// StreamReceiver — the listening half of OpenDisplay: receive H.264 over
// TCP and display it. Compiled into BOTH targets (see project.yml): it is
// the iOS app's core, and the Mac app's receiver mode (issue #82) reuses it
// unchanged to turn a spare Mac into a display.
//
// Pipeline:  TCP socket -> deframe -> Annex B parse -> CMSampleBuffer
//            -> AVSampleBufferDisplayLayer (decodes + renders)
//
// The receiver LISTENS; the sending Mac connects (required for usbmux/USB).
// Wire protocol: [4-byte big-endian length][Annex B payload].
//
// Keep this file UIKit/AppKit-free — platform specifics (device kind,
// default names, cursor drawing, orientation) are injected by the app layer.

import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox
import QuartzCore
import ImageIO

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
    var cursorPerSec = 0         // cursor position updates applied (this window)
    var cursorLost = 0           // UDP cursor datagrams missing or reordered (this window)
    var macDrops = 0             // enc + net drops (legacy total)
    var macEncDrops = 0          // Mac skipped capture: encoder busy
    var macNetDrops = 0          // Mac skipped capture: TCP queue full
    var macPending = 0           // Mac send queue depth right now
    var inputP50 = 0.0           // touch sent → CGEvent injected on the Mac, ms
    var inputP95 = 0.0
    var capFps = 0               // frames ScreenCaptureKit delivered on the Mac
    // Metal renderer path only:
    var decodeP50 = 0.0          // VTDecompressionSession decode, ms
    var photonP50 = 0.0          // Mac capture → frame actually on glass, ms
    var photonP95 = 0.0
}

// MARK: - Peer-driven update signals (issue #132)

/// What the connected (sending) Mac tells us about compatibility. The iOS app
/// feeds this into its VersionGate; the Mac receiver panel shows it inline.
enum PeerUpdateSignal: Equatable {
    case updateReceiver(message: String, storeURL: URL)  // Mac sent `updateRequired`
    case updateMac(message: String)                      // sender's pv is below our floor
}

final class StreamReceiver: ObservableObject {

    @Published var status = "Starting…"
    @Published var fps = 0
    @Published var connected = false
    @Published var videoSize = CGSize.zero   // for touch coordinate mapping
    @Published var perf = PerfStats()
    // Compatibility signal from the connected Mac (issue #132). Nil = no signal.
    // Merged into the update gate by ReceiverScreen.
    @Published var peerSignal: PeerUpdateSignal?
    /// Mac protocol version from the most recent `welcome` message.
    @Published private(set) var macProtocolVersion = WireProtocol.assumedWhenAbsent

    /// True when the connected Mac understands pencil/proximity wire messages.
    var macSupportsPencilWire: Bool { macProtocolVersion >= WireProtocol.pencilWireVersion }

    private var listener: NWListener?
    private var listenerHealthy = false
    private var connection: NWConnection?
    // Cursor side channel: UDP on port+1. Cursor positions ride TCP behind
    // multi-hundred-KB video frames, so over WiFi one late frame stalls the
    // cursor with it (head-of-line blocking). UDP datagrams skip that queue.
    // Optional end to end: advertised in hello only once the listener is
    // ready, and the sender keeps using TCP when it is absent.
    private var cursorListener: NWListener?
    private var cursorListenerReady = false
    private var cursorConnection: NWConnection?
    private var cursorPortAnnounced = false
    // Newcomer connections still proving themselves against a live session
    // (see the listener). Tracked so stop() and adoption can cancel them —
    // an untracked silent socket would sit parked forever and could even
    // adopt into a receiver that was stopped in the meantime.
    private var pendingConnections: [NWConnection] = []
    // What the last hello advertised, to notice a cable appearing
    // mid-session: plugging one creates new interfaces, and a sender can
    // only probe addresses it has been told about.
    private var lastAdvertisedAddrs: [String] = []
    private var addrWatchTimer: DispatchSourceTimer?
    // The cable upgrade (PROTOCOL.md 6.4) is Mac-to-Mac: only Mac
    // receivers put addrs in their hello — see sendHello for why phones
    // must not.
    private var advertisesAddresses: Bool { deviceKind == "Mac" }
    private var lastCursorSeq: UInt64 = 0
    // Cursor channel health for the HUD/stats: how many positions landed and
    // how many datagrams never did (sequence gaps + reordered drops). A
    // stuttering pointer with a healthy count means the drawing side; a low
    // count or high loss means the network.
    private var cursorUpdatesThisWindow = 0
    private var cursorLostThisWindow = 0
    private var cursorPort: UInt16 { port &+ 1 }
    private let queue = DispatchQueue(label: "receiver.video")
    private var buffer = Data()
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    // Liveness: the Mac streams video and pings every 2s; if nothing arrives
    // for 5s the connection is half-open (Mac killed, tunnel died) — drop it
    // so the listener can accept a fresh one.
    private var lastDataReceived = Date()
    private var port: UInt16 = 9000
    // Liveness monitors: cancel-and-replace timers (not self-rescheduling
    // asyncAfter chains) so stop() can actually silence them — see #75.
    private var pingTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?

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
    private var macEncDrops = 0
    private var macNetDrops = 0
    private var macPending = 0
    private var macInputP50 = 0.0
    private var macInputP95 = 0.0
    private var macCapFps = 0

    private var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    // Local cursor echo (both called on the main thread): position is
    // normalized [0,1] in video space; the sprite arrives as a PNG with its
    // hotspot anchor and size normalized against the Mac display. The anchor
    // and normalized coordinates use a TOP-LEFT origin (video space).
    var onCursor: ((_ x: Double, _ y: Double, _ visible: Bool) -> Void)?
    var onCursorImage: ((_ image: CGImage, _ anchor: CGPoint, _ normSize: CGSize) -> Void)?
    // The video view attaches only once frames are on screen — usually AFTER
    // the connect-time sprite already arrived (the sender re-sends it only
    // when the cursor changes shape, so a plain arrow would stay invisible
    // forever). Keep the latest of each so a late-attaching view replays
    // them. Main-thread, like the callbacks.
    private(set) var cursorState: (x: Double, y: Double, visible: Bool) = (0.5, 0.5, false)
    private(set) var cursorSprite: (image: CGImage, anchor: CGPoint, normSize: CGSize)?

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

    // Platform identity, injected at init so this file stays UI-framework-free.
    /// "iPhone" / "iPad" / "Mac" — announced in the hello (the sender names
    /// the virtual display after it) and used in peer-update copy.
    private let deviceKind: String
    // Decode ceiling advertised in hello (PROTOCOL.md 6.5): the largest
    // stream this machine can actually sustain, which a big panel says
    // nothing about. nil = advertise nothing (sender streams full size).
    private let maxEncodeWide: Int?
    private let maxEncodeHigh: Int?
    /// What to advertise when the user-set service name is empty.
    private let fallbackServiceName: String

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

    private var advertisedService: NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = Self.installID
        txt["pv"] = String(WireProtocol.version)   // issue #132
        return NWListener.Service(name: serviceName, type: "_opensidecar._tcp",
                                  domain: nil, txtRecord: txt)
    }

    /// Update the advertised name and re-publish if already listening.
    func setServiceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallbackServiceName : trimmed
        queue.async {
            guard resolved != self.serviceName else { return }
            self.serviceName = resolved
            if self.listener != nil {
                self.listener?.service = self.advertisedService
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
        guard nativeLong > 0 else { return }
        setPanel(pixelsWide: portrait ? nativeShort : nativeLong,
                 pixelsHigh: portrait ? nativeLong : nativeShort,
                 scale: deviceScale)
    }

    /// Announce the panel this receiver renders onto. Called before start()
    /// and again whenever it changes (iOS rotation via setOrientation, macOS
    /// display-mode changes) — a live connection re-sends hello so the sender
    /// rebuilds the virtual display for the new dimensions.
    func setPanel(pixelsWide w: Int, pixelsHigh h: Int, scale: Double) {
        deviceScale = scale
        guard w > 0, h > 0, w != devicePixelsWide || h != devicePixelsHigh else { return }
        devicePixelsWide = w
        devicePixelsHigh = h
        Log.info("panel changed -> \(w)x\(h) @\(scale)x")
        if let connection { sendHello(on: connection) }
    }

    init(displayLayer: AVSampleBufferDisplayLayer, deviceKind: String,
         fallbackServiceName: String,
         maxEncodeWide: Int? = nil, maxEncodeHigh: Int? = nil) {
        self.displayLayer = displayLayer
        self.deviceKind = deviceKind
        self.fallbackServiceName = fallbackServiceName
        self.maxEncodeWide = maxEncodeWide
        self.maxEncodeHigh = maxEncodeHigh
        displayLayer.videoGravity = .resizeAspect
    }

    func start(port: UInt16 = 9000) {
        self.port = port
        queue.async {
            self.startListener()
            self.armLivenessTimers()
        }
    }

    /// Leave receiver duty for good: announce "closing" to a live sender (so
    /// it ends the session instead of waiting for a wake), drop the
    /// connection and the listener, and silence the liveness timers. The Mac
    /// app calls this when the user leaves receiver mode or quits; the
    /// instance is discarded afterwards (start() re-arms if it isn't).
    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.pingTimer?.cancel(); self.pingTimer = nil
            self.watchdogTimer?.cancel(); self.watchdogTimer = nil
            self.addrWatchTimer?.cancel(); self.addrWatchTimer = nil
            self.pendingConnections.forEach { $0.cancel() }
            self.pendingConnections.removeAll()
        }
        closeSession(announcing: WireMessage.closing, status: "Stopped",
                     completion: completion)
    }

    /// Recreate the listener if it isn't healthy — called when the app
    /// returns to the foreground (iOS may have torn it down while suspended,
    /// or enterSleep deliberately took it down on lock).
    func ensureListening() {
        queue.async {
            guard !self.listenerHealthy else { return }
            Log.info("listener not healthy — restarting")
            self.restartListener()
        }
    }

    // Set while the app lingers in the background with the session alive
    // (brief app switch): decoding is pointless and hardware decode sessions
    // fail off-screen, so frames are dropped before the sample stage.
    private var renderingPaused = false

    /// Pause/resume the video sink around a background linger. Resuming
    /// flushes the layer and asks the Mac for a keyframe so the picture
    /// re-syncs immediately (the Mac replays a static screen as IDR too).
    func setRenderingPaused(_ paused: Bool) {
        queue.async {
            guard paused != self.renderingPaused else { return }
            self.renderingPaused = paused
            Log.info(paused ? "rendering paused (backgrounded)" : "rendering resumed")
            if !paused {
                self.displayLayer.flush()
                if self.connection?.state == .ready {
                    self.sendControl(["type": "kf"])
                }
            }
        }
    }

    /// The device locked — nobody can see the stream, so tell the Mac and go
    /// silent. Sends "sleeping" (the Mac drops its virtual display so the
    /// cursor isn't stranded on an invisible screen and arms a reconnect),
    /// then closes the connection AND the listener: while asleep we must not
    /// accept connections, or the Mac's wake retries would rebuild the
    /// display before anyone can see it. ensureListening() re-arms
    /// everything when the scene becomes active again.
    func enterSleep(completion: (() -> Void)? = nil) {
        closeSession(announcing: WireMessage.sleeping,
                     status: "Asleep — resumes on wake", completion: completion)
    }

    /// The app is being terminated (user swiped it away). Same close, but
    /// announced as "closing": quitting the app is deliberate, so the Mac
    /// ends the session without waiting around for a wake.
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
                self.listenerHealthy = false
                self.stopCursorListener()
                self.setConnected(false)
                self.setStatus(status)
                completion?()
            }
            guard let conn = self.connection, conn.state == .ready else {
                Log.info("closing session (\(type)) — no live connection")
                finish()
                return
            }
            Log.info("closing session — announcing \(type) to the Mac")
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
        listenerHealthy = false
        startListener()
    }

    /// The UDP cursor listener follows the TCP listener's lifecycle: created
    /// right after it, torn down with it. Losing it is never fatal; the
    /// sender falls back to TCP when hello carries no cursorPort.
    private func startCursorListener() {
        stopCursorListener()
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        params.serviceClass = .responsiveData
        let udp: NWListener
        do {
            udp = try NWListener(using: params, on: NWEndpoint.Port(rawValue: cursorPort)!)
        } catch {
            Log.info("cursor listener failed on udp :\(cursorPort): \(error) (cursor stays on TCP)")
            return
        }
        cursorListener = udp
        udp.newConnectionHandler = { [weak self] conn in
            guard let self, self.cursorListener === udp else { conn.cancel(); return }
            // A UDP "connection" is one remote host:port flow. The newest
            // one is the live sender (a rebuilt sender socket gets a fresh
            // ephemeral port) and starts its sequence over.
            self.cursorConnection?.cancel()
            self.cursorConnection = conn
            self.lastCursorSeq = 0
            conn.stateUpdateHandler = { [weak self] state in
                guard let self, self.cursorConnection === conn else { return }
                if case .failed(let error) = state {
                    Log.info("cursor channel failed: \(error)")
                    self.cursorConnection = nil
                }
            }
            conn.start(queue: self.queue)
            self.receiveCursorDatagrams(on: conn)
        }
        udp.stateUpdateHandler = { [weak self] state in
            guard let self, self.cursorListener === udp else { return }
            switch state {
            case .ready:
                self.cursorListenerReady = true
                Log.info("cursor listener ready on udp :\(self.cursorPort)")
                // hello may already be out without the port (the sender
                // connected before UDP bound); re-send so it can switch.
                if let connection, connection.state == .ready, !self.cursorPortAnnounced {
                    self.sendHello(on: connection)
                }
            case .failed(let error):
                Log.info("cursor listener failed: \(error) (cursor stays on TCP)")
                let wasAnnounced = self.cursorPortAnnounced
                self.stopCursorListener()
                // Withdraw the offer: a hello without cursorPort makes the
                // sender close its channel and return to TCP.
                if wasAnnounced, let connection = self.connection, connection.state == .ready {
                    self.sendHello(on: connection)
                }
            case .cancelled:
                self.cursorListenerReady = false
            default: break
            }
        }
        udp.start(queue: queue)
    }

    private func stopCursorListener() {
        cursorConnection?.cancel()
        cursorConnection = nil
        cursorListener?.cancel()
        cursorListener = nil
        cursorListenerReady = false
        cursorPortAnnounced = false
    }

    private func receiveCursorDatagrams(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.cursorConnection === conn else { return }
            if let error {
                Log.info("cursor channel receive error: \(error)")
                return
            }
            if let data, !data.isEmpty { self.handleCursorDatagram(data) }
            self.receiveCursorDatagrams(on: conn)
        }
    }

    /// One datagram = one cursor JSON plus `s`, a per-flow sequence. UDP can
    /// reorder, and a stale position after a fresh one reads as jitter, so
    /// anything at or below the last seen sequence is dropped.
    private func handleCursorDatagram(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "cursor",
              let seq = (obj["s"] as? NSNumber)?.uint64Value else { return }
        // Loss accounting only; the floor itself is enforced in applyCursor,
        // shared with TCP. Counts run slightly hot during the brief window
        // where the sender still mirrors to TCP (duplicates read as drops).
        guard seq > lastCursorSeq else { cursorLostThisWindow += 1; return }
        if lastCursorSeq == 0 {
            // First datagram of this flow: tell the sender the channel truly
            // delivers (UDP .ready proves only a local route — a firewalled
            // port would otherwise eat the cursor forever, PROTOCOL.md 6.3).
            Log.info("cursor channel: receiving datagrams")
            sendControl(["type": "cursorAck"])
        } else {
            cursorLostThisWindow += Int(seq - lastCursorSeq - 1)
        }
        applyCursor(obj)
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
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            setStatus("Listener failed: \(error.localizedDescription)")
            return
        }
        // Advertise on the local network so the Mac can discover us for WiFi
        // mode (USB/usbmux connects straight to the port and ignores this).
        listener?.service = advertisedService
        listener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Log.info("new connection from \(String(describing: conn.endpoint))")
            // usbmux-forwarded (cable) connections arrive from loopback;
            // anything else came over the network.
            let peer = String(describing: conn.endpoint)
            self.transport = (peer.hasPrefix("127.0.0.1") || peer.hasPrefix("::1")
                              || peer.hasPrefix("localhost")) ? "USB" : "WiFi"
            // A Bonjour dial races IPv6 and IPv4 and both handshakes can
            // complete; the sender cancels its loser within milliseconds.
            // Adopting every newcomer at once evicted the winner for a
            // connection that was already dying (seen in the field as a
            // reset-by-peer storm). With a connection in hand, a newcomer
            // has to stay alive for a moment before it replaces it.
            // A closed socket still reads as .ready until a receive hits
            // EOF, so the proof is bytes: greet the newcomer and adopt it
            // the moment it streams something back; a socket that closes
            // or errors first is discarded and the session stays put.
            if let current = self.connection, current.state != .cancelled,
               !Self.isFailed(current.state) {
                self.pendingConnections.append(conn)
                conn.stateUpdateHandler = { [weak self] state in
                    guard let self, case .ready = state else { return }
                    self.sendHello(on: conn)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) {
                        [weak self] data, _, isComplete, error in
                        guard let self else { return }
                        // Only a still-tracked candidate may adopt: adoption
                        // of a rival and stop() both clear the list, so a
                        // late callback can't evict a session or resurrect a
                        // stopped receiver.
                        guard self.pendingConnections.contains(where: { $0 === conn }) else {
                            conn.cancel()
                            return
                        }
                        self.pendingConnections.removeAll { $0 === conn }
                        if let data, !data.isEmpty {
                            self.adopt(conn, greeted: true, initialData: data)
                        } else {
                            Log.info("ignored a twin connection that closed at once"
                                     + (error.map { " (\($0))" } ?? ""))
                            conn.cancel()
                        }
                        _ = isComplete
                    }
                }
                conn.start(queue: self.queue)
            } else {
                self.adopt(conn)
            }
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
        startCursorListener()
    }

    /// Make `conn` the session: replace any existing connection and reset
    /// decoder state. `greeted` marks a newcomer that already got its hello
    /// while it proved itself (see the listener), with the bytes it sent
    /// back in `initialData`; a second hello would make the sender rebuild.
    private func adopt(_ conn: NWConnection, greeted: Bool = false, initialData: Data? = nil) {
        if greeted { Log.info("newcomer proved itself — adopting it as the session") }
        connection?.cancel()
        connection = conn
        // The race is decided: rival candidates die here.
        for pending in pendingConnections where pending !== conn { pending.cancel() }
        pendingConnections.removeAll()
        resetStreamState()
        lastCursorSeq = 0   // the sender restarts its cursor sequence per session
        cursorPortAnnounced = false
        // Hide the previous sender's cursor: replayed into a fresh video view
        // it would ghost over a new sender that never sends one (mirror mode
        // hides no local cursor and streams no sprite).
        DispatchQueue.main.async {
            self.cursorState = (0.5, 0.5, false)
            self.cursorSprite = nil
            self.onCursor?(0.5, 0.5, false)
        }
        let onReady: () -> Void = { [weak self] in
            guard let self else { return }
            self.lastDataReceived = Date()
            self.setConnected(true)
            if !greeted { self.sendHello(on: conn) }
        }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, conn === self.connection else { return }   // replaced: stay quiet
            switch state {
            case .ready: onReady()
            case .failed, .cancelled: self.setConnected(false)
            default: break
            }
        }
        if conn.state == .ready {
            onReady()   // already up: the handler will not fire again
        } else {
            conn.start(queue: queue)
        }
        if let initialData, !initialData.isEmpty {
            bytesThisWindow += initialData.count
            buffer.append(initialData)
            drainFrames()
        }
        receive(on: conn)
    }

    private static func isFailed(_ state: NWConnection.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Liveness (ping + watchdog)

    /// Arm (or re-arm) the ping and watchdog timers on the receiver queue.
    private func armLivenessTimers() {
        pingTimer?.cancel()
        let ping = DispatchSource.makeTimerSource(queue: queue)
        ping.schedule(deadline: .now() + 2.0, repeating: 2.0)
        ping.setEventHandler { [weak self] in
            guard let self, self.connection?.state == .ready else { return }
            self.sendControl(["type": "ping", "t": self.nowMs])
        }
        ping.resume()
        pingTimer = ping

        addrWatchTimer?.cancel()
        if advertisesAddresses {
            let addrWatch = DispatchSource.makeTimerSource(queue: queue)
            addrWatch.schedule(deadline: .now() + 5.0, repeating: 5.0)
            addrWatch.setEventHandler { [weak self] in
                guard let self, let conn = self.connection, conn.state == .ready else { return }
                let now = Self.reachableAddresses()
                guard now != self.lastAdvertisedAddrs else { return }
                // A cable was plugged (or pulled) mid-session: tell the sender,
                // it re-probes on the fresh list (PROTOCOL.md 6.4).
                Log.info("reachable addresses changed — re-sending hello")
                self.sendHello(on: conn)
            }
            addrWatch.resume()
            addrWatchTimer = addrWatch
        }

        watchdogTimer?.cancel()
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 2.0, repeating: 2.0)
        watchdog.setEventHandler { [weak self] in
            guard let self, let conn = self.connection, conn.state == .ready,
                  Date().timeIntervalSince(self.lastDataReceived) > 5 else { return }
            Log.info("watchdog: nothing from the Mac for >5s — dropping connection")
            conn.cancel()
            self.connection = nil
            self.setConnected(false)
        }
        watchdog.resume()
        watchdogTimer = watchdog
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
            applyCursor(obj)
        case "cursorImg":
            guard let b64 = obj["png"] as? String,
                  let png = Data(base64Encoded: b64),
                  let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let nw = obj["nw"] as? Double, let nh = obj["nh"] as? Double else { return }
            let anchor = CGPoint(x: obj["ax"] as? Double ?? 0, y: obj["ay"] as? Double ?? 0)
            let normSize = CGSize(width: nw, height: nh)
            DispatchQueue.main.async {
                self.cursorSprite = (image, anchor, normSize)
                self.onCursorImage?(image, anchor, normSize)
            }
        case WireMessage.welcome:
            // The Mac identified itself (issue #132). If it speaks a protocol
            // older than we support, it's the Mac that needs updating — and an
            // old Mac can't diagnose that itself, so we surface it here.
            let macPV = obj["pv"] as? Int ?? WireProtocol.assumedWhenAbsent
            DispatchQueue.main.async {
                self.macProtocolVersion = macPV
            }
            if macPV < WireProtocol.minSupportedPeer {
                let msg = "The OpenDisplay app on your Mac is too old for this \(deviceKind) app. Update OpenDisplay on your Mac to reconnect."
                DispatchQueue.main.async { self.peerSignal = .updateMac(message: msg) }
            }
        case WireMessage.updateRequired:
            // The Mac refuses this pairing until we update from the App Store.
            let message = obj["message"] as? String
                ?? "Update OpenDisplay from the App Store to keep using your second display."
            let store = (obj["store"] as? String).flatMap { URL(string: $0) } ?? AppStore.updateURL
            DispatchQueue.main.async { self.peerSignal = .updateReceiver(message: message, storeURL: store) }
        default:
            break
        }
    }

    /// Shared by the TCP control path and the UDP side channel so both feed
    /// the same cursorState buffering and onCursor callback. The sequence
    /// floor lives here so the two paths can't reorder each other: around a
    /// channel switch a TCP frame queued behind video would otherwise land
    /// after (and override) a newer UDP position. Old senders put no `s` on
    /// TCP frames; those apply unconditionally, as before.
    private func applyCursor(_ obj: [String: Any]) {
        if let seq = (obj["s"] as? NSNumber)?.uint64Value {
            guard seq > lastCursorSeq else { return }
            lastCursorSeq = seq
        }
        let visible = (obj["v"] as? Int ?? 0) == 1
        let x = obj["x"] as? Double ?? 0
        let y = obj["y"] as? Double ?? 0
        cursorUpdatesThisWindow += 1
        DispatchQueue.main.async {
            self.cursorState = (x, y, visible)
            self.onCursor?(x, y, visible)
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
        var hello: [String: Any] = [
            "type": "hello",
            "pixelsWide": devicePixelsWide,
            "pixelsHigh": devicePixelsHigh,
            "scale": deviceScale,
            "device": deviceKind,
            "id": Self.installID,
            "pv": WireProtocol.version,   // issue #132 — absent on old receivers
        ]
        // Additive capability: only offered while the UDP listener is bound,
        // so a sender never dials a port nobody answers on.
        if cursorListenerReady { hello["cursorPort"] = Int(cursorPort) }
        // Additive: decode ceiling (PROTOCOL.md 6.5) — ask for the full
        // desktop but a stream no larger than this machine can decode.
        if let maxEncodeWide, let maxEncodeHigh {
            hello["maxEncodeWide"] = maxEncodeWide
            hello["maxEncodeHigh"] = maxEncodeHigh
        }
        // Additive: the addresses this receiver can be reached on, so the
        // sender can probe for a better (cabled) path and migrate a WiFi
        // session onto it — mDNS resolution under an interface-restricted
        // dial stalls, a literal address does not (PROTOCOL.md 6.4).
        // Mac receivers only: a cabled phone reaches the sender over
        // usbmuxd, and advertising a phone's WiFi fe80 would invite a
        // false "upgrade" onto a bridged-LAN path that still crosses the
        // phone's radio — and then have the session classified as a cable
        // whose loss must end it instead of reconnecting.
        let addrs = advertisesAddresses ? Self.reachableAddresses() : []
        if !addrs.isEmpty { hello["addrs"] = addrs }
        lastAdvertisedAddrs = addrs
        cursorPortAnnounced = cursorListenerReady
        sendControl(hello, on: conn)
        Log.info("hello sent\(cursorListenerReady ? " (cursorPort \(cursorPort))" : "")")
    }

    /// Every IP address of an up, non-loopback interface, for hello.addrs.
    /// Link-local IPv6 is sent bare (no scope): the zone id only means
    /// something on the machine holding the interface, so the sender scopes
    /// it to each of its own candidate interfaces when probing. Virtual and
    /// peer-to-peer interfaces (awdl/llw/utun) never carry this traffic and
    /// are skipped.
    private static func reachableAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            // anpi* is Apple's internal peripheral/debug interface: TCP
            // handshakes complete over it but it cannot carry the stream —
            // a session migrated onto it stalls within seconds (field log
            // 18:59). The user-facing USB-C host-to-host link is a plain en.
            if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun")
                || name.hasPrefix("pdp_ip") || name.hasPrefix("anpi") { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = family == UInt8(AF_INET)
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var addr = String(cString: host)
            // getnameinfo appends %scope to link-local IPv6 — strip it, the
            // receiver-side zone id is meaningless to the sender.
            if let percent = addr.firstIndex(of: "%") { addr = String(addr[..<percent]) }
            if !result.contains(addr) { result.append(addr) }
            if result.count >= 12 { break }
        }
        return result
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

    /// Apple Pencil stroke/hover. azimuth and altitude are radians.
    /// rotation is always 0 until Apple Pencil Pro barrel roll is wired up.
    func sendPencil(phase: String, x: Double, y: Double,
                    pressure: Double, azimuth: Double, altitude: Double) {
        var msg: [String: Any] = [
            "type": "pencil",
            "phase": phase,
            "x": x, "y": y,
            "pressure": pressure,
            "azimuth": azimuth,
            "altitude": altitude,
            "rotation": 0,   // TODO: UIKit rollAngle once Pencil Pro is available
        ]
        if let offset = clockOffsetMs { msg["t"] = nowMs + offset }
        sendControl(msg)
    }

    func sendProximity(entering: Bool, x: Double, y: Double) {
        sendControl(["type": "proximity", "entering": entering, "x": x, "y": y])
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
            // A replaced connection's last callback must not touch the
            // session (its EOF used to flip `connected` off for the new one).
            guard let self, conn === self.connection else { return }
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
        // Backgrounded linger: hardware decode is off-limits there, so drop
        // frames at the door instead of feeding a failing display layer at
        // frame rate. setRenderingPaused(false) re-syncs with a keyframe.
        if renderingPaused { return }

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
            stats.cursorPerSec = Int(Double(cursorUpdatesThisWindow) / elapsed)
            stats.cursorLost = cursorLostThisWindow
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
            stats.decodeP50 = percentile(decodeWindow, 0.5)
            stats.photonP50 = percentile(photonWindow, 0.5)
            stats.photonP95 = percentile(photonWindow, 0.95)
            framesThisWindow = 0
            bytesThisWindow = 0
            stallsThisWindow = 0
            cursorUpdatesThisWindow = 0
            cursorLostThisWindow = 0
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
                    "cur": stats.cursorPerSec,
                    "curLost": stats.cursorLost,
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
        DispatchQueue.main.async {
            self.connected = value
            if !value {
                self.macProtocolVersion = WireProtocol.assumedWhenAbsent
            }
        }
        if !value { setStatus("Listening on :9000") }
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
