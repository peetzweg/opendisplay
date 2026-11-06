// The sender's half of code pairing (issue #16, PROTOCOL.md 11.3): dial the
// receiver's pairing service, let it show a code, prove the code the user
// typed, and pin the receiver's key once it has proven the code too.
// One dedicated connection with its own queue — never MacSender's.

import Foundation
import Network

enum PairingDialer {
    enum Failure: Error, Equatable {
        case unreachable                 // no pairing service answered
        case identityUnavailable         // this Mac has no usable TLS identity
        case wrongCode
        case expired
        case locked(retryAfter: Int)     // too many wrong codes on the receiver
        case refused(String)             // pairError with another reason
        case cancelled                   // the user dismissed the prompt
        case otherDevice                 // the code belonged to a different receiver
        case protocolError(String)

        var message: String {
            switch self {
            case .unreachable: return "Couldn't reach the device to pair. Make sure OpenDisplay is open on it."
            case .identityUnavailable: return "This Mac couldn't create its encryption key (Keychain unavailable)."
            case .wrongCode: return "That code wasn't right. Try again with the new code on the device."
            case .expired: return "The code expired. Try again."
            case .locked(let seconds):
                return "Too many wrong codes. The device accepts new pairing attempts in \(max(1, seconds / 60)) min."
            case .refused(let reason): return "The device refused to pair (\(reason))."
            case .cancelled: return "Pairing cancelled."
            case .otherDevice: return "The code came from a different device than the one selected."
            case .protocolError(let detail): return "Pairing failed: \(detail)."
            }
        }
    }

    struct Paired {
        let receiverID: String
        let receiverName: String
    }

    /// Run one pairing attempt against `endpoint` (the receiver's main
    /// service or address). `askCode` runs on the main actor once the
    /// receiver shows its code; it returns nil when the user cancels.
    /// `expectedReceiverID`, when known, must match the receiver that
    /// answers. On success both pins are stored.
    static func pair(endpoint: NWEndpoint, expectedReceiverID: String?,
                     askCode: @escaping @MainActor (_ receiverName: String) async -> String?) async throws -> Paired {
        guard let senderID = TrustStore.shared.installID(),
              let senderSPKI = TrustStore.shared.ownSPKI() else {
            throw Failure.identityUnavailable
        }
        let queue = DispatchQueue(label: "opendisplay.pairing")
        let target = WireCrypto.endpoint(endpoint, serviceType: WireCrypto.pairServiceType,
                                         portOffset: WireCrypto.pairPortOffset)
        let conn = NWConnection(to: target, using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options()))
        defer { conn.cancel() }
        try await ready(conn, queue: queue)

        let client = PairingClient()
        let senderName = Host.current().localizedName ?? "Mac"
        try await send(["type": WireMessage.pairStart, "pv": 1, "id": senderID,
                        "name": senderName, "A": client.publicKeyHex], on: conn)
        let challenge = try await receive(on: conn)
        guard challenge["type"] as? String == WireMessage.pairChallenge,
              let receiverID = challenge["id"] as? String, !receiverID.isEmpty,
              let salt = challenge["salt"] as? String,
              let b = challenge["B"] as? String else {
            throw failure(from: challenge)
        }
        if let expectedReceiverID, expectedReceiverID != receiverID {
            throw Failure.otherDevice
        }
        let receiverName = (challenge["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "the device"

        guard let typed = await askCode(receiverName) else { throw Failure.cancelled }
        guard let code = Pairing.normalizeCode(typed) else { throw Failure.wrongCode }

        let proof: PairingClient.Proof
        do {
            proof = try client.prove(code: code, saltHex: salt, serverPublicKeyHex: b)
        } catch {
            throw Failure.protocolError("bad challenge")
        }
        let mac = Pairing.identityMAC(key: proof.identityKey, role: .sender, id: senderID, spki: senderSPKI)
        try await send(["type": WireMessage.pairProof, "M1": proof.clientProofHex,
                        "spki": senderSPKI.base64EncodedString(),
                        "mac": mac.base64EncodedString()], on: conn)
        let done = try await receive(on: conn)
        guard done["type"] as? String == WireMessage.pairDone,
              let m2 = done["M2"] as? String,
              let spkiB64 = done["spki"] as? String,
              let receiverSPKI = Data(base64Encoded: spkiB64), !receiverSPKI.isEmpty, receiverSPKI.count <= 4096,
              let macB64 = done["mac"] as? String, let receiverMAC = Data(base64Encoded: macB64) else {
            throw failure(from: done)
        }
        do {
            try client.verifyServer(proofHex: m2, for: proof)
        } catch {
            throw Failure.protocolError("the device did not prove the code")
        }
        guard Pairing.verifyIdentityMAC(receiverMAC, key: proof.identityKey, role: .receiver,
                                        id: receiverID, spki: receiverSPKI) else {
            throw Failure.protocolError("the device's key did not verify")
        }
        guard TrustStore.shared.setPin(peerID: receiverID, spki: receiverSPKI, displayName: receiverName) else {
            throw Failure.identityUnavailable
        }
        Log.info("paired with \(receiverName) (\(receiverID))")
        return Paired(receiverID: receiverID, receiverName: receiverName)
    }

    private static func failure(from message: [String: Any]) -> Failure {
        guard message["type"] as? String == WireMessage.pairError else {
            return .protocolError("unexpected \(message["type"] ?? "message")")
        }
        switch message["reason"] as? String {
        case "code": return .wrongCode
        case "expired": return .expired
        case "locked": return .locked(retryAfter: message["retryAfter"] as? Int ?? 300)
        case let reason?: return .refused(reason)
        case nil: return .refused("no reason")
        }
    }

    // MARK: - Connection helpers ([UInt32 BE length][JSON] frames)

    private static func ready(_ conn: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resume: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                cont.resume(with: result)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: resume(.success(()))
                case .failed, .cancelled: resume(.failure(Failure.unreachable))
                case .waiting: resume(.failure(Failure.unreachable))
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { resume(.failure(Failure.unreachable)) }
        }
    }

    private static func send(_ message: [String: Any], on conn: NWConnection) async throws {
        let payload = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// One frame. No timeout: the receiver bounds the exchange (the code
    /// expires there), and a closed socket ends the wait.
    private static func receive(on conn: NWConnection) async throws -> [String: Any] {
        let header = try await read(4, on: conn)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= WireCrypto.maxPairFrameBytes else {
            throw Failure.protocolError("bad frame length \(length)")
        }
        let payload = try await read(length, on: conn)
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw Failure.protocolError("not a JSON object")
        }
        return object
    }

    private static func read(_ count: Int, on conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: error.map { _ in Failure.unreachable } ?? Failure.unreachable)
                }
            }
        }
    }
}
