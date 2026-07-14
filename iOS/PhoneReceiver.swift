// PhoneReceiver — Milestone 1: receive H.264 over TCP and display it.
//
// Pipeline:  TCP socket -> deframe -> Annex B parse -> CMSampleBuffer
//            -> AVSampleBufferDisplayLayer (decodes + renders)
//
// The phone LISTENS; the Mac connects (required for usbmux/USB).
// Wire protocol: [4-byte big-endian length][Annex B payload].

import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox
import UIKit
import Security
import CryptoKit

/// One-second window of pipeline health, plus per-frame timing samples for
/// the performance overlay graph.
struct PerfStats: Equatable {
    var fps = 0
    var mbps = 0.0
    var avgFrameMs = 0.0
    var maxFrameMs = 0.0
    var stalls = 0               // frames that arrived >50ms late (this window)
    var decodeFlushes = 0        // display layer failures since connect
    var samples: [Double] = []   // last ~120 inter-frame intervals, ms
    // True end-to-end latency (Mac capture → phone display handoff), using
    // the clock offset estimated from timestamped ping/pong.
    var e2eP50 = 0.0
    var e2eP95 = 0.0
    var encodeP50 = 0.0          // Mac-side capture→socket (encode + queue)
    var rttMs = 0.0              // control-channel round trip
    var e2eSamples: [Double] = []  // last ~120 per-frame e2e latencies, ms
    var transport = "—"          // USB (loopback via usbmux) or WiFi
    var macDrops = 0             // frames the Mac dropped (backpressure), total
    var macPending = 0           // Mac send queue depth right now
    var inputP50 = 0.0           // touch sent → CGEvent injected on the Mac, ms
    var inputP95 = 0.0
    var capFps = 0               // frames ScreenCaptureKit delivered on the Mac
    // Metal renderer path only:
    var decodeP50 = 0.0          // VTDecompressionSession decode, ms
    var photonP50 = 0.0          // Mac capture → frame actually on glass, ms
    var photonP95 = 0.0
}

/// How an inbound connection was accepted — decided BY THE LISTENER (TLS
/// listener ⇒ .tls; :9000 ⇒ loopback-prefix heuristic, which stays a mere
/// transport label and priority rank, never a trust decision).
private enum TransportLabel {
    case loopback, tls, plaintextWiFi
    var rank: Int { self == .loopback ? 2 : self == .tls ? 1 : 0 }
    var statsName: String { self == .loopback ? "USB" : "WiFi" }
}

/// One pending USB trust offer, published for the confirmation sheet.
struct TrustRequest: Identifiable, Equatable {
    let macID: String
    let macName: String        // cosmetic, UNVERIFIED
    let spki: Data
    let fingerprint: String    // TrustStore.fingerprint(spki:)
    let isIdentityChange: Bool // pin exists but SPKI differs
    var id: String { macID + "|" + fingerprint }
}

final class PhoneReceiver: ObservableObject {

    @Published var status = "Starting…"
    @Published var fps = 0
    @Published var connected = false
    @Published var videoSize = CGSize.zero   // for touch coordinate mapping
    @Published var perf = PerfStats()
    // Compatibility signal from the connected Mac (issue #132). Nil = no signal.
    // Merged into the update gate by ReceiverScreen.
    @Published var peerSignal: PeerUpdateSignal?
    // Main-thread mirror of pendingOffer; drives the trust-confirmation sheet.
    @Published var pendingTrust: TrustRequest?

    private var listener: NWListener?
    private var listenerHealthy = false
    private var connection: NWConnection?
    // peerID (TrustStore account) of the Mac behind `connection`, resolved
    // from its TLS client certificate at `.ready`. Only ever set for `.tls`
    // connections — loopback/USB has no cryptographic peer identity to
    // resolve (never a trust decision), so this stays nil for
    // it. Scopes per-Mac "forget" (dropActiveConnection(peerID:)) so
    // forgetting Mac A can never kick an unrelated, still-trusted Mac B.
    private var connectedPeerID: String?
    private let queue = DispatchQueue(label: "receiver.video")
    private var buffer = Data()
    // Upper bound on a single length-prefixed video-channel frame, so a
    // corrupt or hostile 4-byte length prefix can't grow `buffer` unbounded
    // while trickled bytes keep resetting the liveness watchdog (mirrors the
    // bound already enforced on the bootstrap channel via
    // WireCrypto.maxBootstrapFrameBytes). Generous enough for any real H.264
    // keyframe at the highest supported quality/resolution.
    private static let maxVideoFrameBytes = 64 << 20   // 64 MiB
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    // USB trust bootstrap (loopback-only) + TLS listener state.
    private var bootstrapListener: NWListener?
    private var bootstrapListenerHealthy = false
    private var tlsListener: NWListener?
    private var tlsListenerHealthy = false
    private var currentLabel: TransportLabel?          // label of self.connection
    private var bootstrapConn: NWConnection?           // one at a time
    private var bootstrapBuffer = Data()
    private var pendingOffer: TrustRequest?             // queue-confined mirror of pendingTrust

    // Liveness: the Mac streams video and pings every 2s; if nothing arrives
    // for 5s the connection is half-open (Mac killed, tunnel died) — drop it
    // so the listener can accept a fresh one.
    private var lastDataReceived = Date()
    private var port: UInt16 = 9000
    private var monitorsStarted = false

    private var framesThisWindow = 0
    private var fpsWindowStart = Date()
    private var bytesThisWindow = 0
    private var stallsThisWindow = 0
    private var decodeFlushes = 0
    private var lastFrameAt: Date?
    private var frameIntervals: [Double] = []   // ring buffer, ms
    private let maxSamples = 120

    // Clock sync (NTP-style): offset = macClock − phoneClock, taken from the
    // ping/pong sample with the lowest RTT (least asymmetric).
    private var offsetSamples: [(rtt: Double, offset: Double)] = []
    private var clockOffsetMs: Double?
    private var lastRttMs = 0.0
    private var e2eWindow: [Double] = []        // capture→display, ms
    private var encodeWindow: [Double] = []     // capture→socket on the Mac, ms
    private var e2eRing: [Double] = []          // per-frame, for the overlay graph
    private var statsReportCounter = 0
    private var transport = "—"
    private var macDrops = 0
    private var macPending = 0
    private var macInputP50 = 0.0
    private var macInputP95 = 0.0
    private var macCapFps = 0

    private var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    // Local cursor echo (both called on the main thread): position is
    // normalized [0,1] in video space; the sprite arrives as a PNG with its
    // hotspot anchor and size normalized against the Mac display.
    var onCursor: ((_ x: Double, _ y: Double, _ visible: Bool) -> Void)?
    var onCursorImage: ((_ image: UIImage, _ anchor: CGPoint, _ normSize: CGSize) -> Void)?

    // Metal renderer path (experimental, "metalRenderer" setting): we decode
    // explicitly and hand BGRA buffers out; called on the receiver queue.
    var onDecodedFrame: ((_ pixelBuffer: CVPixelBuffer, _ captureMs: Double?) -> Void)?
    private var decompressionSession: VTDecompressionSession?
    private var decodeWindow: [Double] = []
    private var photonWindow: [Double] = []
    private var loggedDisplayPath = false
    private var decodeErrorCount = 0
    // Default OFF: A/B measurement showed the system video layer reaches
    // glass faster than our CAMetalLayer path (iOS gives AVSBDL a dedicated
    // compositor plane). Kept as an experimental toggle + for its metrics.
    private var useMetalPath: Bool { UserDefaults.standard.bool(forKey: "metalRenderer") }

    /// Called by the renderer's presented handler: maps the CACurrentMediaTime-
    /// based glass timestamp into wall-clock ms and computes true photon e2e.
    func recordPresented(presentedTime: CFTimeInterval, captureMs: Double?) {
        guard let captureMs, presentedTime > 0 else { return }
        let presentedWallMs = nowMs - (CACurrentMediaTime() - presentedTime) * 1000
        queue.async {
            guard let offset = self.clockOffsetMs else { return }
            let photon = (presentedWallMs + offset) - captureMs
            if photon > -50, photon < 5000 {
                self.photonWindow.append(max(photon, 0))
            }
        }
    }

    let displayLayer: AVSampleBufferDisplayLayer

    /// Native panel size in pixels + scale, announced to the Mac in a "hello"
    /// message so it can size the virtual display. Orientation-dependent:
    /// rotating the phone re-announces with swapped dimensions and the Mac
    /// rebuilds the virtual display as a portrait/landscape monitor.
    private var nativeLong = 0
    private var nativeShort = 0
    private(set) var devicePixelsWide = 0
    private(set) var devicePixelsHigh = 0
    var deviceScale: Double = 2
    // Name advertised over Bonjour for the Mac's WiFi picker. iOS 16+ returns
    // a generic "iPhone" from UIDevice.current.name (the user-assigned name
    // needs an entitlement Apple gates behind approval and personal teams
    // can't get), so this is user-editable in Settings. The USB picker gets
    // the real name host-side via lockdownd regardless.
    var serviceName = "OpenDisplay"

    // Stable per-install identity, advertised in the Bonjour TXT record and
    // sent in every hello. The Mac uses it to recognize "same device, other
    // transport" — the service name can't serve that role since it's
    // user-editable, and iOS offers no public API for the hardware UDID
    // that usbmuxd reports.
    static let installID: String = {
        if let existing = UserDefaults.standard.string(forKey: "installID") {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "installID")
        return fresh
    }()

    private func advertisedService() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = Self.installID
        txt["pv"] = String(WireProtocol.version)   // issue #132
        return NWListener.Service(name: serviceName, type: "_opensidecar._tcp",
                                  domain: nil, txtRecord: txt)
    }

    /// Update the advertised name and re-publish if already listening.
    func setServiceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? UIDevice.current.name : trimmed
        queue.async {
            guard resolved != self.serviceName else { return }
            self.serviceName = resolved
            if self.tlsListener != nil {
                self.tlsListener?.service = self.advertisedService()
                Log.info("re-advertising as \"\(resolved)\"")
            }
        }
    }

    func setNativePanel(long: Int, short: Int, scale: Double) {
        nativeLong = long
        nativeShort = short
        deviceScale = scale
        if devicePixelsWide == 0 {   // default landscape until the view reports
            devicePixelsWide = long
            devicePixelsHigh = short
        }
    }

    func setOrientation(portrait: Bool) {
        let w = portrait ? nativeShort : nativeLong
        let h = portrait ? nativeLong : nativeShort
        guard w > 0, w != devicePixelsWide else { return }
        devicePixelsWide = w
        devicePixelsHigh = h
        Log.info("orientation changed -> \(portrait ? "portrait" : "landscape") \(w)x\(h)")
        if let connection { sendHello(on: connection) }
    }

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
    }

    func start(port: UInt16 = 9000) {
        self.port = port
        queue.async {
            TrustStore.shared.refreshSnapshot()   // arm the verify-block snapshot before any TLS accept
            self.startListener()                  // legacy :9000 — unchanged internals
            self.startBootstrapListener()
            self.startTLSListener()
        }
        if !monitorsStarted {
            monitorsStarted = true
            schedulePing()
            scheduleWatchdog()
        }
    }

    /// Recreate any listener that isn't healthy — called when the app
    /// returns to the foreground (iOS may have torn listeners down while
    /// suspended). Per-listener recovery: a healthy listener (and its live
    /// accepted connection) is never churned because a sibling is down.
    func ensureListening() {
        queue.async {
            if !self.listenerHealthy          { Log.info("legacy listener unhealthy — restarting");    self.restartListener() }
            if !self.bootstrapListenerHealthy { Log.info("bootstrap listener unhealthy — restarting"); self.restartBootstrapListener() }
            if !self.tlsListenerHealthy       { Log.info("TLS listener unhealthy — restarting");       self.restartTLSListener() }
        }
    }

    /// Reset-identity hook: tear down and rebuild all three listeners (e.g.
    /// the TLS listener needs the freshly generated identity).
    func restartAllListeners() {
        queue.async {
            self.restartListener()
            self.restartBootstrapListener()
            self.restartTLSListener()
        }
    }

    /// Per-Mac forget hook: kick the live connection ONLY if it belongs to
    /// the forgotten peer. `peerID` is resolved from the peer's TLS client
    /// certificate at connect time (see `resolvePeerID`), so this can't kick
    /// an unrelated, still-trusted Mac's active session. If `connectedPeerID`
    /// couldn't be resolved (e.g. USB/loopback, which has no cryptographic
    /// peer identity) the active connection is left alone;
    /// forgetting a USB-pinned peer while it's the live connection is a rare
    /// edge case and erring toward NOT disconnecting an unrelated session is
    /// the safer default.
    func dropActiveConnection(peerID: String) {
        queue.async {
            guard let conn = self.connection, self.connectedPeerID == peerID else { return }
            Log.info("dropping active connection for forgotten peer \(peerID)")
            conn.cancel()
        }
    }

    /// Reset-identity hook: purgeAll() drops every pin, so unlike the
    /// per-Mac forget above there is no "unrelated" session to protect —
    /// kick whatever is connected, unconditionally.
    func dropActiveConnection() {
        queue.async {
            guard let conn = self.connection else { return }
            Log.info("dropping active connection after identity reset")
            conn.cancel()
        }
    }

    /// Symmetric revoke: tell the connected Mac to drop its pin for us. On a
    /// TLS connection the send is scoped to the forgotten peer via
    /// `connectedPeerID`; on loopback/USB there is no cryptographic peer
    /// identity, so the message is sent as-is and the Mac
    /// ignores it unless `toID` matches its own installID.
    func sendUnpair(toPeerID peerID: String) {
        queue.async {
            guard let conn = self.connection, conn.state == .ready else { return }
            if self.currentLabel == .tls, self.connectedPeerID != peerID { return }
            Log.info("unpair sent to \(peerID)")
            self.sendControl(["type": WireMessage.unpair,
                              "fromID": Self.installID,
                              "toID": peerID], on: conn)
        }
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        listenerHealthy = false
        startListener()
    }

    private func restartBootstrapListener() {
        bootstrapListener?.cancel()
        bootstrapListener = nil
        bootstrapListenerHealthy = false
        startBootstrapListener()
    }

    private func restartTLSListener() {
        tlsListener?.cancel()
        tlsListener = nil
        tlsListenerHealthy = false
        startTLSListener()
    }

    private func startListener() {
        do {
            // noDelay matters most in THIS direction: touch events are tiny
            // packets, and Nagle would hold each one until the previous is
            // ACKed — batched, late drags read as input lag.
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.serviceClass = .interactiveVideo
            // The legacy plaintext port now
            // serves ONLY usbmux-forwarded traffic, which arrives on loopback —
            // bind loopback-only so LAN plaintext can never reach it again. Same
            // anchor as the bootstrap listener below: the port comes from
            // requiredLocalEndpoint — do NOT also pass `on:`.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port)!)
            listener = try NWListener(using: params)
        } catch {
            setStatus("Listener failed: \(error.localizedDescription)")
            return
        }
        listener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            // usbmux-forwarded (cable) connections arrive from loopback;
            // anything else came over the network. This prefix check is a
            // mere transport label / priority rank — never a trust decision;
            // TLS acceptance derives solely from the
            // completed pinned handshake in the TLS listener below.
            let peer = String(describing: conn.endpoint)
            let label: TransportLabel = (peer.hasPrefix("127.0.0.1") || peer.hasPrefix("::1")
                              || peer.hasPrefix("localhost")) ? .loopback : .plaintextWiFi
            self.adopt(conn, label: label)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.listenerHealthy = true
                self.setStatus("Waiting for your Mac to connect…")
            case .failed(let error):
                Log.info("listener failed: \(error) — restarting in 1s")
                self.listenerHealthy = false
                self.setStatus("Listener failed — restarting…")
                self.queue.asyncAfter(deadline: .now() + 1) { self.restartListener() }
            case .cancelled:
                self.listenerHealthy = false
            default: break
            }
        }
        listener?.start(queue: queue)
    }

    // MARK: - Connection adoption / replacement priority

    /// Single adoption path for every inbound connection, regardless of
    /// listener. Rank: loopback = 2, TLS = 1, plaintext-WiFi = 0. Accept iff
    /// no active existing connection OR incoming.rank >= existing.rank.
    /// Rejection cancels the INCOMING conn (never started); acceptance
    /// cancels the existing one.
    /// True unless the connection has cancelled or failed — `.failed` carries
    /// an associated `NWError`, so it can't be matched with a bare `!=` and
    /// needs an explicit switch instead.
    private func isActive(_ state: NWConnection.State) -> Bool {
        switch state {
        case .cancelled, .failed: return false
        default: return true
        }
    }

    private func adopt(_ conn: NWConnection, label: TransportLabel) {
        Log.info("new \(label) connection from \(String(describing: conn.endpoint))")
        if let existing = connection,
           isActive(existing.state),
           let existingLabel = currentLabel,
           label.rank < existingLabel.rank {
            Log.info("rejecting \(label) connection — active \(existingLabel) connection has priority")
            conn.cancel()
            return
        }
        connection?.cancel()
        connection = conn
        currentLabel = label
        transport = label.statsName          // stats/overlay label ONLY — never a trust decision
        resetStreamState()
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lastDataReceived = Date()
                self.setConnected(true)
                if label == .tls {
                    self.connectedPeerID = self.resolvePeerID(for: conn)
                } else {
                    self.connectedPeerID = nil   // loopback/USB: no cryptographic identity
                }
                self.sendHello(on: conn)
            case .failed, .cancelled:
                if self.connection === conn {   // a replaced conn must not clobber its successor
                    self.connection = nil
                    self.currentLabel = nil
                    self.connectedPeerID = nil
                    self.setConnected(false)
                }
            default: break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    /// Resolves which pinned peerID's certificate matches this TLS
    /// connection's peer, by re-deriving its SPKI the SAME way
    /// TLSConfigurator's verify_block does (same-source encoding, so
    /// pinned == extracted byte-for-byte) and looking it up against
    /// TrustStore's pinned peers. Runs on `queue`, post-handshake, so the
    /// connection has already passed pin verification — this only answers
    /// "which pin", never "is it pinned".
    private func resolvePeerID(for conn: NWConnection) -> String? {
        guard let tlsMetadata = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        let secMetadata = tlsMetadata.securityProtocolMetadata
        var leaf: SecCertificate?
        // Block is invoked once per chain certificate, leaf first — grab only
        // the first and ignore the rest (self-signed world: pinning already
        // verified the leaf's SPKI is trusted; we just need to know WHICH one).
        _ = sec_protocol_metadata_access_peer_certificate_chain(secMetadata) { certificate in
            if leaf == nil { leaf = sec_certificate_copy_ref(certificate).takeRetainedValue() }
        }
        guard let leaf,
              let key = SecCertificateCopyKey(leaf),
              let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let pub = try? P256.Signing.PublicKey(x963Representation: x963) else {
            return nil
        }
        let spki = pub.derRepresentation
        return TrustStore.shared.pinnedPeers().first { TrustStore.shared.pin(peerID: $0.peerID) == spki }?.peerID
    }

    // MARK: - USB trust bootstrap listener (loopback-only)

    private func startBootstrapListener() {
        do {
            let tcp = NWProtocolTCP.Options()
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            // THE trust anchor: only loopback-delivered traffic (i.e. usbmux
            // forwarding) can reach this listener. No .service ⇒ no Bonjour ⇒
            // no Local Network prompt.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: WireCrypto.bootstrapPort)!)
            bootstrapListener = try NWListener(using: params)   // port comes from requiredLocalEndpoint — do NOT also pass `on:`
        } catch {
            bootstrapListenerHealthy = false
            Log.info("bootstrap listener bind failed: \(error)")
            return
        }
        bootstrapListener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            // One at a time; a fresh dial (Mac retry) replaces a stale one.
            self.bootstrapConn?.cancel()
            self.bootstrapBuffer.removeAll()
            self.clearPendingTrust()
            self.bootstrapConn = conn
            conn.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.dropBootstrapConn(conn) }
                if case .cancelled = state { self?.dropBootstrapConn(conn) }
            }
            conn.start(queue: self.queue)
            self.handleBootstrapData(on: conn)
        }
        bootstrapListener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.bootstrapListenerHealthy = true
            case .failed(let error):
                Log.info("bootstrap listener failed: \(error) — restarting in 1s")
                self.bootstrapListenerHealthy = false
                self.queue.asyncAfter(deadline: .now() + 1) { self.restartBootstrapListener() }
            case .cancelled: self.bootstrapListenerHealthy = false
            default: break
            }
        }
        bootstrapListener?.start(queue: queue)
    }

    /// If `conn` is still the active bootstrap connection, tear it down and
    /// retract any pending sheet (pending unplug ⇒ sheet retracts; the Mac's
    /// next USB hello retries).
    private func dropBootstrapConn(_ conn: NWConnection) {
        guard bootstrapConn === conn else { return }
        bootstrapConn = nil
        bootstrapBuffer.removeAll()
        clearPendingTrust()
    }

    private func clearPendingTrust() {
        pendingOffer = nil
        DispatchQueue.main.async { self.pendingTrust = nil }
    }

    // MARK: - TLS listener (pinned mutual TLS)

    private func startTLSListener() {
        guard let identity = TrustStore.shared.ownIdentity() else {
            tlsListenerHealthy = false
            Log.info("TLS listener: no identity available — will retry via ensureListening")
            return
        }
        guard let tlsOptions = TLSConfigurator.mutualTLSOptions(
                identity: identity,
                pinnedSPKIs: { TrustStore.shared.allPinnedPeerSPKIs() },   // live snapshot: new pins take effect with NO restart
                isListener: true, queue: queue) else {
            tlsListenerHealthy = false
            Log.info("TLS listener: mutualTLSOptions failed — refusing TLS (never plaintext)")
            return
        }
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: tlsOptions, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.serviceClass = .interactiveVideo
            tlsListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: WireCrypto.tlsPort)!)
        } catch {
            tlsListenerHealthy = false
            Log.info("TLS listener bind failed: \(error)")
            return
        }
        // Advertise on the local network so the Mac can discover us for WiFi
        // mode. This is the ONE Bonjour advertisement — the same
        // "_opensidecar._tcp" type the app has always declared, so upgrades
        // never need a fresh Local Network grant (macOS snapshots the
        // declared types at grant time; a new type browses as NoAuth -65555).
        // It resolves to the TLS port: WiFi is mTLS-only by construction.
        tlsListener?.service = advertisedService()
        tlsListener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            // A completed handshake already proves pinned mutual auth by
            // construction — always .tls, no endpoint-string inspection.
            self.adopt(conn, label: .tls)
        }
        tlsListener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.tlsListenerHealthy = true
            case .failed(let error):
                Log.info("TLS listener failed: \(error) — restarting in 1s")
                self.tlsListenerHealthy = false
                self.queue.asyncAfter(deadline: .now() + 1) { self.restartTLSListener() }
            case .cancelled:
                self.tlsListenerHealthy = false
            default: break
            }
        }
        tlsListener?.start(queue: queue)
    }

    // MARK: - Bootstrap wire protocol

    /// Framed read loop on the bootstrap connection: [UInt32 BE length][UTF-8 JSON].
    private func handleBootstrapData(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard self.bootstrapConn === conn else { return }   // superseded by a fresh dial
            if let data, !data.isEmpty {
                self.bootstrapBuffer.append(data)
                self.drainBootstrapFrames(on: conn)
            }
            if error != nil || isComplete {
                self.dropBootstrapConn(conn)
                return
            }
            if self.bootstrapConn === conn {
                self.handleBootstrapData(on: conn)
            }
        }
    }

    private func drainBootstrapFrames(on conn: NWConnection) {
        while bootstrapBuffer.count >= 4 {
            let len = bootstrapBuffer.prefix(4).withUnsafeBytes {
                Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            guard len > 0, len < WireCrypto.maxBootstrapFrameBytes else {
                Log.info("bootstrap frame length out of bounds (\(len)) — closing")
                conn.cancel()
                return
            }
            guard bootstrapBuffer.count >= 4 + len else { break }
            let payload = bootstrapBuffer.subdata(in: bootstrapBuffer.index(bootstrapBuffer.startIndex, offsetBy: 4)..<bootstrapBuffer.index(bootstrapBuffer.startIndex, offsetBy: 4 + len))
            bootstrapBuffer.removeSubrange(bootstrapBuffer.startIndex..<bootstrapBuffer.index(bootstrapBuffer.startIndex, offsetBy: 4 + len))
            processBootstrapFrame(payload, on: conn)
        }
    }

    /// State machine: idle → offerReceived → {autoAccepted | awaitingUser}
    /// → {accepted | denied | aborted} → idle.
    private func processBootstrapFrame(_ payload: Data, on conn: NWConnection) {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = obj["type"] as? String, type == WireMessage.trustOffer,
              let macID = obj["macID"] as? String, !macID.isEmpty,
              let spkiB64 = obj["spki"] as? String,
              let spki = Data(base64Encoded: spkiB64),
              spki.count >= 1, spki.count <= 4096 else {
            sendBootstrapReply(["type": WireMessage.trustDeny], on: conn, thenClose: true)
            return
        }
        let macName = (obj["macName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
        let fingerprint = TrustStore.fingerprint(spki: spki)

        if let existingPin = TrustStore.shared.pin(peerID: macID) {
            if existingPin == spki {
                // Auto-accept (idempotent): no write, no UI.
                replyTrustAccept(on: conn)
                return
            }
            // Changed identity: pin exists but SPKI differs. Old pin is NOT
            // touched until Allow.
            let request = TrustRequest(macID: macID, macName: macName, spki: spki,
                                       fingerprint: fingerprint, isIdentityChange: true)
            pendingOffer = request
            DispatchQueue.main.async { self.pendingTrust = request }
            return
        }
        // First contact: no pin.
        let request = TrustRequest(macID: macID, macName: macName, spki: spki,
                                   fingerprint: fingerprint, isIdentityChange: false)
        pendingOffer = request
        DispatchQueue.main.async { self.pendingTrust = request }
    }

    /// UI entry point (main thread) — hops to `queue`. Idempotent.
    func resolveTrust(allow: Bool) {
        queue.async {
            guard let offer = self.pendingOffer, let conn = self.bootstrapConn else { return }
            guard allow else {
                self.sendBootstrapReply(["type": WireMessage.trustDeny], on: conn, thenClose: true)
                self.pendingOffer = nil
                DispatchQueue.main.async { self.pendingTrust = nil }
                return
            }
            guard let mySPKI = TrustStore.shared.ownSPKI() else {
                self.sendBootstrapReply(["type": WireMessage.trustDeny], on: conn, thenClose: true)
                self.pendingOffer = nil
                DispatchQueue.main.async { self.pendingTrust = nil }
                return
            }
            guard TrustStore.shared.setPin(peerID: offer.macID, spki: offer.spki, displayName: offer.macName) else {
                self.sendBootstrapReply(["type": WireMessage.trustDeny], on: conn, thenClose: true)
                self.pendingOffer = nil
                DispatchQueue.main.async { self.pendingTrust = nil }
                return
            }
            if self.tlsListener == nil { self.startTLSListener() }
            self.pendingOffer = nil
            DispatchQueue.main.async { self.pendingTrust = nil }
            self.replyTrustAccept(on: conn, mySPKI: mySPKI)
        }
    }

    private func replyTrustAccept(on conn: NWConnection) {
        guard let mySPKI = TrustStore.shared.ownSPKI() else {
            sendBootstrapReply(["type": WireMessage.trustDeny], on: conn, thenClose: true)
            return
        }
        replyTrustAccept(on: conn, mySPKI: mySPKI)
    }

    private func replyTrustAccept(on conn: NWConnection, mySPKI: Data) {
        let message: [String: Any] = [
            "type": WireMessage.trustAccept,
            "phoneID": Self.installID,
            "spki": mySPKI.base64EncodedString(),
        ]
        sendBootstrapReply(message, on: conn, thenClose: true)
    }

    private func sendBootstrapReply(_ message: [String: Any], on conn: NWConnection, thenClose: Bool) {
        guard let payload = try? JSONSerialization.data(withJSONObject: message) else {
            if thenClose { conn.cancel() }
            return
        }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { Log.info("bootstrap reply send error: \(error)") }
            if thenClose {
                conn.cancel()
                if self?.bootstrapConn === conn { self?.bootstrapConn = nil }
            }
        })
    }

    // MARK: - Liveness (ping + watchdog)

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if self.connection?.state == .ready {
                self.sendControl(["type": "ping", "t": self.nowMs])
            }
            self.schedulePing()
        }
    }

    /// JSON on the video channel (pong, ping liveness) — payloads starting '{'.
    private func handleVideoChannelJSON(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "pong":
            guard let t1 = obj["t"] as? Double, let mt = obj["mt"] as? Double else { return }
            let t2 = nowMs
            let rtt = t2 - t1
            guard rtt >= 0, rtt < 2000 else { return }
            let offset = mt - (t1 + t2) / 2
            offsetSamples.append((rtt, offset))
            if offsetSamples.count > 15 { offsetSamples.removeFirst() }
            if let best = offsetSamples.min(by: { $0.rtt < $1.rtt }) {
                clockOffsetMs = best.offset
            }
            lastRttMs = rtt
        case "ping":
            // The Mac piggybacks its send-side health on liveness pings.
            macDrops = obj["drops"] as? Int ?? macDrops
            macPending = obj["pending"] as? Int ?? macPending
            macInputP50 = obj["inp50"] as? Double ?? macInputP50
            macInputP95 = obj["inp95"] as? Double ?? macInputP95
            macCapFps = obj["capFps"] as? Int ?? macCapFps
        case "cursor":
            let visible = (obj["v"] as? Int ?? 0) == 1
            let x = obj["x"] as? Double ?? 0
            let y = obj["y"] as? Double ?? 0
            DispatchQueue.main.async { self.onCursor?(x, y, visible) }
        case "cursorImg":
            guard let b64 = obj["png"] as? String,
                  let png = Data(base64Encoded: b64),
                  let image = UIImage(data: png),
                  let nw = obj["nw"] as? Double, let nh = obj["nh"] as? Double else { return }
            let anchor = CGPoint(x: obj["ax"] as? Double ?? 0, y: obj["ay"] as? Double ?? 0)
            let normSize = CGSize(width: nw, height: nh)
            DispatchQueue.main.async { self.onCursorImage?(image, anchor, normSize) }
        case WireMessage.welcome:
            // The Mac identified itself (issue #132). A Mac older than the
            // TLS WiFi transport still streams over USB (which is how this
            // welcome arrived — the plaintext port is loopback-only), but
            // can never do Wi-Fi — and an old Mac can't diagnose that
            // itself, so surface a soft hint here.
            let macPV = obj["pv"] as? Int ?? WireProtocol.assumedWhenAbsent
            if macPV < WireProtocol.minWiFiPeer {
                let msg = "The OpenDisplay app on your Mac is too old for Wi-Fi streaming. Update OpenDisplay on your Mac to use Wi-Fi — USB keeps working."
                DispatchQueue.main.async { self.peerSignal = .updateMac(message: msg) }
            }
        case WireMessage.updateRequired:
            // The Mac refuses this pairing until we update from the App Store.
            let message = obj["message"] as? String
                ?? "Update OpenDisplay from the App Store to keep using your second display."
            let store = (obj["store"] as? String).flatMap { URL(string: $0) } ?? AppStore.updateURL
            DispatchQueue.main.async { self.peerSignal = .updateIPhone(message: message, storeURL: store) }
        case WireMessage.unpair:
            guard let fromID = obj["fromID"] as? String, !fromID.isEmpty,
                  let toID = obj["toID"] as? String, toID == Self.installID else {
                Log.info("unpair ignored — malformed or not addressed to us")
                break
            }
            // TLS: the authenticated peer must BE the revoking Mac. Loopback
            // has no cryptographic peer identity — the physical
            // cable is the same trust anchor the bootstrap channel uses.
            if currentLabel == .tls, connectedPeerID != fromID {
                Log.info("unpair ignored — fromID \(fromID) does not match authenticated peer")
                break
            }
            Log.info("Mac \(fromID) revoked pairing — forgetting pin and dropping connection")
            TrustStore.shared.forget(peerID: fromID)   // no-op if not pinned; refreshes snapshot
            connection?.cancel()                        // adopt()'s state handler clears connection/connectedPeerID/setConnected
        default:
            break
        }
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if let conn = self.connection, conn.state == .ready,
               Date().timeIntervalSince(self.lastDataReceived) > 5 {
                Log.info("watchdog: nothing from the Mac for >5s — dropping connection")
                conn.cancel()
                self.connection = nil
                self.currentLabel = nil
                self.connectedPeerID = nil
                self.setConnected(false)
            }
            self.scheduleWatchdog()
        }
    }

    private func resetStreamState() {
        buffer.removeAll(keepingCapacity: true)
        formatDesc = nil
        sps = nil
        pps = nil
        lastFrameAt = nil
        frameIntervals.removeAll()
        decodeFlushes = 0
        displayLayer.flush()
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        decodeWindow.removeAll(keepingCapacity: true)
        photonWindow.removeAll(keepingCapacity: true)
    }

    // MARK: - Control messages (phone -> Mac)

    private func sendHello(on conn: NWConnection) {
        sendControl([
            "type": "hello",
            "pixelsWide": devicePixelsWide,
            "pixelsHigh": devicePixelsHigh,
            "scale": deviceScale,
            "device": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            "id": Self.installID,
            "pv": WireProtocol.version,   // issue #132 — absent on old receivers
        ], on: conn)
        Log.info("hello sent")
    }

    /// Touch events: x/y normalized [0,1] in video space, origin top-left.
    /// Stamped in *Mac* clock time (our clock + sync offset) so the Mac can
    /// measure touch→injection latency without doing its own clock sync.
    func sendTouch(phase: String, x: Double, y: Double) {
        var msg: [String: Any] = ["type": "touch", "phase": phase, "x": x, "y": y]
        if let offset = clockOffsetMs { msg["t"] = nowMs + offset }
        sendControl(msg)
    }

    /// Two-finger scroll: dx/dy in video pixels (natural-scrolling sign).
    func sendScroll(dx: Double, dy: Double) {
        sendControl(["type": "scroll", "dx": dx, "dy": dy])
    }

    private func sendControl(_ message: [String: Any], on conn: NWConnection? = nil) {
        guard let conn = conn ?? connection,
              let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { error in
            if let error { Log.info("control send error: \(error)") }
        })
    }

    // MARK: - Socket read + length-prefixed deframing

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastDataReceived = Date()
                self.bytesThisWindow += data.count
                self.buffer.append(data)
                self.drainFrames(on: conn)
            }
            if let error {
                Log.info("receive error: \(error)")
                return
            }
            if isComplete {
                Log.info("peer closed connection")
                self.setConnected(false)
                return
            }
            self.receive(on: conn)
        }
    }

    private func drainFrames(on conn: NWConnection) {
        // Cursor-based drain so we only compact the buffer once per batch.
        var cursor = buffer.startIndex
        while buffer.distance(from: cursor, to: buffer.endIndex) >= 4 {
            let len = buffer[cursor..<buffer.index(cursor, offsetBy: 4)]
                .withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            // Bound the length prefix so a corrupt/hostile value can't grow
            // `buffer` unboundedly — trickled bytes would otherwise keep
            // resetting the liveness watchdog while data piles up in memory.
            guard len <= Self.maxVideoFrameBytes else {
                Log.info("video frame length out of bounds (\(len)) — closing")
                conn.cancel()
                return
            }
            guard buffer.distance(from: cursor, to: buffer.endIndex) >= 4 + len else { break }
            let start = buffer.index(cursor, offsetBy: 4)
            let end = buffer.index(start, offsetBy: len)
            handleAnnexB(Data(buffer[start..<end]))
            cursor = end
        }
        buffer.removeSubrange(buffer.startIndex..<cursor)
    }

    // MARK: - Annex B -> CMSampleBuffer

    private func handleAnnexB(_ data: Data) {
        // Pure JSON payload = control message (pong, cursor sprite etc.).
        // Video frames also begin with '{' (telemetry prefix) but always
        // contain start codes — the null bytes make them unambiguous even
        // against multi-KB JSON (cursor sprites are base64, NUL-free).
        if data.count < 32_768, data.first == UInt8(ascii: "{"), !data.contains(0x00) {
            handleVideoChannelJSON(data)
            return
        }

        // Split on 4-byte start codes (our sender only emits 00 00 00 01).
        // Bytes before the FIRST start code are the telemetry prefix
        // ({"cap":…,"snd":…} stamped by the Mac).
        var nalus: [Data] = []
        var metaPrefix: Data?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var naluStart: Int? = nil
            var firstSC: Int? = nil
            var i = 0
            while i + 4 <= bytes.count {
                if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 {
                    if firstSC == nil { firstSC = i }
                    if let s = naluStart, s < i { nalus.append(Data(bytes[s..<i])) }
                    naluStart = i + 4
                    i += 4
                } else {
                    i += 1
                }
            }
            if let s = naluStart, s < bytes.count { nalus.append(Data(bytes[s...])) }
            if let f = firstSC, f > 0 { metaPrefix = Data(bytes[0..<f]) }
        }

        var captureMs: Double?
        var sendMs: Double?
        if let metaPrefix,
           let meta = try? JSONSerialization.jsonObject(with: metaPrefix) as? [String: Any] {
            captureMs = meta["cap"] as? Double
            sendMs = meta["snd"] as? Double
        }

        var vclNALUs: [Data] = []
        for nalu in nalus {
            guard let first = nalu.first else { continue }
            switch first & 0x1F {
            case 7:                                  // SPS (stream may change
                if sps != nalu {                     //  size on rotation)
                    sps = nalu
                    formatDesc = nil
                }
            case 8:                                  // PPS
                if pps != nalu {
                    pps = nalu
                    formatDesc = nil
                }
            case 6: break                            // SEI — skip
            default: vclNALUs.append(nalu)           // slice data
            }
        }
        if formatDesc == nil, let sps, let pps {
            displayLayer.flush()   // drop any frames from the previous format
            buildFormatDescription(sps: sps, pps: pps)
        }
        guard !vclNALUs.isEmpty else { return }
        // All slices of one wire frame go into ONE sample buffer.
        enqueueFrame(vclNALUs, captureMs: captureMs, sendMs: sendMs)
    }

    private func buildFormatDescription(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsBuf.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBuf.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                if status == noErr, let formatDesc {
                    let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
                    Log.info("format description built: \(dims.width)x\(dims.height)")
                    DispatchQueue.main.async {
                        self.videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
                    }
                    setStatus("Receiving \(dims.width)×\(dims.height)")
                } else {
                    Log.info("format description FAILED: \(status)")
                }
            }
        }
    }

    private func enqueueFrame(_ nalus: [Data], captureMs: Double? = nil, sendMs: Double? = nil) {
        guard let formatDesc else { return }

        // Build one AVCC buffer: each NALU prefixed with 4-byte big-endian length.
        var avcc = Data(capacity: nalus.reduce(0) { $0 + $1.count + 4 })
        for nalu in nalus {
            var len = UInt32(nalu.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nalu)
        }

        // Allocate a block buffer that OWNS its memory and copy the bytes in —
        // referencing a transient Swift buffer here is a use-after-free.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,                   // let CoreMedia allocate
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0,
                dataLength: avcc.count, flags: 0,
                blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return }
        let copyStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copyStatus == noErr else { return }

        var sample: CMSampleBuffer?
        var sizeArr = [avcc.count]
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr,
            sampleBufferOut: &sample)

        guard let sample else { return }

        if loggedDisplayPath != (useMetalPath && onDecodedFrame != nil) {
            loggedDisplayPath = useMetalPath && onDecodedFrame != nil
            Log.info("display path: metal=\(useMetalPath) sink=\(onDecodedFrame != nil)")
        }
        if useMetalPath, onDecodedFrame != nil {
            decodeAndRender(sample, captureMs: captureMs)
        } else {
            // Display immediately: low latency, no PTS scheduling.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }

            if displayLayer.status == .failed {
                Log.info("display layer failed (\(String(describing: displayLayer.error))) — flushing")
                decodeFlushes += 1
                displayLayer.flush()
            }
            displayLayer.enqueue(sample)
        }

        // Per-frame timing for the performance overlay.
        let now = Date()
        if let last = lastFrameAt {
            let ms = now.timeIntervalSince(last) * 1000
            frameIntervals.append(ms)
            if frameIntervals.count > maxSamples { frameIntervals.removeFirst() }
            if ms > 50 { stallsThisWindow += 1 }
        }
        lastFrameAt = now

        // True end-to-end latency: Mac capture timestamp vs our clock mapped
        // onto the Mac's via the ping/pong offset.
        if let captureMs, let sendMs {
            encodeWindow.append(sendMs - captureMs)
            if let offset = clockOffsetMs {
                let e2e = (nowMs + offset) - captureMs
                if e2e > -50, e2e < 5000 {
                    e2eWindow.append(e2e)
                    e2eRing.append(max(e2e, 0))
                    if e2eRing.count > maxSamples { e2eRing.removeFirst() }
                }
            }
        }

        framesThisWindow += 1
        let elapsed = now.timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            let fps = Int(Double(framesThisWindow) / elapsed)
            var stats = PerfStats()
            stats.fps = fps
            stats.mbps = Double(bytesThisWindow) * 8 / elapsed / 1_000_000
            stats.samples = frameIntervals
            if !frameIntervals.isEmpty {
                stats.avgFrameMs = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
                stats.maxFrameMs = frameIntervals.max() ?? 0
            }
            stats.stalls = stallsThisWindow
            stats.decodeFlushes = decodeFlushes
            stats.e2eP50 = percentile(e2eWindow, 0.5)
            stats.e2eP95 = percentile(e2eWindow, 0.95)
            stats.encodeP50 = percentile(encodeWindow, 0.5)
            stats.rttMs = lastRttMs
            stats.e2eSamples = e2eRing
            stats.transport = transport
            stats.macDrops = macDrops
            stats.macPending = macPending
            stats.inputP50 = macInputP50
            stats.inputP95 = macInputP95
            stats.capFps = macCapFps
            stats.decodeP50 = percentile(decodeWindow, 0.5)
            stats.photonP50 = percentile(photonWindow, 0.5)
            stats.photonP95 = percentile(photonWindow, 0.95)
            framesThisWindow = 0
            bytesThisWindow = 0
            stallsThisWindow = 0
            fpsWindowStart = now

            // Every 5s, report the aggregate to the Mac so its log holds the
            // full pipeline picture for offline analysis.
            statsReportCounter += 1
            if statsReportCounter >= 5 {
                statsReportCounter = 0
                sendControl([
                    "type": "stats",
                    "transport": transport,
                    "fps": fps,
                    "mbps": (stats.mbps * 10).rounded() / 10,
                    "e2e50": stats.e2eP50.rounded(),
                    "e2e95": stats.e2eP95.rounded(),
                    "enc50": stats.encodeP50.rounded(),
                    "rtt": lastRttMs.rounded(),
                    "stalls": stats.stalls,
                    "inp50": macInputP50.rounded(),
                    "capFps": macCapFps,
                    "dec50": stats.decodeP50.rounded(),
                    "ph50": stats.photonP50.rounded(),
                    "ph95": stats.photonP95.rounded(),
                    "offsetKnown": clockOffsetMs != nil,
                ])
                e2eWindow.removeAll(keepingCapacity: true)
                encodeWindow.removeAll(keepingCapacity: true)
                decodeWindow.removeAll(keepingCapacity: true)
                photonWindow.removeAll(keepingCapacity: true)
            }

            DispatchQueue.main.async {
                self.fps = fps
                self.perf = stats
            }
        }
    }

    // MARK: - Explicit decode (Metal renderer path)

    private func ensureDecompressionSession() {
        guard let formatDesc else { return }
        if let session = decompressionSession {
            if VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: formatDesc) {
                return
            }
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        // NV12: the decoder's native output — BGRA would add a conversion
        // pass inside VideoToolbox (measured ~7ms); the YUV→RGB happens in
        // the renderer's fragment shader instead (~free).
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: formatDesc, decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &session)
        if status != noErr { Log.info("VTDecompressionSessionCreate failed: \(status)") }
        decompressionSession = session
    }

    /// Synchronous hardware decode — the handler runs before this returns,
    /// so blocking in the renderer (nextDrawable) is our frame pacing.
    private func decodeAndRender(_ sample: CMSampleBuffer, captureMs: Double?) {
        ensureDecompressionSession()
        guard let session = decompressionSession else { return }
        let t0 = nowMs
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            if status == noErr, let imageBuffer {
                self.decodeWindow.append(self.nowMs - t0)
                self.onDecodedFrame?(imageBuffer, captureMs)
            } else {
                if self.decodeErrorCount % 60 == 0 {
                    Log.info("decode output error: \(status) imageBuffer=\(imageBuffer != nil)")
                }
                self.decodeErrorCount += 1
                // Joined mid-GOP (e.g. the renderer attached after the
                // connect-time IDR, and periodic keyframes are off) — ask
                // the Mac for a fresh sync point.
                self.requestKeyframeIfNeeded()
            }
        }
        if status != noErr {
            decodeFlushes += 1
            decodeErrorCount += 1
            if decodeErrorCount % 60 == 1 {
                Log.info("decode call error: \(status) (\(decodeErrorCount) total)")
            }
            requestKeyframeIfNeeded()
        }
    }

    private var lastKeyframeRequest = Date.distantPast
    private func requestKeyframeIfNeeded() {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 1 else { return }
        lastKeyframeRequest = Date()
        Log.info("requesting keyframe (decoder needs sync)")
        sendControl(["type": "kf"])
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[idx]
    }

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        Log.info("status: \(text)")
        DispatchQueue.main.async { self.status = text }
    }

    private func setConnected(_ value: Bool) {
        DispatchQueue.main.async { self.connected = value }
        if !value { setStatus("Waiting for your Mac to connect…") }
        else {
            setStatus("Connected")
            // Remember the first ever successful connection to a Mac so the
            // first-run onboarding hint never reappears (issue #49).
            if !UserDefaults.standard.bool(forKey: "hasConnectedBefore") {
                UserDefaults.standard.set(true, forKey: "hasConnectedBefore")
            }
        }
    }
}
