// The receiver's pairing channel (issue #16, PROTOCOL.md 11.3): a plain TCP
// listener on base port + 3 where a sender proves the code this receiver
// shows, and the two trade the keys they pin for mutual TLS. The channel
// itself needs no encryption — SRP and the identity MACs carry the security
// (see Shared/Pairing.swift) — and nothing but these four messages is ever
// spoken on it. Runs on the owning StreamReceiver's queue.

import Foundation
import Network

final class PairingListener {
    /// What the receiver UI shows while a sender waits for the code.
    struct Prompt: Equatable {
        let code: String
        let senderName: String
    }

    /// Main-thread callbacks.
    var onPrompt: ((Prompt?) -> Void)?
    var onPaired: ((_ senderID: String, _ senderName: String) -> Void)?

    private let queue: DispatchQueue
    private let receiverID: String
    private let receiverName: () -> String
    private var listener: NWListener?
    private(set) var healthy = false
    private var port: UInt16 = 0

    // One pairing at a time: a new connection replaces the attempt in
    // progress (the code on screen changes, so the user sees it).
    private var connection: NWConnection?
    private var buffer = Data()
    private var attempt: Attempt?
    private var expiry: DispatchWorkItem?

    private struct Attempt {
        let server: PairingServer
        let senderID: String
        let senderName: String
        let clientPublicKeyHex: String
    }

    // Online guessing: each wrong code costs the guesser a full exchange,
    // a visible code on the receiver, and a delay; enough of them in a
    // window close the channel for a while. With 10^6 codes, 5 guesses per
    // 5 minutes keeps a determined attacker below 1% after a year.
    private var failures: [Date] = []
    private var lockedUntil: Date?
    private static let maxFailures = 5
    private static let failureWindow: TimeInterval = 15 * 60
    private static let lockout: TimeInterval = 5 * 60
    private static let failureDelay: TimeInterval = 1
    /// How long a shown code stays valid.
    private static let codeLifetime: TimeInterval = 120

    init(queue: DispatchQueue, receiverID: String, receiverName: @escaping () -> String) {
        self.queue = queue
        self.receiverID = receiverID
        self.receiverName = receiverName
    }

    /// Bind base port + 3. Call on `queue`.
    func start(port: UInt16) {
        self.port = port
        guard listener == nil else { return }
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            Log.info("pairing listener failed on :\(port): \(error)")
            return
        }
        self.listener = listener
        listener.service = service
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.healthy = true
            case .failed(let error):
                Log.info("pairing listener failed: \(error) — restarting in 1s")
                self.healthy = false
                self.listener?.cancel()
                self.listener = nil
                self.queue.asyncAfter(deadline: .now() + 1) { self.start(port: self.port) }
            case .cancelled:
                self.healthy = false
            default: break
            }
        }
        listener.start(queue: queue)
    }

    /// Call on `queue`.
    func stop() {
        listener?.cancel()
        listener = nil
        healthy = false
        endAttempt()
    }

    /// Published under the receiver's service name so a sender can dial it
    /// by name (PROTOCOL.md 11.1).
    private var service: NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = receiverID
        return NWListener.Service(name: receiverName(), type: WireCrypto.pairServiceType,
                                  domain: nil, txtRecord: txt)
    }

    /// The receiver was renamed. Call on `queue`.
    func republish() {
        listener?.service = service
    }

    func ensureListening() {
        if listener == nil, port != 0 { start(port: port) }
    }

    // MARK: - Connection

    private func accept(_ conn: NWConnection) {
        Log.info("pairing connection from \(String(describing: conn.endpoint))")
        endAttempt()
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === conn else { return }
            switch state {
            case .failed, .cancelled: self.endAttempt()
            default: break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                guard self.drain(on: conn) else { return }
            }
            if isComplete || error != nil {
                self.endAttempt()
                return
            }
            self.receive(on: conn)
        }
    }

    /// Parse whole frames; false once the connection was given up.
    private func drain(on conn: NWConnection) -> Bool {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= WireCrypto.maxPairFrameBytes else {
                Log.info("pairing: frame length \(length) out of bounds — closing")
                endAttempt()
                return false
            }
            guard buffer.count >= 4 + length else { break }
            let payload = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            guard let message = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let type = message["type"] as? String else {
                fail(on: conn, reason: "malformed")
                return false
            }
            switch type {
            case WireMessage.pairStart: start(message, on: conn)
            case WireMessage.pairProof: proof(message, on: conn)
            default:
                fail(on: conn, reason: "malformed")
                return false
            }
            if connection !== conn { return false }
        }
        return true
    }

    // MARK: - Messages

    private func start(_ message: [String: Any], on conn: NWConnection) {
        guard attempt == nil,
              let senderID = message["id"] as? String, !senderID.isEmpty, senderID.count <= 128,
              let a = message["A"] as? String, !a.isEmpty else {
            fail(on: conn, reason: "malformed")
            return
        }
        if let until = lockedUntil, until > Date() {
            Log.info("pairing: refused, locked for \(Int(until.timeIntervalSinceNow))s after failed attempts")
            send(["type": WireMessage.pairError, "reason": "locked",
                  "retryAfter": Int(until.timeIntervalSinceNow.rounded(.up))], on: conn, thenClose: true)
            return
        }
        let rawName = (message["name"] as? String) ?? ""
        let senderName = rawName.isEmpty ? "A Mac" : String(rawName.prefix(64))
        let server = PairingServer()
        attempt = Attempt(server: server, senderID: senderID, senderName: senderName,
                          clientPublicKeyHex: a)
        Log.info("pairing: \(senderName) asked to pair — showing a code")
        let prompt = Prompt(code: server.code, senderName: senderName)
        DispatchQueue.main.async { self.onPrompt?(prompt) }
        let timeout = DispatchWorkItem { [weak self, weak conn] in
            guard let self, let conn, self.connection === conn else { return }
            Log.info("pairing: code expired")
            self.send(["type": WireMessage.pairError, "reason": "expired"], on: conn, thenClose: true)
        }
        expiry = timeout
        queue.asyncAfter(deadline: .now() + Self.codeLifetime, execute: timeout)
        send(["type": WireMessage.pairChallenge,
              "id": receiverID,
              "name": receiverName(),
              "salt": server.saltHex,
              "B": server.publicKeyHex], on: conn)
    }

    private func proof(_ message: [String: Any], on conn: NWConnection) {
        guard let attempt,
              let m1 = message["M1"] as? String,
              let spkiB64 = message["spki"] as? String,
              let senderSPKI = Data(base64Encoded: spkiB64), !senderSPKI.isEmpty, senderSPKI.count <= 4096,
              let macB64 = message["mac"] as? String, let mac = Data(base64Encoded: macB64) else {
            fail(on: conn, reason: "malformed")
            return
        }
        let verified: PairingServer.Verified
        do {
            verified = try attempt.server.verify(clientPublicKeyHex: attempt.clientPublicKeyHex,
                                                 clientProofHex: m1)
        } catch Pairing.Failure.wrongCode {
            recordFailure()
            Log.info("pairing: wrong code from \(attempt.senderName)")
            // Hide the code at once; the reply waits a moment, which slows a
            // guessing loop without making a mistyped code feel broken.
            DispatchQueue.main.async { self.onPrompt?(nil) }
            self.attempt = nil
            queue.asyncAfter(deadline: .now() + Self.failureDelay) { [weak self] in
                self?.send(["type": WireMessage.pairError, "reason": "code"], on: conn, thenClose: true)
            }
            return
        } catch {
            fail(on: conn, reason: "malformed")
            return
        }
        guard Pairing.verifyIdentityMAC(mac, key: verified.identityKey, role: .sender,
                                        id: attempt.senderID, spki: senderSPKI) else {
            Log.info("pairing: sender identity MAC did not verify")
            fail(on: conn, reason: "identity")
            return
        }
        guard let ownSPKI = TrustStore.shared.ownSPKI() else {
            fail(on: conn, reason: "unavailable")
            return
        }
        guard TrustStore.shared.setPin(peerID: attempt.senderID, spki: senderSPKI,
                                       displayName: attempt.senderName) else {
            fail(on: conn, reason: "unavailable")
            return
        }
        failures.removeAll()
        Log.info("pairing: paired with \(attempt.senderName) (\(attempt.senderID))")
        let mac2 = Pairing.identityMAC(key: verified.identityKey, role: .receiver,
                                       id: receiverID, spki: ownSPKI)
        send(["type": WireMessage.pairDone,
              "M2": verified.serverProofHex,
              "spki": ownSPKI.base64EncodedString(),
              "mac": mac2.base64EncodedString()], on: conn, thenClose: true)
        let (id, name) = (attempt.senderID, attempt.senderName)
        self.attempt = nil
        DispatchQueue.main.async {
            self.onPrompt?(nil)
            self.onPaired?(id, name)
        }
    }

    // MARK: - Helpers

    private func recordFailure() {
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < Self.failureWindow } + [now]
        if failures.count >= Self.maxFailures {
            lockedUntil = now.addingTimeInterval(Self.lockout)
            failures.removeAll()
            Log.info("pairing: \(Self.maxFailures) wrong codes — pairing locked for \(Int(Self.lockout))s")
        }
    }

    private func fail(on conn: NWConnection, reason: String) {
        Log.info("pairing: failed (\(reason))")
        send(["type": WireMessage.pairError, "reason": reason], on: conn, thenClose: true)
    }

    private func send(_ message: [String: Any], on conn: NWConnection, thenClose: Bool = false) {
        guard let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { [weak self] _ in
            guard thenClose, let self else { return }
            self.queue.async {
                if self.connection === conn { self.endAttempt() } else { conn.cancel() }
            }
        })
    }

    /// Drop the connection and anything shown for it. Idempotent.
    private func endAttempt() {
        expiry?.cancel()
        expiry = nil
        let hadPrompt = attempt != nil
        attempt = nil
        buffer.removeAll()
        if let conn = connection {
            connection = nil
            conn.cancel()
        }
        if hadPrompt { DispatchQueue.main.async { self.onPrompt?(nil) } }
    }
}
