// How the sender decides to reach a receiver over the network (issue #16,
// PROTOCOL.md 11): pinned mutual TLS for a paired receiver, code pairing
// for one that offers it, and an explicit, informed choice before anything
// goes out unencrypted to one that cannot encrypt.

import AppKit
import Network

extension SenderController {
    enum WiFiDecision {
        case encrypted(TLSSessionConfig)
        case plain
        /// Not now: pairing or a consent question is under way, or the
        /// device needs the user (the row says why).
        case deferred
    }

    // MARK: - Discovery of the encrypted transport

    /// Receivers that can pair publish their TLS listener as its own
    /// service under the same name (PROTOCOL.md 11.1). Its presence is the
    /// capability signal that does not depend on the main record's TXT,
    /// which browse results often lack.
    func startBrowsingSecure() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: WireCrypto.tlsServiceType, domain: nil),
                                using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                var services: [String: String] = [:]
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    var id = ""
                    if case .bonjour(let txt) = result.metadata { id = txt["id"] ?? "" }
                    services[name] = id
                }
                self.secureServices = services
            }
        }
        browser.start(queue: .main)
        tlsBrowser = browser
    }

    func offersEncryption(_ result: NWBrowser.Result) -> Bool {
        if case .bonjour(let txt) = result.metadata, txt["sec"] == "1" { return true }
        guard let name = serviceName(of: result) else { return false }
        return secureServices[name] != nil
    }

    /// The receiver's install id: its TXT, its TLS service's TXT, or what an
    /// earlier hello or pairing taught us for this service name.
    func receiverID(for result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata, let id = txt["id"], !id.isEmpty { return id }
        guard let name = serviceName(of: result) else { return nil }
        if let id = secureServices[name], !id.isEmpty { return id }
        return installIDByWifiName[name]
    }

    private func consentKey(for result: NWBrowser.Result) -> String {
        receiverID(for: result) ?? ConnectionTarget.wifi(result).sessionID
    }

    func note(_ target: ConnectionTarget, _ text: String?) {
        wifiNotes[target.sessionID] = text
    }

    // MARK: - The decision

    /// - cableTrusted: the record was seen on the direct host-to-host cable
    ///   (physical trust, PROTOCOL.md 11.6) — plain is fine there.
    /// - approvedOnce: the user just confirmed an unencrypted connection.
    func decideWiFi(_ result: NWBrowser.Result, userInitiated: Bool,
                    cableTrusted: Bool = false, approvedOnce: Bool = false) -> WiFiDecision {
        let target = ConnectionTarget.wifi(result)
        let id = receiverID(for: result)

        // A name we know as a paired receiver now claims another identity:
        // a reinstall, or someone else using that name. Never treat it as
        // the paired device, and never quietly as a plain one either.
        if let name = serviceName(of: result), let known = installIDByWifiName[name],
           let id, id != known, TrustStore.shared.hasPin(peerID: known), !TrustStore.shared.hasPin(peerID: id) {
            note(target, "This isn't the device paired under this name. Forget that pairing to connect.")
            return .deferred
        }

        if let id, let pin = TrustStore.shared.pin(peerID: id) {
            guard let identity = TrustStore.shared.ownIdentity() else {
                note(target, "Encryption unavailable: this Mac's key couldn't be loaded from the Keychain.")
                return .deferred
            }
            note(target, nil)
            return .encrypted(TLSSessionConfig(identity: identity, pinnedReceiverSPKI: pin, peerID: id))
        }
        if cableTrusted { return .plain }
        if offersEncryption(result) {
            if userInitiated {
                startPairing(result, expectedID: id)
            } else {
                note(target, "Not paired yet — Connect to pair with a code.")
            }
            return .deferred
        }
        if approvedOnce || plaintextApproved.contains(consentKey(for: result)) {
            note(target, nil)
            return .plain
        }
        if userInitiated {
            askPlaintextConsent(result)
        } else {
            note(target, "Can't encrypt — Connect to choose.")
        }
        return .deferred
    }

    // MARK: - Pairing

    func startPairing(_ result: NWBrowser.Result, expectedID: String?) {
        let target = ConnectionTarget.wifi(result)
        guard !pairingInFlight.contains(target.sessionID) else { return }
        pairingInFlight.insert(target.sessionID)
        note(target, "Pairing — enter the code shown on the device…")
        Task { @MainActor in
            defer { self.pairingInFlight.remove(target.sessionID) }
            while true {
                do {
                    let paired = try await PairingDialer.pair(
                        endpoint: result.endpoint, expectedReceiverID: expectedID,
                        askCode: { name in Self.askForCode(deviceName: name) })
                    if let name = self.serviceName(of: result) {
                        self.installIDByWifiName[name] = paired.receiverID
                    }
                    self.note(target, nil)
                    self.pairingInFlight.remove(target.sessionID)
                    // Discovery may have refreshed the record meanwhile.
                    let fresh = self.discovered.first { self.serviceName(of: $0) == self.serviceName(of: result) } ?? result
                    self.connect(to: .wifi(fresh), userInitiated: true)
                    return
                } catch let failure as PairingDialer.Failure {
                    Log.info("pairing with \(target.sessionID) failed: \(failure)")
                    if failure == .cancelled {
                        self.note(target, nil)
                        return
                    }
                    self.note(target, failure.message)
                    let retryable = failure == .wrongCode || failure == .expired
                    guard Self.showPairingFailure(failure, offerRetry: retryable) else { return }
                    self.note(target, "Pairing — enter the code shown on the device…")
                } catch {
                    Log.info("pairing with \(target.sessionID) failed: \(error)")
                    self.note(target, "Pairing failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    /// Modal code prompt. nil when the user cancels.
    static func askCode(deviceName: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pair with “\(deviceName)”"
        alert.informativeText = "Enter the 6-digit code shown on \(deviceName). Once paired, this Mac and \(deviceName) "
            + "connect over Wi-Fi encrypted, and only to each other."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        field.placeholderString = "123456"
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func askForCode(deviceName: String) -> String? { askCode(deviceName: deviceName) }

    /// true = try again.
    static func showPairingFailure(_ failure: PairingDialer.Failure, offerRetry: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Pairing didn't work"
        alert.informativeText = failure.message
        if offerRetry {
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return false
    }

    // MARK: - Consent to an unencrypted connection

    func askPlaintextConsent(_ result: NWBrowser.Result) {
        let target = ConnectionTarget.wifi(result)
        let name = serviceName(of: result) ?? "This device"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)” can't encrypt this connection"
        alert.informativeText = "If you connect, everything shown on this display, and every touch and keystroke sent "
            + "back, crosses the network unencrypted. Anyone on this network could watch or tamper with it.\n\n"
            + "To encrypt, update OpenDisplay on \(name) to a version that supports pairing. A USB or "
            + "Thunderbolt cable is also safe without encryption."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Connect Unencrypted")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again for \(name)"
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else {
            note(target, "Not connected: can't encrypt.")
            return
        }
        if alert.suppressionButton?.state == .on {
            plaintextApproved.insert(consentKey(for: result))
        }
        Log.info("user approved an unencrypted connection to \(target.sessionID)")
        connect(to: target, userInitiated: true, plaintextApprovedOnce: true)
    }

    func hasPlaintextApproval(_ entry: DeviceEntry) -> Bool {
        guard case .wifi(let result)? = entry.wifiTarget else { return false }
        return plaintextApproved.contains(consentKey(for: result))
    }

    func revokePlaintextApproval(_ entry: DeviceEntry) {
        guard case .wifi(let result)? = entry.wifiTarget else { return }
        plaintextApproved.remove(consentKey(for: result))
    }

    // MARK: - Forget

    /// The paired receiver behind a device row, if any.
    func pairedReceiverID(for entry: DeviceEntry) -> String? {
        var candidates: [String] = []
        if let id = session(for: entry)?.deviceID { candidates.append(id) }
        if case .wifi(let result)? = entry.wifiTarget, let id = receiverID(for: result) { candidates.append(id) }
        if case .usb(let udid?)? = entry.usbTarget, let id = installIDByUDID[udid] { candidates.append(id) }
        return candidates.first { TrustStore.shared.hasPin(peerID: $0) }
    }

    /// Drop the pairing on both sides: tell the receiver over the live
    /// encrypted session when there is one (PROTOCOL.md 11.5), then forget.
    func forgetPairing(receiverID: String) {
        let live = sessions.filter { $0.deviceID == receiverID && $0.encrypted }
        let ownID = TrustStore.shared.installID()
        TrustStore.shared.forget(peerID: receiverID)
        Log.info("forgot paired receiver \(receiverID)")
        for session in live {
            if let ownID {
                session.sender.sendUnpair(fromID: ownID, toID: receiverID) { [weak self] in self?.end(session) }
            } else {
                end(session)
            }
        }
        objectWillChange.send()
    }

    /// Wire the encrypted-transport callbacks of a freshly built session.
    func attachSecurityHandlers(_ session: DeviceSession) {
        session.sender.onUnpaired = { [weak self, weak session] fromID, toID in
            guard let self, let session else { return }
            guard toID == TrustStore.shared.installID(), fromID == session.deviceID else {
                Log.info("unpair ignored: not addressed to this Mac by this session's receiver")
                return
            }
            Log.info("receiver \(fromID) forgot this Mac — dropping its pin")
            TrustStore.shared.forget(peerID: fromID)
            self.wifiNotes[session.id] = "The device forgot this Mac — Connect to pair again."
            self.end(session)
        }
        session.sender.onPairingRejected = { [weak self, weak session] receiverID in
            guard let self, let session else { return }
            self.wifiNotes[session.id] = "This device no longer accepts this Mac. Forget the pairing, then pair again."
            self.end(session)
        }
    }
}
