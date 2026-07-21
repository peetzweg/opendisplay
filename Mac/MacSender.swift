// MacSender — captures a display, H.264-encodes it, streams it to the phone.
//
// Milestone 1 (mirror):  capture the main display.
// Milestone 2 (extend):  create a CGVirtualDisplay sized to the phone panel
//                        (announced by the phone in a "hello" message) and
//                        capture that — macOS gains a true second monitor.
//
// Pipeline:  ScreenCaptureKit -> VideoToolbox (H.264) -> framed TCP
// Roles: the PHONE listens, the MAC connects (required for usbmux/USB).
//
// Wire protocol, Mac -> phone:   [4-byte big-endian length][Annex B payload]
//   (keyframes prefixed with SPS+PPS, NALUs delimited by 00 00 00 01)
// Wire protocol, phone -> Mac:   [4-byte big-endian length][JSON message]
//   e.g. {"type":"hello","pixelsWide":2556,"pixelsHigh":1179,"scale":3}

import ScreenCaptureKit
import VideoToolbox
import Network
import CoreMedia
import AppKit

enum CaptureMode: String {
    case mirror   // main display (Milestone 1)
    case extend   // virtual display (Milestone 2)
}

/// Capture-resolution / bitrate trade-off. The virtual display always runs at
/// native size — only the captured/encoded stream is scaled, so lower presets
/// cut encode, transmit, and decode time at the cost of sharpness.
enum StreamQuality: String, CaseIterable {
    case best, balanced, fast

    var scale: Double {
        switch self {
        case .best: return 1.0
        case .balanced: return 0.75
        case .fast: return 0.5
        }
    }

    var bitrate: Int {
        switch self {
        case .best: return 18_000_000
        case .balanced: return 10_000_000
        case .fast: return 6_000_000
        }
    }

    var label: String {
        switch self {
        case .best: return "Best (native)"
        case .balanced: return "Balanced (75%)"
        case .fast: return "Fast (50%)"
        }
    }

    var explanation: String {
        switch self {
        case .best: return "Pixel-perfect at the device's native resolution. Highest bandwidth and latency."
        case .balanced: return "75% capture resolution — noticeably lower latency, slight softness."
        case .fast: return "Half resolution — lowest latency and bandwidth, visibly softer. Good for WiFi."
        }
    }
}

struct PhoneInfo: Decodable {
    let pixelsWide: Int   // landscape-oriented (long edge)
    let pixelsHigh: Int
    let scale: Double
    let device: String?   // "iPad" / "iPhone" (older receivers omit it)
    let id: String?       // per-install identity (older receivers omit it) —
                          // lets the controller match the same physical device
                          // across USB and WiFi
    let pv: Int?          // receiver protocol version (issue #132); absent on
                          // every pre-handshake install → treat as protocol 1

    var kind: String { device ?? "device" }
    var protocolVersion: Int { pv ?? WireProtocol.assumedWhenAbsent }
}

/// How the sender reaches the receiver. Reconnects re-dial from scratch, so
/// a USB device that was replugged (new usbmuxd DeviceID) is found again.
enum SenderTransport {
    case tcp(NWEndpoint)                   // WiFi (Bonjour) or -host/-port override
    case usb(udid: String?, port: UInt16)  // native usbmuxd dial; nil = first device
}

@available(macOS 14.0, *)
final class MacSender: NSObject, SCStreamOutput, SCStreamDelegate {

    // Status surfaced to the UI (updated on main thread).
    @MainActor var onStatus: ((String) -> Void)?
    @MainActor var onStats: ((Int, Double) -> Void)?   // framesSent, mbps
    // Fired when a previously connected device stays gone past the grace
    // period — the controller ends the session (capture, virtual display,
    // recording indicator all torn down) instead of dialing forever or
    // silently coming back over a different transport.
    @MainActor var onDisconnected: (() -> Void)?
    // Fired when the receiver announces its device locked. The controller
    // ends this session — an invisible display strands the cursor — and
    // starts a fresh one that waits for the wake.
    @MainActor var onPeerSleeping: (() -> Void)?
    // Fired when the receiver announces the app is quitting: deliberate,
    // so the controller ends the session without arming a reconnect.
    @MainActor var onPeerClosed: (() -> Void)?
    // Fired on every hello — carries the receiver's install id so the
    // controller can deduplicate USB/WiFi sessions to the same device.
    @MainActor var onHello: ((PhoneInfo) -> Void)?

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var connection: NWConnection?
    private var virtualDisplay: VirtualDisplay?
    private let queue = DispatchQueue(label: "sender.video")
    private let startCode: [UInt8] = [0, 0, 0, 1]

    // The dial target. Written on `queue` only (after init): the controller
    // can migrate a live session between transports via switchTransport.
    private var transport: SenderTransport
    private let endpointName: String
    private let mode: CaptureMode
    private let quality: StreamQuality
    // Stable per-device serial for the virtual display, so macOS can tell
    // multiple OpenDisplay monitors apart and persist their arrangement.
    private let displaySerial: UInt32

    // ── Encoder parallelism limiter (maxPendingEncodes = 1) ─────────────────
    //
    // VTCompressionSessionEncodeFrame returns immediately; the hardware H.264
    // encoder runs asynchronously. If ScreenCaptureKit delivers the next frame
    // before the previous encode callback fires, VideoToolbox will run multiple
    // encodes in parallel inside the same session.
    //
    // Capping pendingEncodes at 1 enforces “latest frame wins” on the encoder:
    // skip captures while an encode is in flight (enc drops), then feed the next
    // fresh buffer when the callback clears the slot. The H.264 reference chain
    // stays valid (pre-encode skip → normal P-frame n→n+2); we do NOT force
    // keyframes on enc drops.
    private var pendingEncodes = 0
    private let maxPendingEncodes = 1

    // ── Outstanding send backpressure (maxPendingSends = 3) ──────────────────
    //
    // pendingSends counts video frames whose NWConnection.send completion has
    // not fired yet — i.e. bytes still in flight / waiting on TCP ACKs. Allow a
    // small pipeline (3) so the link is not idle between ACKs; unlike the encoder,
    // a few outstanding sends helps throughput without piling up seconds of lag.
    //
    // When pendingSends hits the cap we skip the capture before encode (net
    // drops). Same drop point as enc drops, but means “TCP send queue full”, not
    // “encoder busy” — split counters (enc↓ vs net↓) so the HUD shows which
    // bottleneck fired. Never encode-then-discard: dropping here avoids wasting
    // VT work on frames that would only add latency.
    private var pendingSends = 0
    private let maxPendingSends = 3
    private let pipelineLock = NSLock()
    private var dropsEncThisWindow = 0
    private var dropsNetThisWindow = 0
    private var dropsEncTotal = 0
    private var dropsNetTotal = 0
    private var needsKeyframe = true
    private var connectionReady = false
    private var stopped = false
    // The liveness monitors are self-rescheduling chains guarded only by
    // `stopped`; arm them at most once per instance so a double start() can't
    // stack parallel loops (the failure mode behind #75). Mirrors the
    // `monitorsStarted` guard the iOS PhoneReceiver already uses.
    private var monitorsStarted = false

    // Disconnect detection: before the first connection we dial patiently
    // (the user may start the Mac side first); once connected, a device that
    // stays gone past the grace ends the session via onDisconnected.
    private var everConnected = false
    private var disconnectedSince: Date?
    private let disconnectGraceSeconds: TimeInterval = 10

    private var lastHello: PhoneInfo?
    private var helloContinuation: CheckedContinuation<PhoneInfo, Error>?
    private var inputInjector: InputInjector?

    // Liveness: both sides ping every 2s; if nothing arrives for 5s the link
    // is half-open (e.g. usbmuxd accepted but the device is gone) — reconnect.
    private var lastReceived = Date()

    // Session created after the receiver went to sleep: it refuses
    // connections until its screen is back, so dial failures mean "asleep",
    // not "app closed" — surface that instead of the usual hints. Cleared by
    // the first successful connection.
    private var awaitingWake: Bool

    // Consecutive actively-refused dials on a previously connected session.
    // Refusal is unambiguous: the device is reachable but nothing listens,
    // so the app was quit (a suspended app's kernel still accepts, and a
    // network blip times out instead of refusing). Three in a row (~3s)
    // ends the session early; the full 10s grace stays reserved for the
    // ambiguous failure kinds.
    private var consecutiveRefusals = 0
    private let refusalsBeforeGivingUp = 3
    private var dropsTotal: Int { dropsEncTotal + dropsNetTotal }

    // Local cursor echo: a cursor baked into the video carries the full
    // capture→encode→stream→display latency (~30ms perceived). Instead we
    // hide it from capture and stream its position on the control channel —
    // the phone draws it locally on the ~2ms path the touches use.
    // Escape hatch: `defaults write sh.peet.opensidecar.mac localCursor -bool false`.
    private let localCursor = UserDefaults.standard.object(forKey: "localCursor") == nil
        || UserDefaults.standard.bool(forKey: "localCursor")
    private var cursorTimer: DispatchSourceTimer?
    private var cursorImageTimer: DispatchSourceTimer?
    private var lastCursorSent: (x: Double, y: Double, visible: Bool) = (-1, -1, false)
    private var lastCursorPNGHash = 0
    private var captureDisplayID: CGDirectDisplayID = 0

    // Input latency: touches arrive stamped in our clock (the phone applies
    // its sync offset); delta to now = network + deframe + dispatch.
    private var inputLatencies: [Double] = []
    // Capture cadence: SCK only emits on content change, so the phone can't
    // tell "Mac rendered 45fps" from "frames got lost" — count deliveries here.
    private var capFrames = 0
    private var capWindowStart = Date()

    private var framesSent = 0
    private var bytesSent = 0
    private var statsWindowStart = Date()

    // ScreenCaptureKit emits frames only when content changes. After a
    // reconnect on a static screen there is nothing to hang the forced
    // keyframe on — so keep the last frame around and re-encode it.
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastCaptureAt = Date.distantPast

    init(transport: SenderTransport, name: String, mode: CaptureMode,
         quality: StreamQuality = .best, displaySerial: UInt32 = 0x0001,
         awaitingWake: Bool = false) {
        self.transport = transport
        self.endpointName = name
        self.mode = mode
        self.quality = quality
        self.displaySerial = displaySerial
        self.awaitingWake = awaitingWake
        super.init()
    }

    // MARK: - Lifecycle

    func start() async throws {
        stopped = false
        queue.async { self.connect() }   // dial state lives on `queue`
        if !monitorsStarted {
            monitorsStarted = true
            schedulePing()
            scheduleWatchdog()
        }

        // Screen Recording permission: poll until granted. No auto-prompt at
        // launch — the permission panel's Grant button triggers the system
        // dialog, so the request always has visible context.
        if !CGPreflightScreenCaptureAccess() {
            await status("Screen Recording permission needed — see Permissions below")
            Log.info("Screen Recording permission missing — waiting for grant via the permission panel")
            while !CGPreflightScreenCaptureAccess() {
                try await Task.sleep(for: .seconds(2))
                if stopped { return }
            }
            Log.info("Screen Recording permission granted")
        }

        switch mode {
        case .mirror:
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw NSError(domain: "MacSender", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "no displays found"])
            }
            // SCDisplay reports points; capture at point resolution for M1.
            let captureW = (Int(Double(display.width) * quality.scale)) & ~1
            let captureH = (Int(Double(display.height) * quality.scale)) & ~1
            try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)

        case .extend:
            await status(awaitingWake
                ? "\(endpointName) is asleep — reconnects when it wakes…"
                : "Waiting for the device to connect…")
            let info = try await waitForHello()
            try await setupExtend(info)

            // Touch back-channel (Milestone 3). Needs Accessibility trust;
            // streaming works without it, so don't interrupt with a prompt —
            // the permission panel's Grant button asks when the user is ready.
            if !AXIsProcessTrusted() {
                await status("Extending — grant Accessibility for touch input")
                // Event posting is trust-checked per-post, so it starts working
                // the moment the user grants — poll just to log/report it.
                while !AXIsProcessTrusted() {
                    try await Task.sleep(for: .seconds(2))
                    if stopped { return }
                }
                Log.info("Accessibility permission granted — touch input live")
            }
        }
    }

    /// Build (or rebuild) the virtual display + capture for the announced
    /// phone dimensions. Called at startup and again whenever the phone
    /// rotates (it re-sends hello with swapped dimensions).
    private func setupExtend(_ info: PhoneInfo) async throws {
        Log.info("phone hello: \(info.pixelsWide)x\(info.pixelsHigh) @\(info.scale)x")

        // Phone panel is @3x; the virtual display runs @2x HiDPI, so points
        // = native pixels / 2 (rounded down to even for the encoder).
        let pointsWide = (info.pixelsWide / 2) & ~1
        let pointsHigh = (info.pixelsHigh / 2) & ~1
        // Rough physical size so macOS picks a sane default UI scale.
        let mm = info.pixelsWide >= info.pixelsHigh
            ? CGSize(width: 147, height: 68)
            : CGSize(width: 68, height: 147)

        // USB sessions can start before lockdown resolves the device name —
        // fall back to the kind from the hello rather than the generic label.
        let displayName = endpointName.hasPrefix("iPhone / iPad")
            ? "OpenDisplay — \(info.kind)"
            : "OpenDisplay — \(endpointName)"
        // Orientation-specific serial: macOS persists the chosen mode per
        // serial, and a portrait mode restored onto a landscape display
        // pillarboxes the desktop INTO the framebuffer (streamed as-is).
        // Distinct serials per orientation keep the two configs apart.
        let serial = info.pixelsWide >= info.pixelsHigh
            ? displaySerial
            : displaySerial ^ 0x8000_0000
        // Arrangement memory (#116): keyed on the device's install id so the
        // display returns to its spot across transports and orientations —
        // the serial-keyed memory macOS keeps starts from scratch whenever
        // the serial changes. Old receivers without an id fall back to the
        // session serial, which is at least orientation-stable.
        let arrangementKey = info.id ?? String(format: "serial-%08x", displaySerial)
        let sizeInPoints = CGSize(width: pointsWide, height: pointsHigh)
        // Creating a display whose serial is still registered fails — e.g. a
        // just-quit instance's display lingers in WindowServer for a moment
        // after the process dies. Retry through that window instead of
        // parking the session on "Failed" until a manual reconnect.
        var vd: VirtualDisplay?
        for attempt in 0..<8 {
            if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
            // A Disconnect during the retry window tore the session down. Bail
            // before creating/assigning the display: the serial the old display
            // held is likely free now, so a late attempt would *succeed* and
            // resurrect the very zombie this retry exists to avoid. (Mirrors the
            // `if stopped` checks in the permission-poll loops above.)
            if stopped { return }
            vd = await MainActor.run {
                VirtualDisplay(name: displayName,
                               pointsWide: pointsWide, pointsHigh: pointsHigh,
                               sizeInMillimeters: mm, serialNum: serial,
                               restoreOrigin: DisplayArrangement.origin(for: sizeInPoints,
                                                                        device: arrangementKey),
                               onOriginChange: { origin in
                                   DisplayArrangement.save(origin: origin, size: sizeInPoints,
                                                           device: arrangementKey)
                               })
            }
            if vd != nil { break }
            Log.info("virtual display creation failed (attempt \(attempt + 1)) — retrying")
            await status("Preparing virtual display…")
        }
        guard let vd else {
            throw NSError(domain: "MacSender", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "CGVirtualDisplay creation failed"])
        }
        virtualDisplay = vd
        inputInjector = InputInjector(displayID: vd.displayID)

        let display = try await findSCDisplay(id: vd.displayID)
        // Quality scaling: capture/encode below native when requested — the
        // display itself stays native so window layout is unaffected.
        let captureW = (Int(Double(pointsWide * 2) * quality.scale)) & ~1
        let captureH = (Int(Double(pointsHigh * 2) * quality.scale)) & ~1
        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)

        // Debug aid (`defaults write sh.peet.opensidecar.mac testPattern -bool true`):
        // an animated window on the virtual display generates a constant frame
        // stream so steady-state latency can be measured without user activity.
        if UserDefaults.standard.bool(forKey: "testPattern") {
            let id = vd.displayID
            Task { @MainActor in TestPattern.show(on: id) }
        }
    }

    /// Tear down and rebuild when the phone announces new dimensions. Loops
    /// until the built display matches the latest hello, so rotations that
    /// arrive mid-rebuild aren't lost (and rapid flip-flops settle once).
    private var reconfiguring = false
    private func reconfigure(_ info: PhoneInfo) async {
        guard !reconfiguring, !stopped else { return }
        reconfiguring = true
        defer { reconfiguring = false }
        var target = info
        while !stopped {
            Log.info("reconfiguring for \(target.pixelsWide)x\(target.pixelsHigh)")
            if let stream { try? await stream.stopCapture() }
            stream = nil
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
            virtualDisplay = nil   // removes the old display
            needsKeyframe = true
            do {
                try await setupExtend(target)
            } catch {
                Log.info("reconfigure failed: \(error)")
                await status("Rotation failed: \(error.localizedDescription)")
                return
            }
            if let latest = lastHello,
               latest.pixelsWide != target.pixelsWide || latest.pixelsHigh != target.pixelsHigh {
                target = latest   // rotated again while we were rebuilding
                continue
            }
            return
        }
    }

    /// The virtual display takes a moment to show up in shareable content.
    private func findSCDisplay(id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<20 {
            let content = try await SCShareableContent.current
            if let display = content.displays.first(where: { $0.displayID == id }) {
                return display
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NSError(domain: "MacSender", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "virtual display never appeared in SCShareableContent"])
    }

    private func startCapture(display: SCDisplay, pixelsWide: Int, pixelsHigh: Int) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = pixelsWide
        config.height = pixelsHigh
        // Ask for 120 even though the virtual display is 60Hz: requesting
        // exactly 1/60 makes SCK's rate limiter skip frames that arrive a
        // hair early (beat frequency) — measured ~51fps instead of 60.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        // 420v matches the encoder's native input — skips a BGRA→YUV conversion
        // inside VideoToolbox. (`-pixfmt bgra` reverts for A/B testing.)
        config.pixelFormat = UserDefaults.standard.string(forKey: "pixfmt") == "bgra"
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // One buffer is held permanently (keyframe replay) and one sits in
        // the encoder for ~13ms — headroom prevents SCK starvation drops.
        config.queueDepth = 8
        config.showsCursor = !localCursor

        setupEncoder(width: pixelsWide, height: pixelsHigh)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        captureDisplayID = display.displayID
        lastCursorPNGHash = 0      // rotation rebuilds: re-send the sprite
        lastCursorSent = (-1, -1, false)
        startCursorEcho()
        Log.info("capture started: \(pixelsWide)x\(pixelsHigh) display \(display.displayID) mode \(mode.rawValue) localCursor=\(localCursor)")
        let kind = lastHello?.kind ?? "device"
        await status("\(mode == .extend ? "Extending to" : "Mirroring to") \(kind) (\(pixelsWide)×\(pixelsHigh))")
    }

    func stop() {
        stopped = true
        cursorTimer?.cancel()
        cursorTimer = nil
        cursorImageTimer?.cancel()
        cursorImageTimer = nil
        stream?.stopCapture { _ in }
        stream = nil
        connection?.cancel()
        connection = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        virtualDisplay = nil   // releasing it removes the display
        queue.async { [weak self] in
            // Unblock a start() that is still waiting for the hello.
            self?.helloContinuation?.resume(throwing: CancellationError())
            self?.helloContinuation = nil
        }
    }

    /// Migrate the live session to another transport: swap the socket under
    /// the pipeline — virtual display, capture and encoder stay up (no
    /// display destroy/create, so no screen flash and no window reshuffle)
    /// while the connection redials over the new transport. The receiver
    /// treats it like any reconnect: the fresh connection replaces the old
    /// one and the video resyncs with a keyframe. Which transport to be on
    /// is the controller's call (cable-in upgrade, unplug failover).
    func switchTransport(to newTransport: SenderTransport) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let label = if case .usb = newTransport { "USB" } else { "WiFi" }
            Log.info("switching \(self.endpointName) to \(label)")
            self.transport = newTransport
            // Fresh grace window: if the new link can't come up either, the
            // session ends like any other disconnect instead of dialing
            // a dead transport forever.
            self.disconnectedSince = Date()
            self.connectionReady = false
            self.dialGeneration += 1   // a dial still in flight must not adopt
            self.connection?.cancel()
            self.connection = nil
            self.pendingSends = 0
            self.pipelineLock.lock()
            self.pendingEncodes = 0
            self.pipelineLock.unlock()
            self.connect()
        }
    }

    /// A dial was actively refused (must be called on `queue`). On a session
    /// that has streamed before, enough refusals in a row prove the receiver
    /// app is gone — end now instead of waiting out the grace.
    private func dialRefused() {
        guard everConnected, !stopped else { return }
        consecutiveRefusals += 1
        if consecutiveRefusals == refusalsBeforeGivingUp {
            Log.info("dial refused \(consecutiveRefusals)x — receiver app is gone, ending session")
            Task { @MainActor in self.onDisconnected?() }
        }
    }

    /// The receiver's Bonjour advertisement disappeared (the system
    /// deregisters a dead app's service within ~1s, while a suspended app
    /// keeps it). Only meaningful once the connection is already down —
    /// a live connection outranks a flapping mDNS cache. Together they
    /// prove a WiFi receiver quit, where dials just stall instead of
    /// being refused.
    func peerServiceWithdrawn() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.everConnected,
                  !self.connectionReady else { return }
            Log.info("service withdrawn and connection down — receiver app is gone, ending session")
            Task { @MainActor in self.onDisconnected?() }
        }
    }

    /// Drop the current connection and dial again — fresh TCP through the
    /// tunnel, fresh accept on the phone. Bound to the UI Reconnect button.
    func forceReconnect() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            Log.info("manual reconnect requested")
            self.disconnectedSince = Date()   // fresh grace window
            self.scheduleReconnect()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("stream stopped with error: \(error)")
        Task { await status("Capture stopped: \(error.localizedDescription)") }
        // E.g. display sleep can tear the virtual display down underneath the
        // stream — rebuild instead of sitting dead until an app restart.
        guard !stopped, mode == .extend else { return }
        self.stream = nil
        scheduleCaptureRecovery()
    }

    /// Retry until capture is back (a rebuild during display sleep can fail).
    private func scheduleCaptureRecovery() {
        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, !self.stopped, self.stream == nil,
                  let hello = self.lastHello else { return }
            Log.info("capture died — rebuilding pipeline")
            Task {
                await self.reconfigure(hello)
                self.queue.async {
                    if self.stream == nil { self.scheduleCaptureRecovery() }
                }
            }
        }
    }

    // MARK: - Connection (with retry)

    // Guards against a stale async USB dial adopting after a newer one (or a
    // manual reconnect) superseded it. Only touched on `queue`.
    private var dialGeneration = 0

    private func connect() {
        guard !stopped else { return }
        switch transport {
        case .tcp(let endpoint): connectTCP(endpoint)
        case .usb(let udid, let port): connectUSB(udid: udid, port: port)
        }
    }

    /// Bookkeeping shared by both transports once a connection is live.
    private func becomeReady(_ conn: NWConnection) {
        Log.info("connection ready to \(endpointName)")
        connectionReady = true
        everConnected = true
        awaitingWake = false
        consecutiveRefusals = 0
        disconnectedSince = nil
        needsKeyframe = true   // new peer needs SPS/PPS + IDR
        // A reconnect can recreate the phone's video view with no cursor
        // sprite; the sprite is otherwise only sent on shape change, so the
        // cursor would stay invisible until the user hovers something that
        // changes it. Reset the dedup state to re-send sprite + position to
        // the fresh peer — the cursor analogue of forcing a keyframe.
        lastCursorPNGHash = 0
        lastCursorSent = (-1, -1, false)
        lastReceived = Date()  // fresh grace period for the watchdog
        receiveControl(on: conn)
        Task { await self.status("Connected to \(self.endpointName)") }
    }

    private func connectTCP(_ endpoint: NWEndpoint) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true   // latency matters more than throughput here
        let params = NWParameters(tls: nil, tcp: options)
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        // A dial to a withdrawn Bonjour service (receiver asleep or app
        // closed) sits in .preparing forever — it neither fails nor resolves
        // when the service later returns, observed on macOS 26. Give every
        // dial a deadline and redial fresh: a new NWConnection re-runs
        // Bonjour resolution, so the retry loop reaches the receiver the
        // moment it advertises again.
        let generation = dialGeneration
        queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, generation == self.dialGeneration, !self.stopped,
                  self.connection === conn, conn.state != .ready else { return }
            Log.info("dial timed out in \(conn.state) — redialing")
            self.scheduleReconnect()
        }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.becomeReady(conn)
            case .failed(let error):
                Log.info("connection failed: \(error)")
                self.connectionReady = false
                if case .posix(let code) = error, code == .ECONNREFUSED {
                    self.dialRefused()
                }
                self.scheduleReconnect()
            case .waiting(let error):
                // On loopback there is no "path change" to wake us up again
                // (e.g. a manual -host tunnel not started yet) — treat
                // waiting as failure and poll by reconnecting.
                Log.info("connection waiting: \(error) — will retry")
                self.connectionReady = false
                Task { await self.status(self.awaitingWake
                    ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                    : "Waiting for receiver at \(self.endpointName)…") }
                self.scheduleReconnect()
            case .cancelled:
                self.connectionReady = false
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// Dial through macOS's built-in usbmuxd — no external tunnel needed.
    /// The handshake is async, so adoption is gated on `dialGeneration`.
    private func connectUSB(udid: String?, port: UInt16) {
        dialGeneration += 1
        let generation = dialGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let conn = try await Usbmux.dial(udid: udid, port: port, queue: queue)
                queue.async {
                    guard generation == self.dialGeneration, !self.stopped else {
                        conn.cancel()
                        return
                    }
                    self.connection = conn
                    conn.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .failed(let error):
                            Log.info("usb connection failed: \(error)")
                            self.connectionReady = false
                            self.scheduleReconnect()
                        case .cancelled:
                            self.connectionReady = false
                        default:
                            break
                        }
                    }
                    self.becomeReady(conn)
                }
            } catch {
                // Distinct guidance per failure: cable missing vs app closed.
                let hint: String
                switch error as? Usbmux.Failure {
                case .noDevice:
                    hint = "Waiting for a USB device — plug in the iPhone or iPad…"
                case .refused:
                    hint = self.awaitingWake
                        ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                        : "Device found — open the OpenDisplay app on it…"
                default:
                    Log.info("usb dial failed: \(error)")
                    hint = "USB connection failed: \(error.localizedDescription)"
                }
                queue.async {
                    guard generation == self.dialGeneration, !self.stopped else { return }
                    if case .refused = error as? Usbmux.Failure {
                        self.dialRefused()
                    }
                    Task { await self.status(hint) }
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        if everConnected {
            if let since = disconnectedSince {
                if Date().timeIntervalSince(since) > disconnectGraceSeconds {
                    Log.info("device gone for >\(Int(disconnectGraceSeconds))s — ending session")
                    Task { @MainActor in self.onDisconnected?() }
                    return
                }
            } else {
                disconnectedSince = Date()
                Task { await status("Connection lost — retrying for \(Int(disconnectGraceSeconds))s…") }
            }
        }
        connectionReady = false
        dialGeneration += 1   // a USB dial still in flight must not adopt
        let generation = dialGeneration
        connection?.cancel()
        connection = nil
        pendingSends = 0
        pipelineLock.lock()
        pendingEncodes = 0
        pipelineLock.unlock()
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            // Generation-guarded so a switchTransport (or another reconnect)
            // that landed in this 1s window supersedes this dial instead of
            // racing it — otherwise the queued connect() re-dials the new
            // transport, briefly running two live connections. (No bare
            // self-rescheduling asyncAfter — the pattern banned in #76.)
            guard let self, generation == self.dialGeneration, !self.stopped else { return }
            self.connect()
        }
    }

    // MARK: - Liveness (ping + watchdog)

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.connectionReady {
                // Liveness + send-side health for the phone's overlay.
                let elapsed = Date().timeIntervalSince(self.capWindowStart)
                let capFps = elapsed > 0 ? Int(Double(self.capFrames) / elapsed) : 0
                self.capFrames = 0
                self.capWindowStart = Date()
                let sorted = self.inputLatencies.sorted()
                let inp50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2].rounded()
                let inp95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))].rounded()
                self.sendJSONFrame("{\"type\":\"ping\",\"drops\":\(self.dropsTotal),\"encDrops\":\(self.dropsEncTotal),\"netDrops\":\(self.dropsNetTotal),\"pending\":\(self.pendingSends),\"inp50\":\(inp50),\"inp95\":\(inp95),\"capFps\":\(capFps)}")
            }
            self.schedulePing()
        }
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.connectionReady, Date().timeIntervalSince(self.lastReceived) > 5 {
                // A suspended receiver app (user switched apps) goes silent
                // like this while its kernel still accepts redials — the
                // session and display are kept on purpose so the user's
                // window arrangement survives until they come back. Genuine
                // network loss fails the redials and ends via the grace.
                Log.info("watchdog: nothing from the phone for >5s — reconnecting")
                Task { await self.status("\(self.endpointName) app in background — keeping the display") }
                self.scheduleReconnect()
            }
            // The disconnect grace is otherwise only evaluated when a dial
            // changes state — a dial stuck in .preparing (withdrawn Bonjour
            // service) would keep a dead session's display up forever.
            // Enforce it from here too, where the clock always ticks.
            if !self.connectionReady, self.everConnected,
               let since = self.disconnectedSince,
               Date().timeIntervalSince(since) > self.disconnectGraceSeconds {
                Log.info("device gone for >\(Int(self.disconnectGraceSeconds))s — ending session")
                Task { @MainActor in self.onDisconnected?() }
            }
            // A reconnect on a static screen produces no capture frames, so
            // the receiver would stay black — replay the last frame as IDR.
            if self.connectionReady, self.needsKeyframe,
               Date().timeIntervalSince(self.lastCaptureAt) > 1,
               let pixelBuffer = self.lastPixelBuffer {
                Log.info("static screen after reconnect — replaying last frame as keyframe")
                self.encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
            }
            self.scheduleWatchdog()
        }
    }

    // MARK: - Local cursor echo (Mac -> phone)

    private func startCursorEcho() {
        guard localCursor else { return }
        cursorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))   // 120Hz
        timer.setEventHandler { [weak self] in self?.pollCursorPosition() }
        timer.resume()
        cursorTimer = timer
        scheduleCursorImagePoll()
    }

    /// Sprite changes (arrow ↔ I-beam ↔ resize…) must land fast or the wrong
    /// cursor shows over hot areas — poll at 30Hz on the main thread (NSCursor
    /// is AppKit), hash the raw bitmap, and only PNG-encode + send on change.
    ///
    /// A dedicated timer (cancelled+replaced here, like cursorTimer above) — not
    /// a self-rescheduling asyncAfter chain. Every rebuild re-enters
    /// startCursorEcho, and sleep/wake rebuilds happen often; a recursive chain
    /// guarded only by `stopped` would stack one extra 30Hz main-thread
    /// TIFF-encode loop per rebuild, creeping CPU to ~50% until a restart (#75).
    private func scheduleCursorImagePoll() {
        cursorImageTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.033, repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.localCursor else { return }
            self.pollCursorImage()
        }
        timer.resume()
        cursorImageTimer = timer
    }

    private func pollCursorPosition() {
        guard connectionReady, captureDisplayID != 0,
              let loc = CGEvent(source: nil)?.location else { return }
        let bounds = CGDisplayBounds(captureDisplayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.contains(loc) {
            let x = (loc.x - bounds.minX) / bounds.width
            let y = (loc.y - bounds.minY) / bounds.height
            if !lastCursorSent.visible
                || abs(x - lastCursorSent.x) > 0.0004 || abs(y - lastCursorSent.y) > 0.0004 {
                lastCursorSent = (x, y, true)
                sendJSONFrame(String(format: "{\"type\":\"cursor\",\"x\":%.4f,\"y\":%.4f,\"v\":1}", x, y))
            }
        } else if lastCursorSent.visible {
            lastCursorSent.visible = false
            sendJSONFrame("{\"type\":\"cursor\",\"v\":0}")
        }
    }

    private func pollCursorImage() {
        // Display size read LIVE, not snapshotted at capture start: the
        // HiDPI mode settles (and macOS re-flips it) asynchronously, and a
        // sprite normalized against the 1x size renders at half size on the
        // device. Mixing the size into the dedup hash re-sends the sprite
        // whenever the mode flips, so the proportion always heals.
        guard connectionReady, captureDisplayID != 0,
              let cursor = NSCursor.currentSystem else { return }
        let displaySize = CGDisplayBounds(captureDisplayID).size   // points, current mode
        guard displaySize.width > 0, displaySize.height > 0 else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return }
        let hash = tiff.hashValue ^ Int(displaySize.width) &* 31
        guard hash != lastCursorPNGHash else { return }
        guard let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              png.count < 24_000 else { return }
        lastCursorPNGHash = hash
        let size = image.size            // Mac points
        let hot = cursor.hotSpot
        // Normalized against the display so the phone can size/anchor the
        // sprite without knowing capture scale or HiDPI factor.
        let msg = String(format:
            "{\"type\":\"cursorImg\",\"nw\":%.5f,\"nh\":%.5f,\"ax\":%.3f,\"ay\":%.3f,\"png\":\"%@\"}",
            size.width / displaySize.width,
            size.height / displaySize.height,
            size.width > 0 ? hot.x / size.width : 0,
            size.height > 0 ? hot.y / size.height : 0,
            png.base64EncodedString())
        queue.async { self.sendJSONFrame(msg) }
    }

    // MARK: - Control messages (phone -> Mac)

    private func receiveControl(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, data.count == 4 else { return }
            let len = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard len > 0, len < 1 << 20 else { return }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] payload, _, _, error in
                guard let self, error == nil, let payload, payload.count == len else { return }
                self.handleControl(payload)
                self.receiveControl(on: conn)
            }
        }
    }

    private func handleControl(_ payload: Data) {
        lastReceived = Date()
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = obj["type"] as? String else {
            Log.info("unparseable control message (\(payload.count) bytes)")
            return
        }
        switch type {
        case "ping":
            // Echo with our clock so the phone can estimate the offset
            // (NTP-style) and compute true end-to-end frame latency.
            if let t = obj["t"] as? Double {
                let mt = Date().timeIntervalSince1970 * 1000
                sendJSONFrame("{\"type\":\"pong\",\"t\":\(t),\"mt\":\(mt)}")
            }
        case "stats":
            // Aggregated pipeline health measured on the phone — logged here
            // so one file holds both ends of the story.
            if let json = try? JSONSerialization.data(withJSONObject: obj),
               let line = String(data: json, encoding: .utf8) {
                Log.info("PHONE-STATS \(line) | mac enc↓=\(dropsEncThisWindow) net↓=\(dropsNetThisWindow) pending=\(pendingSends)")
                dropsEncThisWindow = 0
                dropsNetThisWindow = 0
            }
        case "hello":
            if let info = try? JSONDecoder().decode(PhoneInfo.self, from: payload) {
                let previous = lastHello
                lastHello = info
                Task { @MainActor in self.onHello?(info) }
                // Version handshake (issue #132). Reply with our identity, and
                // if the receiver is below the version we support, tell it to
                // update. Both are additive: older receivers ignore unknown
                // message types. Sending on every hello is idempotent — the
                // phone dedupes by content.
                sendWelcome()
                if info.protocolVersion < WireProtocol.minSupportedPeer {
                    Log.info("receiver protocol \(info.protocolVersion) below supported \(WireProtocol.minSupportedPeer) — requesting update")
                    sendUpdateRequired(kind: info.kind)
                }
                if let continuation = helloContinuation {
                    helloContinuation = nil
                    continuation.resume(returning: info)
                } else if mode == .extend, stream != nil, let previous,
                          previous.pixelsWide != info.pixelsWide
                          || previous.pixelsHigh != info.pixelsHigh {
                    // Phone rotated — rebuild after a short debounce so a
                    // flurry of orientation flips settles into one rebuild.
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard let current = self.lastHello,
                              current.pixelsWide == info.pixelsWide,
                              current.pixelsHigh == info.pixelsHigh else { return }
                        await self.reconfigure(info)
                    }
                }
            }
        case "touch":
            if let phase = obj["phase"] as? String,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                inputInjector?.handleTouch(phase: phase, x: x, y: y)
                if let t = obj["t"] as? Double {
                    let delta = Date().timeIntervalSince1970 * 1000 - t
                    if delta > -50, delta < 1000 {
                        inputLatencies.append(max(delta, 0))
                        if inputLatencies.count > 240 { inputLatencies.removeFirst(120) }
                    }
                }
            }
        case "scroll":
            if let dx = obj["dx"] as? Double, let dy = obj["dy"] as? Double {
                inputInjector?.handleScroll(dx: dx, dy: dy)
            }
        case "kf":
            // The phone's decoder lost sync (e.g. it attached mid-GOP and
            // periodic keyframes are off) — force an IDR on the next frame.
            Log.info("phone requested keyframe")
            needsKeyframe = true
        case WireMessage.sleeping:
            // The device locked and is about to close on us. Hand the
            // session to the controller right away: it tears the virtual
            // display down (returning the cursor to a visible screen) and
            // starts a wake-waiting replacement session.
            Log.info("receiver went to sleep — ending session, reconnect armed for wake")
            Task { @MainActor in self.onPeerSleeping?() }
        case WireMessage.closing:
            // The app on the device is quitting for real — end the session
            // without the silence grace and without waiting for a wake.
            Log.info("receiver app closed — ending session")
            Task { @MainActor in self.onPeerClosed?() }
        default:
            Log.info("unknown control message type: \(type)")
        }
    }

    private func waitForHello() async throws -> PhoneInfo {
        if let lastHello { return lastHello }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let hello = self.lastHello {
                    continuation.resume(returning: hello)
                } else {
                    self.helloContinuation = continuation
                }
            }
        }
    }

    // MARK: - Encoder setup

    private func setupEncoder(width: Int, height: Int) {
        // Low-latency rate control: the hardware encoder emits every frame
        // immediately instead of pipelining. (`-lowlatency NO` for A/B.)
        let lowLatency = UserDefaults.standard.object(forKey: "lowlatency") == nil
            || UserDefaults.standard.bool(forKey: "lowlatency")
        let spec: CFDictionary? = lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
            : nil
        VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder
        )
        guard let encoder else {
            Log.info("FATAL: VTCompressionSessionCreate failed")
            return
        }
        // Low-latency settings: real-time, no B-frames, periodic keyframes.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        // No periodic IDRs: each one is a bitrate spike → transmit-time hiccup.
        // TCP never loses data, and we force a keyframe on reconnect/drop.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: quality.bitrate as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(encoder)
        Log.info("encoder ready: \(width)x\(height) H.264 \(quality.bitrate / 1_000_000)Mbps quality=\(quality.rawValue) lowLatencyRC=\(lowLatency)")
    }

    // MARK: - Capture callback

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        lastPixelBuffer = pixelBuffer
        lastCaptureAt = Date()
        capFrames += 1

        // No receiver, or a pipeline stage is backed up: skip this frame.
        guard connectionReady else { return }
        if shouldDropFrame(reason: "pending_encode") { return }  // encoder busy
        if shouldDropFrame(reason: "pending_sends") { return }   // TCP send queue full

        encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// Drop when encode or send pipeline is busy.
    /// Pre-encode drops are invisible to the decoder — the H.264 reference
    /// chain stays intact, so the next frame can be a normal P-frame (n → n+2).
    /// Do NOT force keyframes here; that causes IDR pulsing / blockiness.
    private func shouldDropFrame(reason: String) -> Bool {
        pipelineLock.lock()
        let drop: Bool
        switch reason {
        case "pending_encode":
            drop = pendingEncodes >= maxPendingEncodes
        case "pending_sends":
            drop = pendingSends >= maxPendingSends
        default:
            drop = false
        }
        pipelineLock.unlock()
        guard drop else { return false }
        switch reason {
        case "pending_encode":
            dropsEncThisWindow += 1
            dropsEncTotal += 1
        case "pending_sends":
            dropsNetThisWindow += 1
            dropsNetTotal += 1
        default:
            break
        }
        return true
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let encoder else { return }
        pipelineLock.lock()
        pendingEncodes += 1
        pipelineLock.unlock()
        let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        var frameProperties: CFDictionary?
        if needsKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            needsKeyframe = false
        }
        let submitStatus = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, buffer in
            guard let self else { return }
            defer {
                self.pipelineLock.lock()
                self.pendingEncodes = max(0, self.pendingEncodes - 1)
                self.pipelineLock.unlock()
            }
            guard status == noErr, let buffer else { return }
            if let data = self.annexB(from: buffer) {
                let sndMs = Int64(Date().timeIntervalSince1970 * 1000)
                var framed = Data("{\"cap\":\(capturedAtMs),\"snd\":\(sndMs)}".utf8)
                framed.append(data)
                self.sendFramed(framed)
            }
        }
        if submitStatus != noErr {
            pipelineLock.lock()
            pendingEncodes = max(0, pendingEncodes - 1)
            pipelineLock.unlock()
            Log.info("VTCompressionSessionEncodeFrame failed: \(submitStatus)")
        }
    }

    // MARK: - H.264 -> Annex B

    private func annexB(from sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &len, totalLengthOut: &total,
                dataPointerOut: &ptr) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 128)
        // On keyframes, prepend SPS/PPS (they live in the format description).
        if isKeyframe(sample), let fmt = CMSampleBufferGetFormatDescription(sample) {
            for i in 0..<2 {           // index 0 = SPS, 1 = PPS
                var psPtr: UnsafePointer<UInt8>?
                var psLen = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let psPtr {
                    out.append(contentsOf: startCode)
                    out.append(Data(bytes: psPtr, count: psLen))
                }
            }
        }
        // Convert AVCC (4-byte length-prefixed NALUs) to Annex B start codes.
        let raw = UnsafeRawPointer(ptr)
        var offset = 0
        while offset + 4 <= total {
            var nalLen: UInt32 = 0
            memcpy(&nalLen, raw + offset, 4)
            nalLen = CFSwapInt32BigToHost(nalLen)
            offset += 4
            guard offset + Int(nalLen) <= total else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + offset, count: Int(nalLen)))
            offset += Int(nalLen)
        }
        return out
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let dict = (arr as? [[CFString: Any]])?.first else { return true }
        return !(dict[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    // MARK: - Wire framing: [4-byte big-endian length][payload]

    /// Control messages on the video channel (pong etc.) — framed JSON without
    /// start codes; the receiver routes payloads starting with '{'.
    // MARK: - Version handshake (issue #132)

    /// Identify ourselves to the receiver: our protocol version and the oldest
    /// receiver version we still support.
    private func sendWelcome() {
        sendJSONFrame("{\"type\":\"\(WireMessage.welcome)\",\"pv\":\(WireProtocol.version),\"min\":\(WireProtocol.minSupportedPeer)}")
    }

    /// Ask the receiver to update from the App Store (built via JSONSerialization
    /// because the message text is user-facing prose).
    private func sendUpdateRequired(kind: String) {
        let dict: [String: Any] = [
            "type": WireMessage.updateRequired,
            "target": "ios",
            "store": AppStore.updateURL.absoluteString,
            "message": "This \(kind) app is too old for this Mac. Update OpenDisplay from the App Store to reconnect.",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            sendJSONFrame(json)
        }
    }

    private func sendJSONFrame(_ json: String) {
        guard let connection, connectionReady else { return }
        let payload = Data(json.utf8)
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func sendFramed(_ payload: Data) {
        guard let connection, connectionReady else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        pendingSends += 1
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingSends -= 1
            if let error {
                Log.info("send error: \(error)")
                return
            }
            self.framesSent += 1
            self.bytesSent += frame.count
            // Report stats roughly once a second.
            let elapsed = Date().timeIntervalSince(self.statsWindowStart)
            if elapsed >= 1.0 {
                let mbps = Double(self.bytesSent) * 8 / elapsed / 1_000_000
                let frames = self.framesSent
                self.bytesSent = 0
                self.statsWindowStart = Date()
                Task { @MainActor in self.onStats?(frames, mbps) }
            }
        })
    }

    // MARK: - Helpers

    private func status(_ text: String) async {
        await MainActor.run { onStatus?(text) }
    }
}
