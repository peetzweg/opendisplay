// DisplayReceiver — the Mac counterpart of iOS/PhoneReceiver.swift: receive
// H.264 over TCP and display it, turning this Mac into a second monitor for
// another Mac running the OpenDisplay sender.
//
// Pipeline:  TCP socket -> deframe -> Annex B parse -> CMSampleBuffer
//            -> AVSampleBufferDisplayLayer (decodes + renders)
//
// The receiver LISTENS; the sender Mac connects — same wire protocol and
// ordering as the iOS app, so the unmodified sender discovers this Mac over
// Bonjour exactly like an iPhone. Wire: [4-byte big-endian length][payload].
//
// Deliberately kept close to PhoneReceiver so protocol fixes port both ways;
// iOS-only concerns (backgrounding, rotation, the Metal path) are dropped.

import Foundation
import Network
import AVFoundation
import CoreMedia
import AppKit
import VideoToolbox

/// One-second window of pipeline health for the HUD overlay.
struct PerfStats: Equatable {
    var fps = 0
    var mbps = 0.0
    var avgFrameMs = 0.0
    var maxFrameMs = 0.0
    var stalls = 0               // frames that arrived >50ms late (this window)
    var decodeFlushes = 0        // display layer failures since connect
    var samples: [Double] = []   // last ~120 inter-frame intervals, ms
    // True end-to-end latency (sender capture → display handoff), using the
    // clock offset estimated from timestamped ping/pong.
    var e2eP50 = 0.0
    var e2eP95 = 0.0
    var encodeP50 = 0.0          // sender-side capture→socket (encode + queue)
    var rttMs = 0.0              // control-channel round trip
    var e2eSamples: [Double] = []  // last ~120 per-frame e2e latencies, ms
    var transport = "—"
    var macDrops = 0             // enc + net drops (legacy total)
    var macEncDrops = 0          // sender skipped capture: encoder busy
    var macNetDrops = 0          // sender skipped capture: TCP queue full
    var macPending = 0           // sender send queue depth right now
    var inputP50 = 0.0           // input sent → CGEvent injected on the sender, ms
    var inputP95 = 0.0
    var capFps = 0               // frames ScreenCaptureKit delivered on the sender
}

final class DisplayReceiver: ObservableObject {

    @Published var status = "Starting…"
    @Published var fps = 0
    @Published var connected = false
    @Published var videoSize = CGSize.zero   // for input coordinate mapping
    @Published var perf = PerfStats()
    // Compatibility signal from the connected sender (issue #132). This build
    // speaks the current protocol, so it should never fire — surfaced anyway
    // in case a far-future sender raises its floor past us.
    @Published var peerMessage: String?

    private var listener: NWListener?
    private var cursorListener: NWListener?
    private var cursorConnection: NWConnection?
    private var listenerHealthy = false
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "receiver.video")
    private var buffer = Data()
    private var formatDesc: CMVideoFormatDescription?
    private enum StreamCodec { case h264, hevc, prores4444, prores4444XQ }
    private var codec = StreamCodec.h264
    private var peerProtocolVersion = WireProtocol.assumedWhenAbsent
    // Parameter sets, ordered as received. Arrays, not single values: the
    // sender's low-latency static-refresh HEVC session emits one VPS, one
    // SPS and FOUR PPS entries with distinct ids — keeping only the last
    // PPS made every refresh IDR undecodable (-12909).
    private var vpsSets: [Data] = [] // HEVC only
    private var spsSets: [Data] = []
    private var ppsSets: [Data] = []

    // Liveness: the sender streams video and pings every 2s; if nothing
    // arrives for 5s the connection is half-open — drop it so the listener
    // can accept a fresh one.
    private var lastDataReceived = Date()
    private var port: UInt16 = 9000
    private let cursorPort: UInt16 = 9001
    private var lastCursorDatagramSequence: UInt64 = 0
    private var monitorsStarted = false

    private var framesThisWindow = 0
    private var fpsWindowStart = Date()
    private var bytesThisWindow = 0
    private var stallsThisWindow = 0
    private var decodeFlushes = 0
    private var lastFrameAt: Date?
    private var frameIntervals: [Double] = []   // ring buffer, ms
    private let maxSamples = 120

    // Clock sync (NTP-style): offset = senderClock − ourClock, taken from the
    // ping/pong sample with the lowest RTT (least asymmetric).
    private var offsetSamples: [(rtt: Double, offset: Double)] = []
    private var clockOffsetMs: Double?
    private var lastRttMs = 0.0
    private var e2eWindow: [Double] = []        // capture→display, ms
    private var encodeWindow: [Double] = []     // capture→socket on the sender, ms
    private var e2eRing: [Double] = []          // per-frame, for the HUD graph
    private var statsReportCounter = 0
    private var transport = "—"
    private var macDrops = 0
    private var macEncDrops = 0
    private var macNetDrops = 0
    private var macPending = 0
    private var macInputP50 = 0.0
    private var macInputP95 = 0.0
    private var macCapFps = 0
    private var destinationColorDiagnostic = "window-unavailable"

    private var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    // Local cursor echo (both called on the main thread): position is
    // normalized [0,1] in video space; the sprite arrives as a PNG with its
    // hotspot anchor and size normalized against the sender display.
    var onCursor: ((_ x: Double, _ y: Double, _ visible: Bool) -> Void)?
    var onCursorImage: ((_ image: NSImage, _ anchor: CGPoint, _ normSize: CGSize) -> Void)?
    // Explicit VideoToolbox + Metal remains available in the source for
    // diagnostics, but production presentation follows upstream OpenDisplay:
    // AVSampleBufferDisplayLayer lets the system decoder/compositor perform
    // the final ColorSync conversion into the receiver display's active ICC.
    var onDecodedFrame: ((_ pixelBuffer: CVPixelBuffer) -> Void)?
    private var decompressionSession: VTDecompressionSession?
    private var decodeErrorCount = 0

    let displayLayer: AVSampleBufferDisplayLayer
    let metalRenderer: MetalVideoRenderer?

    /// Announced panel size in pixels + scale, sent to the sender in a
    /// "hello" message so it can size the virtual display (it creates
    /// pixels/2 points at @2x HiDPI). Set before start(); setPanel() with new
    /// dimensions re-announces and the sender rebuilds the virtual display.
    private(set) var devicePixelsWide = 0
    private(set) var devicePixelsHigh = 0
    var deviceScale: Double = 2
    private(set) var deviceColorSpace = WireColorSpace.sRGB
    private(set) var deviceICCProfileData: Data?
    // Name advertised over Bonjour for the sender's device picker.
    var serviceName = Host.current().localizedName ?? "Mac"

    // Stable per-install identity, advertised in the Bonjour TXT record and
    // sent in every hello. The sender uses it to recognize the device across
    // reconnects and to persist display arrangement (#116).
    static let installID: String = {
        if let existing = UserDefaults.standard.string(forKey: "installID") {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "installID")
        return fresh
    }()

    /// Detect this Mac's Thunderbolt bridge address (normally the link-local
    /// IPv4 on bridge*). During cable bring-up IPv6 can appear slightly before
    /// IPv4, so keep a scoped IPv6 address as a fallback instead of omitting
    /// the low-latency cursor endpoint from the initial hello.
    private static var bridgeIP: String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(first) }
        var ipv6Fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr?.pointee {
            let name = String(cString: iface.ifa_name)
            if name.hasPrefix("bridge"), (iface.ifa_flags & UInt32(IFF_UP)) != 0 {
                if let sa = iface.ifa_addr,
                   sa.pointee.sa_family == sa_family_t(AF_INET)
                    || sa.pointee.sa_family == sa_family_t(AF_INET6) {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                   &buf, socklen_t(buf.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let address = String(cString: buf)
                        if sa.pointee.sa_family == sa_family_t(AF_INET) {
                            return address
                        }
                        if ipv6Fallback == nil { ipv6Fallback = address }
                    }
                }
            }
            ptr = iface.ifa_next
        }
        return ipv6Fallback
    }

    private var advertisedService: NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = Self.installID
        txt["pv"] = String(WireProtocol.version)   // issue #132
        if let ip = Self.bridgeIP { txt["ip"] = ip }
        return NWListener.Service(name: serviceName, type: "_opensidecar._tcp",
                                  domain: nil, txtRecord: txt)
    }

    /// Update the advertised name and re-publish if already listening.
    func setServiceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? (Host.current().localizedName ?? "Mac") : trimmed
        queue.async {
            guard resolved != self.serviceName else { return }
            self.serviceName = resolved
            if self.listener != nil {
                self.listener?.service = self.advertisedService
                Log.info("re-advertising as \"\(resolved)\"")
            }
        }
    }

    /// Set (or change) the announced panel size. A change while connected
    /// re-sends hello and the sender rebuilds the virtual display — the Mac
    /// analogue of the iOS rotation path (screen swap, resolution setting).
    func setPanel(pixelsWide: Int, pixelsHigh: Int, scale: Double,
                  colorSpace: WireColorSpace, iccProfileData: Data?) {
        queue.async {
            guard pixelsWide > 0, pixelsHigh > 0,
                  pixelsWide != self.devicePixelsWide
                  || pixelsHigh != self.devicePixelsHigh
                  || scale != self.deviceScale
                  || colorSpace != self.deviceColorSpace
                  || iccProfileData != self.deviceICCProfileData else { return }
            let announced = self.devicePixelsWide != 0
            self.devicePixelsWide = pixelsWide
            self.devicePixelsHigh = pixelsHigh
            self.deviceScale = scale
            self.deviceColorSpace = colorSpace
            self.deviceICCProfileData = iccProfileData
            self.metalRenderer?.setNegotiatedSourceColorSpace(
                self.peerProtocolVersion >= 3 ? colorSpace : nil)
            self.metalRenderer?.setDeviceICCPassthrough(
                self.peerProtocolVersion >= 5 && iccProfileData != nil)
            if announced {
                Log.info("panel changed -> \(pixelsWide)x\(pixelsHigh) \(colorSpace.rawValue)")
            }
            if let connection = self.connection, connection.state == .ready {
                self.sendHello(on: connection)
            }
        }
    }

    /// Records the final AppKit/ColorSync destination separately from the
    /// decoded frame's source space, and returns it to the sender in stats.
    func setDestinationColorDiagnostic(_ description: String) {
        queue.async { self.destinationColorDiagnostic = description }
    }

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        // AVSampleBufferDisplayLayer can promote desktop content into the
        // macOS video-overlay path. That path is excellent for ordinary
        // Rec.709 movies, but on a wide-gamut desktop it may bypass the
        // window's normal ColorSync composition and look grey even when the
        // stream carries correct P3/ICC metadata. Decode to retained 10-bit
        // RGB and perform one explicit Display-P3 -> active-display-ICC
        // conversion instead. MetalVideoRenderer keeps a latest-wins frame
        // slot, so this does not add an unbounded presentation queue.
        let renderer = MetalVideoRenderer()
        metalRenderer = renderer
        if let renderer {
            onDecodedFrame = { [weak renderer] pixelBuffer in
                renderer?.render(pixelBuffer)
            }
            Log.info("display path: explicit 10-bit Metal + Core Image ColorSync")
        } else {
            Log.info("display path: AVSampleBufferDisplayLayer fallback (Metal unavailable)")
        }
    }

    func start(port: UInt16 = 9000) {
        self.port = port
        queue.async {
            self.startListener()
            self.startCursorListener()
        }
        if !monitorsStarted {
            monitorsStarted = true
            schedulePing()
            scheduleWatchdog()
        }
    }

    /// Recreate the listener if it isn't healthy — called on wake (enterSleep
    /// deliberately took it down when the display went dark).
    func ensureListening() {
        queue.async {
            guard !self.listenerHealthy else { return }
            Log.info("listener not healthy — restarting")
            self.restartListener()
        }
    }

    /// The screen went dark (display sleep / system sleep) — nobody can see
    /// the stream, so tell the sender and go silent. Sends "sleeping" (the
    /// sender drops its virtual display so the cursor isn't stranded on an
    /// invisible screen and arms a reconnect), then closes the connection AND
    /// the listener: while asleep we must not accept connections, or the
    /// sender's wake retries would rebuild the display before anyone can see
    /// it. ensureListening() re-arms everything on wake.
    func enterSleep(completion: (() -> Void)? = nil) {
        closeSession(announcing: WireMessage.sleeping,
                     status: "Asleep — resumes on wake", completion: completion)
    }

    /// The app is quitting. Same close, but announced as "closing": quitting
    /// is deliberate, so the sender ends the session without waiting around.
    func shutDown(completion: (() -> Void)? = nil) {
        closeSession(announcing: WireMessage.closing,
                     status: "Closed", completion: completion)
    }

    private func closeSession(announcing type: String, status: String,
                              completion: (() -> Void)?) {
        queue.async {
            var finished = false
            let finish = { [weak self] in
                guard let self, !finished else { return }
                finished = true
                self.connection?.cancel()
                self.connection = nil
                self.listener?.cancel()
                self.listener = nil
                self.cursorConnection?.cancel()
                self.cursorConnection = nil
                self.cursorListener?.cancel()
                self.cursorListener = nil
                self.listenerHealthy = false
                self.setConnected(false)
                self.setStatus(status)
                completion?()
            }
            guard let conn = self.connection, conn.state == .ready else {
                Log.info("closing session (\(type)) — no live connection")
                finish()
                return
            }
            Log.info("closing session — announcing \(type) to the sender")
            self.sendControl(["type": type], on: conn) {
                self.queue.async { finish() }
            }
            // The send completion may never fire on a dying link — don't
            // let that keep us accepting connections after going dark.
            self.queue.asyncAfter(deadline: .now() + 1) { finish() }
        }
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        cursorConnection?.cancel()
        cursorConnection = nil
        cursorListener?.cancel()
        cursorListener = nil
        listenerHealthy = false
        startListener()
        startCursorListener()
    }

    /// Cursor positions use a tiny UDP side channel so a multi-megabyte
    /// ProRes frame on the ordered TCP video stream cannot delay pointer
    /// motion. Loss is harmless (the next 120Hz position supersedes it), and
    /// the original TCP cursor messages remain the compatibility fallback.
    private func startCursorListener() {
        guard cursorListener == nil,
              let port = NWEndpoint.Port(rawValue: cursorPort) else { return }
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true
            params.serviceClass = .responsiveData
            cursorListener = try NWListener(using: params, on: port)
        } catch {
            Log.info("cursor UDP listener failed: \(error)")
            return
        }
        cursorListener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.cursorConnection?.cancel()
            self.cursorConnection = conn
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    Log.info("cursor UDP channel ready from \(String(describing: conn.endpoint))")
                }
            }
            conn.start(queue: self.queue)
            self.receiveCursorDatagrams(on: conn)
        }
        cursorListener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.info("cursor UDP listener ready on :\(self.cursorPort)")
            case .failed(let error):
                Log.info("cursor UDP listener failed: \(error)")
            default:
                break
            }
        }
        cursorListener?.start(queue: queue)
    }

    private func receiveCursorDatagrams(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if self.cursorConnection === conn,
               let data, !data.isEmpty,
               self.connection?.state == .ready,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["type"] as? String == "cursor" {
                let sequence = (obj["s"] as? NSNumber)?.uint64Value ?? 0
                if sequence == 0 || sequence > self.lastCursorDatagramSequence {
                    if sequence > 0 { self.lastCursorDatagramSequence = sequence }
                    let visible = (obj["v"] as? Int ?? 0) == 1
                    let x = obj["x"] as? Double ?? 0
                    let y = obj["y"] as? Double ?? 0
                    DispatchQueue.main.async { self.onCursor?(x, y, visible) }
                }
            }
            if let error {
                Log.info("cursor UDP receive error: \(error)")
                return
            }
            self.receiveCursorDatagrams(on: conn)
        }
    }

    private func startListener() {
        do {
            // noDelay matters most in THIS direction: input events are tiny
            // packets, and Nagle would hold each one until the previous is
            // ACKed — batched, late drags read as input lag.
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true
            params.serviceClass = .interactiveVideo
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            setStatus("Listener failed: \(error.localizedDescription)")
            return
        }
        // Advertise on the local network so the sender can discover us.
        listener?.service = advertisedService
        listener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Log.info("new connection from \(String(describing: conn.endpoint))")
            // Loopback would be a tunnel/-host dial; anything else is LAN.
            let peer = String(describing: conn.endpoint)
            self.transport = (peer.hasPrefix("127.0.0.1") || peer.hasPrefix("::1")
                              || peer.hasPrefix("localhost")) ? "USB" : "WiFi"
            // Replace any existing connection and reset decoder state. A
            // stale compatibility complaint dies with the peer it was about.
            self.connection?.cancel()
            self.connection = conn
            self.lastCursorDatagramSequence = 0
            self.resetStreamState()
            DispatchQueue.main.async { self.peerMessage = nil }
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.lastDataReceived = Date()
                    self?.setConnected(true)
                    self?.sendHello(on: conn, cursorRetryAttempt: 0)
                    self?.scheduleDarkStreamNudge(on: conn, attempt: 0)
                case .failed, .cancelled:
                    self?.setConnected(false)
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.receive(on: conn)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.listenerHealthy = true
                self.setStatus("Listening on :\(self.port)")
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

    /// JSON on the video channel (pong, cursor, welcome…) — payloads starting '{'.
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
            // Dark-stream diagnostics: while no video has arrived, the
            // sender's ping is the only window into its pipeline — log it
            // verbatim (capFps > 0 with no video = frames die in encode).
            if formatDesc == nil, let line = String(data: data, encoding: .utf8) {
                Log.info("sender ping while dark: \(line)")
            }
            // The sender piggybacks its send-side health on liveness pings.
            if let enc = obj["encDrops"] as? Int {
                macEncDrops = enc
            } else if let drops = obj["drops"] as? Int {
                macEncDrops = drops
            }
            if let net = obj["netDrops"] as? Int {
                macNetDrops = net
            }
            macDrops = macEncDrops + macNetDrops
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
                  let image = NSImage(data: png),
                  let nw = obj["nw"] as? Double, let nh = obj["nh"] as? Double else { return }
            let anchor = CGPoint(x: obj["ax"] as? Double ?? 0, y: obj["ay"] as? Double ?? 0)
            let normSize = CGSize(width: nw, height: nh)
            DispatchQueue.main.async { self.onCursorImage?(image, anchor, normSize) }
        case WireMessage.welcome:
            // The sender identified itself (issue #132). If it speaks a
            // protocol older than we support, it's the sender that needs
            // updating — an old sender can't diagnose that itself.
            let macPV = obj["pv"] as? Int ?? WireProtocol.assumedWhenAbsent
            peerProtocolVersion = macPV
            metalRenderer?.setNegotiatedSourceColorSpace(
                macPV >= 3 ? deviceColorSpace : nil)
            metalRenderer?.setDeviceICCPassthrough(
                macPV >= 5 && deviceICCProfileData != nil)
            if macPV < WireProtocol.minSupportedPeer {
                let msg = "The OpenDisplay app on the sending Mac is too old for this receiver. Update OpenDisplay there to reconnect."
                DispatchQueue.main.async { self.peerMessage = msg }
            }
        case WireMessage.updateRequired:
            // The sender refuses this pairing until the receiver updates.
            // This build is self-updated (rebuilt from source) — surface the
            // message rather than deep-linking an App Store that isn't ours.
            let message = obj["message"] as? String
                ?? "This receiver speaks an older protocol than the sending Mac supports. Update it from the OpenDisplay repository."
            DispatchQueue.main.async { self.peerMessage = message }
        default:
            break
        }
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if let conn = self.connection, conn.state == .ready,
               Date().timeIntervalSince(self.lastDataReceived) > 5 {
                Log.info("watchdog: nothing from the sender for >5s — dropping connection")
                conn.cancel()
                self.connection = nil
                self.setConnected(false)
            }
            self.scheduleWatchdog()
        }
    }

    private func resetStreamState() {
        buffer.removeAll(keepingCapacity: true)
        formatDesc = nil
        codec = .h264
        peerProtocolVersion = WireProtocol.assumedWhenAbsent
        metalRenderer?.setNegotiatedSourceColorSpace(nil)
        metalRenderer?.setDeviceICCPassthrough(false)
        vpsSets.removeAll()
        spsSets.removeAll()
        ppsSets.removeAll()
        lastFrameAt = nil
        frameIntervals.removeAll()
        decodeFlushes = 0
        decodeErrorCount = 0
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }
        // Remove the previous session's picture entirely: a fresh session
        // that sends no video yet must show the idle view, not a frozen
        // frame the user mistakes for a live (unclickable) desktop.
        displayLayer.flushAndRemoveImage()
        DispatchQueue.main.async { self.videoSize = .zero }
    }

    // MARK: - Control messages (receiver -> sender)

    private func sendHello(on conn: NWConnection, cursorRetryAttempt: Int = 0) {
        let version = Bundle.main.object(forInfoDictionaryKey:
            "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey:
            "CFBundleVersion") as? String ?? "unknown"
        let renderPath = metalRenderer == nil ? "avsamplebuffer" : "metal-device-icc"
        // AVSampleBufferDisplayLayer may be promoted to a separate WindowServer
        // plane, where an independently animated cursor layer caused flashes and
        // trails on some Macs. The normal Metal renderer stays in the same Core
        // Animation tree, so it can safely use the low-latency local cursor path.
        let cursorInVideo = metalRenderer == nil
        // XQ roughly doubles the already-large 4.5K 4:4:4 stream without a
        // visible improvement on the target iMac. Keep it as an opt-in diagnostic
        // mode; ordinary ProRes 4444 remains 10-bit 4:4:4 and preserves the exact
        // device-ICC passthrough path with substantially less network pressure.
        let proRes4444XQ = UserDefaults.standard.bool(forKey: "enableProRes4444XQ")
        var hello: [String: Any] = [
            "type": "hello",
            "pixelsWide": devicePixelsWide,
            "pixelsHigh": devicePixelsHigh,
            "scale": deviceScale,
            "device": "Mac",
            "id": Self.installID,
            "pv": WireProtocol.version,   // issue #132
            "receiverVersion": version,
            "receiverBuild": build,
            "renderPath": renderPath,
            "colorSpace": deviceColorSpace.rawValue,
            "cursorInVideo": cursorInVideo,
            // HEVC keeps a 24-inch iMac at its native 4480×2520 stream size.
            // The earlier colored blocks came from direct NV12 plane sampling;
            // this receiver now decodes to retained BGRA before Metal display.
            "hevc": true,
            // Protocol 4: frame-delimited Apple ProRes 4444. The sender only
            // selects it when both apps advertise support, otherwise the
            // existing HEVC stream remains wire-compatible.
            "prores4444": true,
            // XQ materially reduces low-amplitude luma/chroma quantisation
            // around flat neutral greys. A sender that does not understand
            // this optional offer simply continues using ordinary 4444.
            "prores4444XQ": proRes4444XQ,
        ]
        let cursorHost = Self.bridgeIP
        if let cursorHost {
            hello["cursorHost"] = cursorHost
            hello["cursorPort"] = Int(cursorPort)
        }
        if let deviceICCProfileData {
            hello["iccProfile"] = deviceICCProfileData.base64EncodedString()
        }
        sendControl(hello, on: conn)
        let cursorHostDiagnostic = cursorHost ?? "pending"
        Log.info("hello sent: \(devicePixelsWide)x\(devicePixelsHigh) @\(deviceScale)x "
            + "color=\(deviceColorSpace.rawValue) ICC=\(deviceICCProfileData?.count ?? 0)B "
            + "cursorInVideo=\(cursorInVideo) cursorHost=\(cursorHostDiagnostic) "
            + "prores4444=true prores4444XQ=\(proRes4444XQ) "
            + "receiver=\(version)(\(build)) "
            + "render=\(renderPath)")

        // bridge0 can have a usable Bonjour path before getifaddrs exposes
        // its link-local address. Previously that one unlucky hello left the
        // whole session on the ordered ProRes/TCP stream, adding ~45ms and
        // making the cursor visibly skip. Re-announce for a short bounded
        // window; the sender treats identical hellos idempotently.
        if cursorHost == nil, cursorRetryAttempt < 6 {
            let delay = min(0.5 + Double(cursorRetryAttempt) * 0.5, 2.0)
            queue.asyncAfter(deadline: .now() + delay) { [weak self, weak conn] in
                guard let self, let conn,
                      self.connection === conn, conn.state == .ready else { return }
                self.sendHello(on: conn, cursorRetryAttempt: cursorRetryAttempt + 1)
            }
        }
    }

    /// Pointer events mapped onto the wire's touch vocabulary: x/y normalized
    /// [0,1] in video space, origin top-left. "moved" without a preceding
    /// "began" is a pure cursor move on the sender (hover); began/moved/ended
    /// is a click-drag. Stamped in *sender* clock time (our clock + sync
    /// offset) so the sender can measure input latency without its own sync.
    func sendTouch(phase: String, x: Double, y: Double) {
        var msg: [String: Any] = ["type": "touch", "phase": phase, "x": x, "y": y]
        if let offset = clockOffsetMs { msg["t"] = nowMs + offset }
        sendControl(msg)
    }

    /// Announces whether the receiver's local hardware pointer is currently
    /// driving the remote surface. The sender uses this to stop its sampled
    /// cursor echo from fighting the receiver's zero-latency local position.
    func sendPointerPresence(inside: Bool) {
        sendControl(["type": "pointerPresence", "inside": inside])
    }

    /// Scroll: dx/dy in video pixels (natural-scrolling sign).
    func sendScroll(dx: Double, dy: Double) {
        sendControl(["type": "scroll", "dx": dx, "dy": dy])
    }

    private func sendControl(_ message: [String: Any], on conn: NWConnection? = nil,
                             completion: (() -> Void)? = nil) {
        guard let conn = conn ?? connection,
              let payload = try? JSONSerialization.data(withJSONObject: message) else {
            completion?()
            return
        }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { error in
            if let error { Log.info("control send error: \(error)") }
            completion?()
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
                self.drainFrames()
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

    private func drainFrames() {
        // Cursor-based drain so we only compact the buffer once per batch.
        var cursor = buffer.startIndex
        while buffer.distance(from: cursor, to: buffer.endIndex) >= 4 {
            let len = buffer[cursor..<buffer.index(cursor, offsetBy: 4)]
                .withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard buffer.distance(from: cursor, to: buffer.endIndex) >= 4 + len else { break }
            let start = buffer.index(cursor, offsetBy: 4)
            let end = buffer.index(start, offsetBy: len)
            handleVideoPayload(Data(buffer[start..<end]))
            cursor = end
        }
        buffer.removeSubrange(buffer.startIndex..<cursor)
    }

    // MARK: - Compressed video -> CMSampleBuffer

    private func handleVideoPayload(_ data: Data) {
        // ProRes frames use one JSON metadata line followed by the complete
        // compressed frame. A newline delimiter is safe because compressed
        // bytes begin only after the first line; legacy Annex-B framing is
        // left untouched.
        if data.first == UInt8(ascii: "{"),
           let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            let metaData = data[..<newline]
            if let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
               let codecName = meta["codec"] as? String,
               codecName == "prores4444" || codecName == "prores4444xq",
               let width = meta["w"] as? Int,
               let height = meta["h"] as? Int {
                let frameStart = data.index(after: newline)
                handleProRes4444(Data(data[frameStart...]), width: width, height: height,
                                 xq: codecName == "prores4444xq",
                                 captureMs: meta["cap"] as? Double,
                                 sendMs: meta["snd"] as? Double)
                return
            }
        }
        handleAnnexB(data)
    }

    private func handleProRes4444(_ data: Data, width: Int, height: Int, xq: Bool,
                                  captureMs: Double?, sendMs: Double?) {
        guard !data.isEmpty, width > 0, height > 0 else { return }
        let dimensionsChanged: Bool
        if let formatDesc {
            let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
            dimensionsChanged = dims.width != width || dims.height != height
        } else {
            dimensionsChanged = true
        }
        let requestedCodec: StreamCodec = xq ? .prores4444XQ : .prores4444
        if codec != requestedCodec || dimensionsChanged {
            codec = requestedCodec
            formatDesc = nil
            if onDecodedFrame == nil { displayLayer.flush() }
            // Always provide the named metadata as well as the exact ICC.
            // With ICC alone, VideoToolbox guesses Rec.709 primaries and
            // transfer for ProRes, creating conflicting colour information
            // and a visibly grey/incorrect result on a Display P3 iMac.
            var extensions: [CFString: Any] = [
                kCMFormatDescriptionExtension_ColorPrimaries:
                    deviceColorSpace == .displayP3
                        ? kCMFormatDescriptionColorPrimaries_P3_D65
                        : kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                kCMFormatDescriptionExtension_TransferFunction:
                    kCMFormatDescriptionTransferFunction_sRGB,
                kCMFormatDescriptionExtension_YCbCrMatrix:
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
            ]
            if let deviceICCProfileData {
                extensions[kCMFormatDescriptionExtension_ICCProfile] = deviceICCProfileData as CFData
            }
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: xq
                    ? kCMVideoCodecType_AppleProRes4444XQ
                    : kCMVideoCodecType_AppleProRes4444,
                width: Int32(width), height: Int32(height),
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &formatDesc)
            guard status == noErr else {
                Log.info("ProRes 4444\(xq ? " XQ" : "") format description FAILED: \(status)")
                return
            }
            DispatchQueue.main.async {
                self.videoSize = CGSize(width: width, height: height)
            }
            setStatus("Receiving \(width)×\(height) (ProRes 4444\(xq ? " XQ" : ""))")
            let primaries = deviceColorSpace == .displayP3 ? "P3-D65" : "Rec.709"
            Log.info("format description built (ProRes 4444\(xq ? " XQ" : "")): \(width)x\(height) ICC=\(deviceICCProfileData?.count ?? 0)B primaries=\(primaries) transfer=sRGB matrix=BT.709")
        }
        enqueueCompressedFrame(data, captureMs: captureMs, sendMs: sendMs)
    }

    private func handleAnnexB(_ data: Data) {
        // Pure JSON payload = control message (pong, cursor sprite etc.).
        // Video frames also begin with '{' (telemetry prefix) but always
        // contain start codes — the null bytes make them unambiguous even
        // against multi-KB JSON (cursor sprites are base64, NUL-free).
        if data.count < 32_768, data.first == UInt8(ascii: "{"), !data.contains(0x00) {
            handleVideoChannelJSON(data)
            return
        }

        // Split on 4-byte start codes (the sender only emits 00 00 00 01).
        // Bytes before the FIRST start code are the telemetry prefix
        // ({"cap":…,"snd":…} stamped by the sender).
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
        // Parameter sets carried by THIS wire frame (keyframes only). They
        // are compared and applied as a group after the parse loop — the
        // refresh stream carries several PPS ids per keyframe, so per-NALU
        // "replace the single stored PPS" logic would keep only the last.
        var frameVPS: [Data] = []
        var frameSPS: [Data] = []
        var framePPS: [Data] = []
        for nalu in nalus {
            guard let first = nalu.first else { continue }
            let h264Type = first & 0x1F              // 5-bit H.264 nal type
            let hevcType = (first >> 1) & 0x3F       // 6-bit HEVC nal type
            // Codec auto-detect on parameter sets only. First bytes alone
            // are ambiguous — an HEVC IDR_N_LP slice (0x28) reads as an
            // H.264 PPS — but parameter sets are tiny while slices are KBs,
            // so only small NALUs may switch the codec: HEVC VPS/SPS/PPS
            // (0x40/0x42/0x44) read as H.264 types 0/2/4 (never emitted),
            // and H.264 SPS/PPS (0x67/0x68) read as HEVC 51/52 (invalid).
            if nalu.count < 128 {
                if (32...34).contains(hevcType), h264Type != 7, h264Type != 8 {
                    codec = .hevc
                } else if h264Type == 7 || h264Type == 8, !(32...34).contains(hevcType) {
                    codec = .h264
                }
            }
            switch codec {
            case .h264:
                switch h264Type {
                case 7: frameSPS.append(nalu)        // SPS
                case 8: framePPS.append(nalu)        // PPS
                case 6: break                        // SEI — skip
                default: vclNALUs.append(nalu)       // slice data
                }
            case .hevc:
                switch hevcType {
                case 32: frameVPS.append(nalu)       // VPS
                case 33: frameSPS.append(nalu)       // SPS
                case 34: framePPS.append(nalu)       // PPS
                case 35, 39, 40: break               // AUD / SEI — skip
                default: vclNALUs.append(nalu)       // slice data
                }
            case .prores4444, .prores4444XQ:
                break
            }
        }
        // A keyframe always carries its complete parameter sets; adopt them
        // as a group when anything changed (stream size / session switch).
        // P-frames carry none and leave the stored sets untouched.
        if !frameSPS.isEmpty || !framePPS.isEmpty,
           frameVPS != vpsSets || frameSPS != spsSets || framePPS != ppsSets {
            vpsSets = frameVPS
            spsSets = frameSPS
            ppsSets = framePPS
            formatDesc = nil
        }
        if formatDesc == nil {
            switch codec {
            case .h264:
                if !spsSets.isEmpty, !ppsSets.isEmpty {
                    if onDecodedFrame == nil { displayLayer.flush() }
                    buildFormatDescription(parameterSets: spsSets + ppsSets, hevc: false)
                }
            case .hevc:
                if !vpsSets.isEmpty, !spsSets.isEmpty, !ppsSets.isEmpty {
                    if onDecodedFrame == nil { displayLayer.flush() }
                    buildFormatDescription(parameterSets: vpsSets + spsSets + ppsSets, hevc: true)
                }
            case .prores4444, .prores4444XQ:
                break
            }
        }
        guard !vclNALUs.isEmpty else { return }
        // All slices of one wire frame go into ONE sample buffer.
        enqueueFrame(vclNALUs, captureMs: captureMs, sendMs: sendMs)
    }

    /// Build the format description from ALL parameter sets, ordered
    /// VPS -> SPS -> PPS. Count is dynamic (see the ppsSets rationale).
    private func buildFormatDescription(parameterSets: [Data], hevc: Bool) {
        let sizes = parameterSets.map(\.count)
        let ptrs: [UnsafeMutablePointer<UInt8>] = parameterSets.map { set in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { for p in ptrs { p.deallocate() } }
        let constPtrs = ptrs.map { UnsafePointer($0) }
        let hevcExtensions: CFDictionary? = {
            guard hevc, let deviceICCProfileData else { return nil }
            return [kCMFormatDescriptionExtension_ICCProfile:
                        deviceICCProfileData as CFData] as CFDictionary
        }()
        let status = hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: constPtrs.count,
                parameterSetPointers: constPtrs,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: hevcExtensions,
                formatDescriptionOut: &formatDesc)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: constPtrs.count,
                parameterSetPointers: constPtrs,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &formatDesc)
        if status == noErr, let formatDesc {
            let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
            let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any]
            let embeddedICC = (extensions?[kCMFormatDescriptionExtension_ICCProfile as String]
                as? Data)?.count ?? 0
            let fullRange = extensions?[kCMFormatDescriptionExtension_FullRangeVideo as String]
                as? Bool
            Log.info("format description built (\(hevc ? "HEVC" : "H.264"), "
                + "\(parameterSets.count) parameter sets): \(dims.width)x\(dims.height) "
                + "ICC=\(embeddedICC)B fullRange=\(fullRange.map(String.init) ?? "unspecified")")
            DispatchQueue.main.async {
                self.videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
            }
            setStatus("Receiving \(dims.width)×\(dims.height)\(hevc ? " (HEVC)" : "")")
        } else {
            Log.info("format description FAILED (\(hevc ? "HEVC" : "H.264")): \(status)")
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

        enqueueCompressedFrame(avcc, captureMs: captureMs, sendMs: sendMs)
    }

    /// Wrap one complete compressed frame in an owning CoreMedia buffer and
    /// present it immediately. Used by both AVCC H.264/HEVC and raw ProRes.
    private func enqueueCompressedFrame(_ compressed: Data,
                                        captureMs: Double? = nil,
                                        sendMs: Double? = nil) {
        guard let formatDesc else { return }

        // Allocate a block buffer that OWNS its memory and copy the bytes in —
        // referencing a transient Swift buffer here is a use-after-free.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,                   // let CoreMedia allocate
                blockLength: compressed.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0,
                dataLength: compressed.count, flags: 0,
                blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return }
        let copyStatus = compressed.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: compressed.count)
        }
        guard copyStatus == noErr else { return }

        var sample: CMSampleBuffer?
        var sizeArr = [compressed.count]
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr,
            sampleBufferOut: &sample)

        guard let sample else { return }

        if onDecodedFrame != nil {
            decodeAndRender(sample)
        } else {
            // Fallback only: display immediately with no PTS scheduling.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sample, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(
                    CFArrayGetValueAtIndex(attachments, 0),
                    to: CFMutableDictionary.self)
                CFDictionarySetValue(dict,
                    Unmanaged.passUnretained(
                        kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }

            if displayLayer.status == .failed {
                Log.info("display layer failed (\(String(describing: displayLayer.error))) — flushing")
                decodeFlushes += 1
                displayLayer.flush()
                requestKeyframeIfNeeded()
            }
            displayLayer.enqueue(sample)
        }

        // Per-frame timing for the HUD.
        let now = Date()
        if let last = lastFrameAt {
            let ms = now.timeIntervalSince(last) * 1000
            frameIntervals.append(ms)
            if frameIntervals.count > maxSamples { frameIntervals.removeFirst() }
            if ms > 50 { stallsThisWindow += 1 }
        }
        lastFrameAt = now

        // True end-to-end latency: sender capture timestamp vs our clock
        // mapped onto the sender's via the ping/pong offset.
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
            stats.macEncDrops = macEncDrops
            stats.macNetDrops = macNetDrops
            stats.macPending = macPending
            stats.inputP50 = macInputP50
            stats.inputP95 = macInputP95
            stats.capFps = macCapFps
            framesThisWindow = 0
            bytesThisWindow = 0
            stallsThisWindow = 0
            fpsWindowStart = now

            // Every 5s, report the aggregate to the sender so its log holds
            // the full pipeline picture for offline analysis.
            statsReportCounter += 1
            if statsReportCounter >= 5 {
                statsReportCounter = 0
                // Same aggregate we ship to the sender — also on our own
                // disk, so receiver-side debugging doesn't need both logs.
                Log.info(String(format: "stats: %@ fps=%d mbps=%.1f e2e50=%.0f e2e95=%.0f enc50=%.0f rtt=%.0f stalls=%d capFps=%d enc↓=%d net↓=%d",
                                transport, fps, stats.mbps, stats.e2eP50, stats.e2eP95,
                                stats.encodeP50, lastRttMs, stats.stalls, macCapFps,
                                macEncDrops, macNetDrops))
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
                    "color": metalRenderer?.colorDiagnostic
                        ?? "AVSampleBufferDisplayLayer",
                    "targetColor": destinationColorDiagnostic,
                    "offsetKnown": clockOffsetMs != nil,
                ])
                e2eWindow.removeAll(keepingCapacity: true)
                encodeWindow.removeAll(keepingCapacity: true)
            }

            DispatchQueue.main.async {
                self.fps = fps
                self.perf = stats
            }
        }
    }

    // MARK: - Dark-stream self-rescue

    // MARK: - Explicit VideoToolbox decode (Metal display path)

    private func ensureDecompressionSession() {
        guard let formatDesc else { return }
        if let session = decompressionSession {
            if VTDecompressionSessionCanAcceptFormatDescription(
                    session, formatDescription: formatDesc) {
                return
            }
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        // Preserve Main10 through decode instead of truncating every frame to
        // 8-bit BGRA. l10r is full-range ARGB2101010 and maps directly to
        // Metal BGR10A2; Apple's decoder still owns range, matrix and chroma
        // reconstruction. Some older VideoToolbox implementations reject a
        // 10-bit packed output request, so retry with BGRA rather than leaving
        // the receiver black.
        let outputFormats: [(OSType, String)] = [
            (kCVPixelFormatType_ARGB2101010LEPacked, "10-bit l10r Metal output"),
            (kCVPixelFormatType_32BGRA, "8-bit BGRA compatibility fallback"),
        ]
        for (pixelFormat, label) in outputFormats {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: nil,
                formatDescription: formatDesc,
                decoderSpecification: nil,
                imageBufferAttributes: attributes as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &session)
            if status == noErr, let session {
                decompressionSession = session
                Log.info("VideoToolbox decoder ready (\(label))")
                return
            }
            Log.info("VTDecompressionSessionCreate \(label) failed: \(status)")
        }
        requestKeyframeIfNeeded()
    }

    private func decodeAndRender(_ sample: CMSampleBuffer) {
        ensureDecompressionSession()
        guard let session = decompressionSession else { return }
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            // Keep decoder state and keyframe requests confined to `queue`.
            // The renderer itself is asynchronous/latest-wins, so this does
            // not queue presentation latency behind the decode call.
            flags: [],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            if status == noErr, let imageBuffer {
                self.onDecodedFrame?(imageBuffer)
            } else {
                self.decodeErrorCount += 1
                if self.decodeErrorCount % 60 == 1 {
                    Log.info("decode output error: \(status) image=\(imageBuffer != nil) count=\(self.decodeErrorCount)")
                }
                self.requestKeyframeIfNeeded()
            }
        }
        if status != noErr {
            decodeFlushes += 1
            decodeErrorCount += 1
            if decodeErrorCount % 60 == 1 {
                Log.info("decode call error: \(status) count=\(decodeErrorCount)")
            }
            requestKeyframeIfNeeded()
        }
    }

    /// ScreenCaptureKit only emits frames on content CHANGE — a fresh,
    /// fully static virtual display can therefore never produce a first
    /// frame on senders without screenshot seeding. If the stream is still
    /// dark a few seconds after connect, draw on it ourselves: a tiny
    /// corner drag renders a selection marquee, which is a real change.
    /// Runs at most 3 times per connection; a populated display streams
    /// within the delay, so this only ever touches an empty desktop.
    private func scheduleDarkStreamNudge(on conn: NWConnection, attempt: Int) {
        queue.asyncAfter(deadline: .now() + (attempt == 0 ? 3.0 : 4.0)) { [weak self] in
            guard let self, self.connection === conn, conn.state == .ready,
                  self.formatDesc == nil, attempt < 3 else { return }
            Log.info("stream dark \(attempt == 0 ? 3 : 3 + attempt * 4)s after connect — nudging the sender's display (attempt \(attempt + 1))")
            let steps: [(x: Double, y: Double, phase: String)] = [
                (0.90, 0.90, "began"), (0.92, 0.92, "moved"),
                (0.94, 0.94, "moved"), (0.94, 0.94, "ended"),
            ]
            for (i, step) in steps.enumerated() {
                self.queue.asyncAfter(deadline: .now() + Double(i) * 0.04) { [weak self] in
                    self?.sendControl(["type": "touch", "phase": step.phase,
                                       "x": step.x, "y": step.y], on: conn)
                }
            }
            self.scheduleDarkStreamNudge(on: conn, attempt: attempt + 1)
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
        if !value { setStatus("Listening on :\(port)") }
        else { setStatus("Connected") }
    }
}
