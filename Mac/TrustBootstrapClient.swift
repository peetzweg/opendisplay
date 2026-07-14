// TrustBootstrapClient — one-shot USB trust bootstrap (wifi-tls-pairing-plan
// §2). Dials the phone's loopback-bound bootstrap listener through usbmuxd,
// offers this Mac's identity, and waits for the phone's accept/deny.
//
// Owns a single dedicated connection on its own queue with its own
// lifecycle — NEVER touches MacSender.connection, dialGeneration, or the
// video channel. Framing mirrors MacSender.sendJSONFrame's:
//   [UInt32 big-endian payload length][UTF-8 JSON]

import Foundation
import Network

/// One-shot USB trust bootstrap. Self-verifying: always offers; the phone
/// auto-accepts silently on an exact pin match and prompts otherwise.
enum TrustBootstrapClient {
    private static let dialAttempts = 3
    private static let dialRetryDelay: Duration = .seconds(2)

    /// - Parameters:
    ///   - udid: the usbmuxd device to dial the bootstrap port through.
    ///   - expectedPhoneID: the phone's installID from its hello — the Mac
    ///     verifies the phone's trustAccept.phoneID matches this.
    ///   - phoneDisplayName: mac-known name (usbDevices name ?? session.name).
    ///   - status: diagnostic surface (DeviceSession.pairingStatus); nil = clear.
    static func run(udid: String,
                    expectedPhoneID: String,
                    phoneDisplayName: String,
                    status: @escaping @Sendable (String?) -> Void) async {
        // 1. Our own identity — no force-unwrap anywhere.
        guard let macID = TrustStore.shared.installID(),
              let spki = TrustStore.shared.ownSPKI() else {
            status("Pairing unavailable — identity error")
            return
        }

        let queue = DispatchQueue(label: "trustbootstrap.\(udid)")

        // 2. Dial the loopback-bound bootstrap listener through usbmuxd, with
        //    limited retries — the phone's listener may not be up yet.
        var connection: NWConnection?
        var lastError: Error?
        for attempt in 0..<dialAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: dialRetryDelay)
            }
            do {
                connection = try await Usbmux.dial(udid: udid, port: WireCrypto.bootstrapPort, queue: queue)
                break
            } catch {
                lastError = error
            }
        }
        guard let conn = connection else {
            Log.info("TrustBootstrapClient: dial failed after \(dialAttempts) attempts: \(String(describing: lastError))")
            status("Pairing channel unavailable — is another app using port 9010?")
            return
        }
        defer { conn.cancel() }

        // Install a benign state handler; we drive everything explicitly
        // below via the async send/receive helpers.
        conn.stateUpdateHandler = { _ in }
        conn.start(queue: queue)

        // 3. Send trustOffer.
        let macName = Host.current().localizedName ?? "Mac"
        let offer: [String: Any] = [
            "type": WireMessage.trustOffer,
            "pv": WireProtocol.version,
            "macID": macID,
            "macName": macName,
            "spki": spki.base64EncodedString(),
        ]
        do {
            try await sendFrame(offer, on: conn, queue: queue)
        } catch {
            Log.info("TrustBootstrapClient: send trustOffer failed: \(error)")
            status("Pairing channel unavailable — is another app using port 9010?")
            return
        }
        // Only surface the "confirm on device" hint if the phone doesn't
        // auto-accept near-instantly (exact pin match) — no flash on the
        // routine plug-in path.
        let prompt = Task {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            status("Confirm the pairing on your iPhone or iPad…")
        }
        defer { prompt.cancel() }

        // 4. Await exactly one reply frame — no read timeout; the user may
        //    deliberate. Connection death just returns silently; the next
        //    hello retries.
        let reply: [String: Any]
        do {
            reply = try await receiveFrame(on: conn, queue: queue)
        } catch {
            Log.info("TrustBootstrapClient: no reply (connection closed): \(error)")
            return
        }

        guard let type = reply["type"] as? String else {
            Log.info("TrustBootstrapClient: malformed reply (no type)")
            return
        }

        switch type {
        case WireMessage.trustDeny:
            status("Pairing declined on the device")
        case WireMessage.trustAccept:
            guard let phoneID = reply["phoneID"] as? String, phoneID == expectedPhoneID,
                  let spkiB64 = reply["spki"] as? String,
                  let decoded = Data(base64Encoded: spkiB64), !decoded.isEmpty else {
                Log.info("TrustBootstrapClient: trustAccept failed validation")
                status("Pairing failed — device identity mismatch")
                return
            }
            // Mac pins strictly after the phone's accept, which itself is
            // strictly after user confirmation.
            if TrustStore.shared.setPin(peerID: expectedPhoneID, spki: decoded, displayName: phoneDisplayName) {
                status(nil)
            } else {
                status("Pairing failed — device identity mismatch")
            }
        default:
            Log.info("TrustBootstrapClient: unexpected reply type \(type)")
        }
    }

    // MARK: - Framing: [UInt32 big-endian length][UTF-8 JSON]

    private static func sendFrame(_ message: [String: Any], on conn: NWConnection, queue: DispatchQueue) async throws {
        let payload = try JSONSerialization.data(withJSONObject: message)
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private static func receiveFrame(on conn: NWConnection, queue: DispatchQueue) async throws -> [String: Any] {
        let header = try await receive(exactly: 4, on: conn)
        let len = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard len > 0, len < WireCrypto.maxBootstrapFrameBytes else {
            throw NSError(domain: "TrustBootstrapClient", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad frame length \(len)"])
        }
        let payload = try await receive(exactly: len, on: conn)
        guard let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw NSError(domain: "TrustBootstrapClient", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "non-object JSON reply"])
        }
        return obj
    }

    private static func receive(exactly count: Int, on conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: error ?? NSError(
                        domain: "TrustBootstrapClient", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "socket closed"]))
                }
            }
        }
    }
}
