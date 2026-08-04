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
    let hevc: Bool?       // receiver decodes HEVC (Mac receivers); absent on
                          // iOS receivers → stay on H.264
    let prores4444: Bool? // paired Mac receiver accepts framed ProRes 4444
    let prores4444XQ: Bool? // paired Mac receiver accepts ProRes 4444 XQ
    let receiverVersion: String?
    let receiverBuild: String?
    let renderPath: String?
    let colorSpace: WireColorSpace? // stream working gamut; absent = sRGB
    // Exact active display profile from a Mac receiver. A gamut enum alone
    // loses the factory calibration/TRCs that distinguish an iMac profile
    // from generic Display P3.
    let iccProfile: String?
    // Some receivers deliberately use the system video presentation layer
    // for its native ColorSync path. Those receivers ask ScreenCaptureKit to
    // bake the cursor into the video so no independent overlay can force the
    // display compositor to switch planes (observed as black flashes/trails).
    let cursorInVideo: Bool?
    // Optional low-latency side channel advertised by Mac receivers. Cursor
    // position datagrams bypass the ordered multi-megabyte video stream.
    let cursorHost: String?
    let cursorPort: Int?

    var kind: String { device ?? "device" }
    var protocolVersion: Int { pv ?? WireProtocol.assumedWhenAbsent }
    var iccProfileData: Data? {
        guard let iccProfile, iccProfile.count <= 1_500_000 else { return nil }
        return Data(base64Encoded: iccProfile)
    }
}

/// How the sender reaches the receiver. Reconnects re-dial from scratch, so
/// a USB device that was replugged (new usbmuxd DeviceID) is found again.
enum SenderTransport {
    // Bonjour bridge endpoints resolve afresh for every NWConnection, so a
    // receiver's link-local IP may change without invalidating the session.
    // Binding the endpoint to its discovered interface also prevents a
    // bridge-selected service from silently resolving over en0/WiFi.
    case tcp(NWEndpoint, requiredInterface: NWInterface?)
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
    // Called when a TCP connection is ready, reporting the detected local
    // interface type ("bridge" for Thunderbolt, "wifi" otherwise).
    @MainActor var onTransportDetected: ((String) -> Void)?

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var connection: NWConnection?
    private var cursorConnection: NWConnection?
    private var cursorConnectionReady = false
    private var cursorEndpointKey = ""
    private var cursorSequence: UInt64 = 0
    private var virtualDisplay: VirtualDisplay?
    private let queue = DispatchQueue(label: "sender.video")
    private let startCode: [UInt8] = [0, 0, 0, 1]

    // The dial target. Written on `queue` only (after init): the controller
    // can migrate a live session between transports via switchTransport.
    private var transport: SenderTransport
    private let endpointName: String
    private let mode: CaptureMode
    private let quality: StreamQuality
    private var shouldUseHEVC: Bool {
        (lastHello?.hevc ?? false)
            && !UserDefaults.standard.bool(forKey: "forceH264")
    }
    private var shouldUseProRes4444: Bool {
        (lastHello?.prores4444 ?? false)
            && !UserDefaults.standard.bool(forKey: "disableProRes4444")
    }
    private var shouldUseProRes4444XQ: Bool {
        shouldUseProRes4444 && (lastHello?.prores4444XQ ?? false)
            && !UserDefaults.standard.bool(forKey: "disableProRes4444XQ")
    }
    private var workingColorSpace: WireColorSpace {
        lastHello?.colorSpace ?? .sRGB
    }
    private var workingICCProfile: Data? { lastHello?.iccProfileData }
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
    // 1 for phone-class panels (latest-frame-wins, minimum latency). At 4K
    // a single encode takes ~20ms — longer than a 60fps interval — so one
    // slot halves the frame rate; two slots pipeline the hardware encoder
    // back to full throughput for ~17ms extra latency. Set by setupEncoder.
    private var maxPendingEncodes = 1
    // Low-latency native streams can use a fixed low HEVC QP. The 4.5K path
    // instead constrains the normal hardware rate controller with a maximum
    // QP because per-frame BaseFrameQP is ignored outside low-latency mode.
    // Set during setupEncoder and read on `queue`.
    private var fixedDesktopQP: Int?

    // ── Static-screen refresh ────────────────────────────────────────────
    //
    // When motion stops, the receiver keeps showing the LAST frame — encoded
    // mid-motion on a starved bit budget, so flat fills around the moved
    // content freeze with visible quantization splotches ("colored noise on
    // solid backgrounds"). Re-encoding the same frame does not heal them:
    // HEVC codes unchanged flat blocks as skip, so the ghost noise survives
    // every subsequent P-frame. Measured on the 4480x2520 Main10 pipeline:
    // 4x4-block chroma deviation of ~37/1024 after a window drag, unchanged
    // by refinement P-frames, and only ~27 after a forced main-session IDR
    // (the rate controller still owes debt from the motion burst).
    //
    // Fix: once the screen has been still for a moment, re-encode the frozen
    // frame ONCE as a true high-quality IDR through a separate low-latency
    // HEVC session. kVTEncodeFrameOptionKey_BaseFrameQP is honored only
    // under low-latency rate control (the main session's fixed-QP request is
    // silently ignored outside it), and a low-QP IDR reconstructs flat fills
    // exactly (measured zero luma error). The refresh IDR is ~1.4MB — a
    // one-off burst the idle link absorbs. The main session never saw this
    // frame, so its next real frame must resync the reference chain with a
    // forced keyframe (cheap; it happens while content is moving again).
    // All state lives on `queue`.
    private var refreshEncoder: VTCompressionSession?
    private var refreshEncoderFailed = false
    private var staticRefreshDone = false      // one refresh per still period
    private var refreshInFlight = false
    private var resyncMainOnNextFrame = false  // next main-session frame = IDR
    private var lastRefreshAt = Date.distantPast
    private var refreshMotionBurstFrames = 0
    private var lastRefreshMotionFrameAt = Date.distantPast
    private var encoderIsHEVC = false
    private var encoderIsProRes4444 = false
    private var encoderIsProRes4444XQ = false
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var encoderInputPixelFormat: OSType = 0
    // Still-screen detection threshold + a floor between refreshes so
    // periodic tiny redraws (a blinking terminal cursor) can't turn into a
    // refresh/resync loop.
    private let staticRefreshDelay: TimeInterval = 0.5
    private let staticRefreshMinInterval: TimeInterval = 2.0
    private var staticRefreshEnabled: Bool {
        UserDefaults.standard.object(forKey: "staticRefresh") == nil
            || UserDefaults.standard.bool(forKey: "staticRefresh")
    }
    private var staticRefreshQP: Int {
        let override = UserDefaults.standard.integer(forKey: "refreshQP")
        return (1...51).contains(override) ? override : 8
    }

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
    private let localCursorPreference = UserDefaults.standard.object(forKey: "localCursor") == nil
        || UserDefaults.standard.bool(forKey: "localCursor")
    private var localCursor: Bool {
        localCursorPreference && !(lastHello?.cursorInVideo ?? false)
    }
    private var cursorTimer: DispatchSourceTimer?
    private var cursorImageTimer: DispatchSourceTimer?
    private var lastCursorSent: (x: Double, y: Double, visible: Bool) = (-1, -1, false)
    private var lastCursorPNGHash = 0
    private var captureDisplayID: CGDirectDisplayID = 0
    // Static quality refreshes are large IDRs on the same ordered TCP stream
    // as cursor messages. Do not start one while either pointer is active.
    private var lastCursorActivityAt = Date.distantPast
    private var cursorOwnsReceiver: Bool {
        lastCursorSent.visible || remotePointerInsideReceiver
    }
    // The echoed visibility flag can briefly be cleared when receiver-side
    // and sender-side pointer ownership change at nearly the same time. For
    // expensive refresh decisions, also sample the real CG cursor so a stale
    // ownership message can never let a large IDR jump ahead of the pointer.
    private var cursorBlocksStaticRefresh: Bool {
        cursorOwnsReceiver || isCursorCurrentlyOnCaptureDisplay()
    }
    // ScreenCaptureKit can emit a black buffer while the pointer crosses onto
    // a virtual display. Filter only content that is actually black: pausing
    // every frame here makes AVSampleBufferDisplayLayer clear to black while
    // the independent cursor layer keeps moving (visible as cursor trails).
    private var suppressCursorEntryBlackFramesUntil = Date.distantPast
    private var remotePointerInsideReceiver = false

    // A Mac receiver sends hover moves only while its cursor is over the video
    // view. The sender's synthetic cursor itself remains parked on the virtual
    // display after the local cursor leaves that view, so `lastCursorSent`
    // alone cannot detect a later re-entry. A resumed move at the video edge
    // is the missing transition signal and re-arms the capture guard.
    private var lastRemotePointerInputAt = Date.distantPast

    // Input latency: touches arrive stamped in our clock (the phone applies
    // its sync offset); delta to now = network + deframe + dispatch.
    private var inputLatencies: [Double] = []
    // These policies bound noisy paths while retaining an explicit record when
    // details were suppressed. Unknown types and unparseable messages live on
    // `queue` with the rest of the control-connection state; encoder failures
    // are guarded by `pipelineLock` with the other pipeline counters.
    private var unknownTypeLogPolicy = UnknownControlTypeLogPolicy()
    // Encode failures repeat every frame once the session goes bad; throttle
    // the log to one line a second and carry the count.
    private var encodeFailureLogPolicy = ThrottledLogPolicy<OSStatus>()
    // Same for the encoder output callback rejecting a frame; separate policy
    // so "submit failed" and "output rejected" stay distinguishable.
    private var encodeOutputFailureLogPolicy = ThrottledLogPolicy<OSStatus>()
    // A framing desync feeds this garbage at the peer's message rate until the
    // watchdog redials, so it needs the same treatment. Detail is the byte
    // count of the last message that would not parse.
    private var unparseableControlLogPolicy = ThrottledLogPolicy<Int>()
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

    // The FIRST frame has the same problem, worse: a fresh virtual display
    // whose wallpaper finished drawing before capture started is fully
    // static, so SCK delivers nothing at all and the receiver stays dark
    // with no buffer to replay. A screenshot seeds the pipeline (observed
    // with Mac receivers, whose displays take seconds to set up).
    private var captureFilter: SCContentFilter?
    private var captureConfig: SCStreamConfiguration?
    private var captureStartedAt = Date.distantFuture
    private var seedingFirstFrame = false
    private var firstFrameLogged = false

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
            scheduleStaticRefresh()
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
            // awaitingWake is queue-confined — read it there before surfacing.
            queue.async { [weak self] in
                guard let self else { return }
                let text = self.awaitingWake
                    ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                    : "Waiting for the device to connect…"
                Task { await self.status(text) }
            }
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
        Log.info("phone hello: \(info.pixelsWide)x\(info.pixelsHigh) @\(info.scale)x "
            + "color=\((info.colorSpace ?? .sRGB).rawValue) "
            + "ICC=\(info.iccProfileData?.count ?? 0)B "
            + "receiver=\(info.receiverVersion ?? "legacy")"
            + "(\(info.receiverBuild ?? "unknown")) "
            + "render=\(info.renderPath ?? "unspecified")")

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
                               workingColorSpace: info.colorSpace ?? .sRGB,
                               targetICCProfile: info.iccProfileData,
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

        // ColorSync registers a new virtual display asynchronously. Wait for
        // its working profile before ScreenCaptureKit observes the display;
        // otherwise WindowServer first composites the desktop into sRGB and
        // clips P3 colors before capture can preserve them.
        var colorProfileReady = false
        for _ in 0..<20 {
            colorProfileReady = await MainActor.run { vd.ensureWorkingColorProfile() }
            if colorProfileReady { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if !colorProfileReady {
            Log.info("virtual display color profile did not settle before capture")
        }

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
            if let refreshEncoder { VTCompressionSessionInvalidate(refreshEncoder) }
            refreshEncoder = nil
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
               latest.pixelsWide != target.pixelsWide
                || latest.pixelsHigh != target.pixelsHigh
                || latest.colorSpace != target.colorSpace
                || latest.iccProfile != target.iccProfile {
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
        // The low-latency H.264 hardware encoder silently drops EVERY frame
        // beyond H.264 level 5.2's 60fps ceiling — observed with a Mac
        // receiver announcing 4096x2304: VTCompressionSession returns noErr
        // with a nil sample for 100% of frames, indistinguishable from "no
        // capture" without the callback-error counter. 3840x2160@60 is the
        // largest size inside the level, so clamp the CAPTURE there — the
        // virtual display keeps its native size (window layout and UI
        // density unaffected); only the stream is downscaled, exactly like
        // the quality presets already do. HEVC's hardware envelope is far
        // larger (8K-class), so its clamp exists only as a sanity bound —
        // 5K iMac panels encode at native size.
        let maxEncode = (shouldUseProRes4444 || shouldUseHEVC)
            ? (w: 6144.0, h: 3456.0)
            : (w: 3840.0, h: 2160.0)
        let clamp = min(1.0, maxEncode.w / Double(pixelsWide), maxEncode.h / Double(pixelsHigh))
        let captureW = (Int(Double(pixelsWide) * clamp)) & ~1
        let captureH = (Int(Double(pixelsHigh) * clamp)) & ~1
        if clamp < 1.0 {
            Log.info("capture clamped to \(captureW)x\(captureH) (encoder limit; display stays \(pixelsWide)x\(pixelsHigh))")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = captureW
        config.height = captureH
        // Ask for 120 even though the virtual display is 60Hz: requesting
        // exactly 1/60 makes SCK's rate limiter skip frames that arrive a
        // hair early (beat frequency) — measured ~51fps instead of 60.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        // Preserve the desktop at 10-bit 4:4:4 through capture. The HEVC
        // Main10 hardware encoder performs the final 4:2:0 conversion once;
        // the previous 8-bit 4:2:0 capture discarded most chroma samples
        // before encoding and exposed colored noise/banding on flat fills.
        // Keep the hidden BGRA override for diagnostics and use the legacy
        // 420f path for H.264/iOS receivers.
        let pixelFormat: OSType
        if UserDefaults.standard.string(forKey: "pixfmt") == "bgra" {
            pixelFormat = kCVPixelFormatType_32BGRA
        } else if (shouldUseProRes4444 || shouldUseHEVC), quality == .best {
            // Compressed YCbCr defaults to video range. The former xf44
            // full-range input left range propagation dependent on the HEVC
            // encoder and could look washed out in the system display layer.
            pixelFormat = kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        } else {
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        config.pixelFormat = pixelFormat
        // Make the captured desktop's color meaning deterministic. The Mac
        // receiver advertises Display P3 when its active ICC is wide-gamut;
        // old peers and ordinary panels remain in device-independent sRGB.
        // The encoder writes the same negotiated space into its VUI.
        // With the receiver's exact ICC installed on the virtual display,
        // leaving this unset makes ScreenCaptureKit preserve that display
        // profile. Legacy receivers continue using a standard named space.
        if workingICCProfile == nil {
            config.colorSpaceName = workingColorSpace == .displayP3
                ? CGColorSpace.displayP3
                : CGColorSpace.sRGB
        }
        // ScreenCaptureKit only accepts colorMatrix for 420v/420f. The
        // 10-bit 4:4:4 format carries full-resolution chroma and preserves
        // its meaning through the display color space.
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
        // One buffer is held permanently (keyframe replay) and one sits in
        // the encoder for ~13ms — headroom prevents SCK starvation drops.
        config.queueDepth = 8
        config.showsCursor = !localCursor

        setupEncoder(width: captureW, height: captureH,
                     inputPixelFormat: pixelFormat)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        // Set BEFORE capture starts: delegate frames land on `queue` the
        // moment startCapture returns, racing assignments made after it
        // (observed as a distantFuture-based first-frame log line).
        captureStartedAt = Date()
        firstFrameLogged = false
        try await stream.startCapture()
        self.stream = stream
        captureDisplayID = display.displayID
        captureFilter = filter
        captureConfig = config
        lastCursorPNGHash = 0      // rotation rebuilds: re-send the sprite
        lastCursorSent = (-1, -1, false)
        startCursorEcho()
        Log.info("capture started: \(captureW)x\(captureH) display \(display.displayID) "
            + "mode \(mode.rawValue) localCursor=\(localCursor) "
            + "color=\(workingColorSpace.rawValue)")
        let kind = lastHello?.kind ?? "device"
        await status("\(mode == .extend ? "Extending to" : "Mirroring to") \(kind) (\(captureW)×\(captureH))")
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
        cursorConnection?.cancel()
        cursorConnection = nil
        cursorConnectionReady = false
        cursorEndpointKey = ""
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        if let refreshEncoder { VTCompressionSessionInvalidate(refreshEncoder) }
        refreshEncoder = nil
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
            self.cursorConnection?.cancel()
            self.cursorConnection = nil
            self.cursorConnectionReady = false
            self.cursorEndpointKey = ""
            self.pendingSends = 0
            self.pipelineLock.lock()
            self.pendingEncodes = 0
            self.pipelineLock.unlock()
            self.connect()
        }
    }

    // The controller's end() is idempotent, but several detectors (grace,
    // refusals, service withdrawal) can conclude "gone" repeatedly while the
    // stop is in flight — report once so the log tells the story once.
    private var goneReported = false

    /// Declare the device gone and end the session (must be called on `queue`).
    private func reportGone(_ reason: String) {
        guard !goneReported, !stopped else { return }
        goneReported = true
        Log.info(reason)
        Task { @MainActor in self.onDisconnected?() }
    }

    /// A dial was actively refused (must be called on `queue`). On a session
    /// that has streamed before, enough refusals in a row prove the receiver
    /// app is gone — end now instead of waiting out the grace.
    private func dialRefused() {
        guard everConnected, !stopped else { return }
        consecutiveRefusals += 1
        if consecutiveRefusals >= refusalsBeforeGivingUp {
            reportGone("dial refused \(consecutiveRefusals)x — receiver app is gone, ending session")
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
            self.reportGone("service withdrawn and connection down — receiver app is gone, ending session")
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
        case .tcp(let endpoint, let requiredInterface):
            connectTCP(endpoint, requiredInterface: requiredInterface)
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
        remotePointerInsideReceiver = false
        lastReceived = Date()  // fresh grace period for the watchdog
        receiveControl(on: conn)
        // Detect the local interface used for this connection. Thunderbolt
        // bridge interfaces are named "bridge*"; everything else is WiFi/ETH.
        if let path = conn.currentPath {
            let ifaceName = path.availableInterfaces.first?.name ?? ""
            let isBridge = ifaceName.hasPrefix("bridge")
            Task { @MainActor in
                self.onTransportDetected?(isBridge ? "bridge" : "wifi")
            }
            Log.info("connection interface: \(ifaceName) (bridge=\(isBridge))")
        }
        Task { await self.status("Connected to \(self.endpointName)") }
    }

    private func armDialDeadline(_ conn: NWConnection) {
        let generation = dialGeneration
        queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, generation == self.dialGeneration, !self.stopped,
                  self.connection === conn, conn.state != .ready else { return }
            Log.info("dial timed out — redialing")
            conn.cancel()
            self.scheduleReconnect()
        }
    }

    private func connectTCP(_ endpoint: NWEndpoint,
                            requiredInterface: NWInterface?) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true   // latency matters more than throughput here
        let params = NWParameters(tls: nil, tcp: options)
        params.includePeerToPeer = true
        if let requiredInterface {
            params.requiredInterface = requiredInterface
            Log.info("dial constrained to interface \(requiredInterface.name)")
        }
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        armDialDeadline(conn)
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
                // Read the queue-confined flag here (handler runs on queue),
                // not inside the detached status Task.
                let text = self.awaitingWake
                    ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                    : "Waiting for receiver at \(self.endpointName)…"
                Task { await self.status(text) }
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
                queue.async {
                    guard generation == self.dialGeneration, !self.stopped else { return }
                    // Distinct guidance per failure: cable missing vs app
                    // closed. Composed on `queue`: awaitingWake lives there.
                    let hint: String
                    switch error as? Usbmux.Failure {
                    case .noDevice:
                        hint = "Waiting for a USB device — plug in the iPhone or iPad…"
                    case .refused:
                        self.dialRefused()
                        hint = self.awaitingWake
                            ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                            : "Device found — open the OpenDisplay app on it…"
                    default:
                        Log.info("usb dial failed: \(error)")
                        hint = "USB connection failed: \(error.localizedDescription)"
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
                    reportGone("device gone for >\(Int(disconnectGraceSeconds))s — ending session")
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
        cursorConnection?.cancel()
        cursorConnection = nil
        cursorConnectionReady = false
        cursorEndpointKey = ""
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
                // Can't tell a backgrounded receiver from a brief stall here
                // (both go silent while redials still succeed) — hedge.
                Task { await self.status("\(self.endpointName) is silent — keeping the display (app in background or brief stall)") }
                self.scheduleReconnect()
            }
            // The disconnect grace is otherwise only evaluated when a dial
            // changes state — a dial stuck in .preparing (withdrawn Bonjour
            // service) would keep a dead session's display up forever.
            // Enforce it from here too, where the clock always ticks.
            if !self.connectionReady, self.everConnected,
               let since = self.disconnectedSince,
               Date().timeIntervalSince(since) > self.disconnectGraceSeconds {
                self.reportGone("device gone for >\(Int(self.disconnectGraceSeconds))s — ending session")
            }
            // A reconnect on a static screen produces no capture frames, so
            // the receiver would stay black — replay the last frame as IDR.
            if self.connectionReady, self.needsKeyframe,
               Date().timeIntervalSince(self.lastCaptureAt) > 1,
               let pixelBuffer = self.lastPixelBuffer {
                Log.info("static screen after reconnect — replaying last frame as keyframe")
                self.encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
            }
            // No frame has EVER arrived (static virtual display since before
            // capture started) — there is nothing to replay, so seed one.
            if self.connectionReady, self.needsKeyframe, self.stream != nil,
               self.lastPixelBuffer == nil, !self.seedingFirstFrame,
               Date().timeIntervalSince(self.captureStartedAt) > 1 {
                self.seedFirstFrame()
            }
            self.scheduleWatchdog()
        }
    }

    // MARK: - Static-screen refresh (see the property block for rationale)

    private func scheduleStaticRefresh() {
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.stopped else { return }
            self.maybeSendStaticRefresh()
            self.scheduleStaticRefresh()
        }
    }

    /// Must be called on `queue`. Fires at most once per still period, only
    /// while the pipeline is idle, and never within staticRefreshMinInterval
    /// of the previous refresh (a blinking cursor must not loop refreshes).
    private func maybeSendStaticRefresh() {
        guard connectionReady, encoderIsHEVC, staticRefreshEnabled,
              !staticRefreshDone, !refreshInFlight, !needsKeyframe,
              !cursorBlocksStaticRefresh,
              Date().timeIntervalSince(lastCaptureAt) > staticRefreshDelay,
              Date().timeIntervalSince(lastCursorActivityAt) > 0.75,
              Date().timeIntervalSince(lastRefreshAt) > staticRefreshMinInterval,
              let pixelBuffer = lastPixelBuffer,
              pendingSends == 0 else { return }
        pipelineLock.lock()
        let encoderBusy = pendingEncodes > 0
        pipelineLock.unlock()
        guard !encoderBusy else { return }
        sendStaticRefresh(pixelBuffer)
    }

    /// Rearm the expensive still-frame cleanup only after real motion. A
    /// blinking caret or one status redraw is a lone frame every ~500ms and
    /// must not create the former two-second refresh/keyframe loop.
    private func noteCaptureForStaticRefresh(at now: Date) {
        guard staticRefreshDone else {
            refreshMotionBurstFrames = 0
            lastRefreshMotionFrameAt = now
            return
        }
        if now.timeIntervalSince(lastRefreshMotionFrameAt) <= 0.25 {
            refreshMotionBurstFrames += 1
        } else {
            refreshMotionBurstFrames = 1
        }
        lastRefreshMotionFrameAt = now
        if refreshMotionBurstFrames >= 3 {
            staticRefreshDone = false
            refreshMotionBurstFrames = 0
            Log.info("static refresh rearmed after sustained motion")
        }
    }

    /// The refresh session: low-latency rate control, because that is the
    /// only mode where BaseFrameQP is honored — the main session cannot be
    /// low-latency (the mode caps out around 20fps at 4480x2520, and the
    /// main session needs 60). Lazily created; geometry follows setupEncoder.
    private func ensureRefreshEncoder() -> VTCompressionSession? {
        if let refreshEncoder { return refreshEncoder }
        guard !refreshEncoderFailed, encoderWidth > 0, encoderHeight > 0 else { return nil }
        let spec = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue,
        ] as CFDictionary
        let inputAttributes = [
            kCVPixelBufferPixelFormatTypeKey: encoderInputPixelFormat,
        ] as CFDictionary
        var session: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(encoderWidth), height: Int32(encoderHeight),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec,
            imageBufferAttributes: inputAttributes,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        guard let session else {
            // E.g. hardware without a low-latency HEVC engine. The stream
            // stays correct without refreshes — just less pretty when still.
            refreshEncoderFailed = true
            Log.info("static refresh disabled: low-latency HEVC session unavailable")
            return nil
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: encoderInputPixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
                                ? kVTProfileLevel_HEVC_Main10_AutoLevel
                                : kVTProfileLevel_HEVC_Main_AutoLevel)
        if let workingICCProfile {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ICCProfile,
                                 value: workingICCProfile as CFData)
        }
        // Keep the named colour metadata explicit even when an exact ICC is
        // present. VideoToolbox does not reliably serialize ICC into ProRes
        // and otherwise guesses Rec.709 primaries/transfer on decode, which
        // conflicts with the receiver's Display P3 panel profile.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                             value: workingColorSpace == .displayP3
                                ? kCMFormatDescriptionColorPrimaries_P3_D65
                                : kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                             value: kCMFormatDescriptionTransferFunction_sRGB)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                             value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
        refreshEncoder = session
        Log.info("static refresh encoder ready (\(encoderWidth)x\(encoderHeight) QP\(staticRefreshQP))")
        return session
    }

    /// Encode `pixelBuffer` as a fixed-QP IDR on the refresh session and send
    /// it. Must be called on `queue`.
    private func sendStaticRefresh(_ pixelBuffer: CVPixelBuffer) {
        guard let refresher = ensureRefreshEncoder() else { return }
        staticRefreshDone = true
        refreshMotionBurstFrames = 0
        lastRefreshMotionFrameAt = Date.distantPast
        refreshInFlight = true
        lastRefreshAt = Date()
        let stillMark = lastCaptureAt
        let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let qp = staticRefreshQP
        let frameProperties: [CFString: Any] = [
            kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue,
            kVTEncodeFrameOptionKey_BaseFrameQP: qp as CFNumber,
        ]
        let status = VTCompressionSessionEncodeFrame(
            refresher,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            duration: .invalid,
            frameProperties: frameProperties as CFDictionary,
            infoFlagsOut: nil
        ) { [weak self] status, _, buffer in
            guard let self else { return }
            self.queue.async {
                self.refreshInFlight = false
                guard status == noErr, let buffer else {
                    Log.info("static refresh encode failed: \(status)")
                    return
                }
                // A real frame arrived while the refresh encoded — the
                // refresh content is stale now; sending it would step the
                // picture backwards for a frame. The same applies when a
                // pointer entered meanwhile: this large IDR shares TCP with
                // cursor messages, so it must never be allowed to get ahead
                // of an active pointer.
                guard self.lastCaptureAt == stillMark, self.connectionReady else { return }
                guard !self.cursorBlocksStaticRefresh,
                      Date().timeIntervalSince(self.lastCursorActivityAt) > 0.75 else {
                    // Retry once the pointer leaves and the cooldown expires.
                    self.staticRefreshDone = false
                    Log.info("static refresh cancelled: cursor active")
                    return
                }
                guard let data = self.annexB(from: buffer) else { return }
                // The foreign refresh IDR resets the receiver's reference
                // chain. Force the next main-session frame to be an IDR too,
                // but only when the refresh is actually going onto the wire.
                self.resyncMainOnNextFrame = true
                let sndMs = Int64(Date().timeIntervalSince1970 * 1000)
                var framed = Data("{\"cap\":\(capturedAtMs),\"snd\":\(sndMs)}".utf8)
                framed.append(data)
                self.sendFramed(framed)
                Log.info("static refresh sent: \(data.count / 1024)KB QP\(qp)")
            }
        }
        if status != noErr {
            refreshInFlight = false
            Log.info("static refresh submit failed: \(status)")
        }
    }

    /// Grab one screenshot of the captured display and push it through the
    /// normal encode path as the first (key)frame. Runs at most once at a
    /// time; must be called on `queue`.
    private func seedFirstFrame() {
        guard let filter = captureFilter, let config = captureConfig else { return }
        seedingFirstFrame = true
        Log.info("no capture frames since start — seeding one via screenshot")
        Task { [weak self] in
            do {
                let sample = try await SCScreenshotManager.captureSampleBuffer(
                    contentFilter: filter, configuration: config)
                self?.queue.async {
                    guard let self else { return }
                    self.seedingFirstFrame = false
                    guard !self.stopped, self.connectionReady,
                          self.lastPixelBuffer == nil,
                          let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
                    else { return }
                    // Keep it for the reconnect replay too; lastCaptureAt
                    // stays untouched so that replay path can still fire.
                    self.lastPixelBuffer = pixelBuffer
                    self.encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
                }
            } catch {
                self?.queue.async {
                    self?.seedingFirstFrame = false
                    Log.info("screenshot seed failed: \(error)")
                }
            }
        }
    }

    // MARK: - Local cursor echo (Mac -> phone)

    private func startCursorEcho() {
        guard localCursor else { return }
        cursorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Oversample the 60Hz receiver so a busy 4.5K ProRes encode cannot
        // turn one delayed timer firing into a visibly missing pointer step.
        timer.schedule(deadline: .now(), repeating: .milliseconds(4),
                       leeway: .milliseconds(1))   // up to 240Hz
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
        // A Mac receiver renders its own hardware pointer position while the
        // pointer is over the video. Sampling the synthetic CG cursor here
        // would send an older coordinate back and make diagonal movement
        // visibly oscillate. iOS/older receivers do not send this state and
        // continue using the existing sampled echo path.
        // Suppress only the round-trip echo that overlaps fresh receiver-side
        // input. Once that input pauses, a genuinely different coordinate
        // from the sending Mac's physical mouse may take ownership again.
        if remotePointerInsideReceiver,
           Date().timeIntervalSince(lastRemotePointerInputAt) < 0.08 {
            return
        }
        guard connectionReady, captureDisplayID != 0,
              let loc = CGEvent(source: nil)?.location else { return }
        let bounds = CGDisplayBounds(captureDisplayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.contains(loc) {
            let x = (loc.x - bounds.minX) / bounds.width
            let y = (loc.y - bounds.minY) / bounds.height
            if !lastCursorSent.visible {
                armCursorEntryFrameGuard(reason: "cursor became visible")
            }
            if !lastCursorSent.visible
                || abs(x - lastCursorSent.x) > 0.00005 || abs(y - lastCursorSent.y) > 0.00005 {
                lastCursorSent = (x, y, true)
                lastCursorActivityAt = Date()
                cursorSequence &+= 1
                sendCursorFrame(String(format: "{\"type\":\"cursor\",\"x\":%.6f,\"y\":%.6f,\"v\":1,\"s\":%llu}", x, y, cursorSequence))
            }
        } else if lastCursorSent.visible {
            lastCursorSent.visible = false
            lastCursorActivityAt = Date()
            cursorSequence &+= 1
            sendCursorFrame("{\"type\":\"cursor\",\"v\":0,\"s\":\(cursorSequence)}")
        }
    }

    private func armCursorEntryFrameGuard(reason: String) {
        let now = Date()
        let wasInactive = now > suppressCursorEntryBlackFramesUntil

        suppressCursorEntryBlackFramesUntil = now.addingTimeInterval(0.40)
        if wasInactive {
            Log.info("cursor-entry capture guard armed: \(reason)")
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
            handleUnparseableControlLogAction(
                unparseableControlLogPolicy.record(
                    payload.count,
                    at: ProcessInfo.processInfo.systemUptime
                )
            )
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
                configureCursorChannel(info)
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
                          || previous.pixelsHigh != info.pixelsHigh
                          || previous.colorSpace != info.colorSpace
                          || previous.iccProfile != info.iccProfile {
                    // Rotation or target-profile change — rebuild after a
                    // short debounce so a flurry of changes settles into one.
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard let current = self.lastHello,
                              current.pixelsWide == info.pixelsWide,
                              current.pixelsHigh == info.pixelsHigh,
                              current.colorSpace == info.colorSpace,
                              current.iccProfile == info.iccProfile else { return }
                        await self.reconfigure(info)
                    }
                }
            }
        case "touch":
            if let phase = obj["phase"] as? String,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                if phase == "moved" || phase == "began" {
                    let now = Date()
                    lastCursorActivityAt = now
                    let idle = now.timeIntervalSince(lastRemotePointerInputAt)
                    let edgeDistance = min(x, 1 - x, y, 1 - y)
                    // Re-entering the receiver video begins at one of its
                    // edges. Requiring both an input gap and an edge position
                    // avoids adding a hold after an ordinary pause in the
                    // middle of the remote desktop.
                    if !remotePointerInsideReceiver,
                       idle > 0.35, edgeDistance <= 0.045 {
                        armCursorEntryFrameGuard(
                            reason: String(format: "remote pointer resumed after %.0fms", idle * 1000))
                    }
                    lastRemotePointerInputAt = now
                    // Track the injected position without echoing it back.
                    // After receiver input pauses, polling sees the same point
                    // and stays quiet; only a different physical-sender point
                    // is sent, which cleanly transfers cursor ownership.
                    if remotePointerInsideReceiver {
                        lastCursorSent = (x, y, true)
                    }
                }
                inputInjector?.handleTouch(phase: phase, x: x, y: y)
                if let t = obj["t"] as? Double {
                    let delta = Date().timeIntervalSince1970 * 1000 - t
                    if delta > -50, delta < 1000 {
                        inputLatencies.append(max(delta, 0))
                        if inputLatencies.count > 240 { inputLatencies.removeFirst(120) }
                    }
                }
            }
        case "pointerPresence":
            if let inside = obj["inside"] as? Bool {
                remotePointerInsideReceiver = inside
                lastCursorActivityAt = Date()
                if inside {
                    armCursorEntryFrameGuard(reason: "receiver pointer entered")
                } else if lastCursorSent.visible {
                    lastCursorSent.visible = false
                    sendJSONFrame("{\"type\":\"cursor\",\"v\":0}")
                }
            }
        case "scroll":
            if let dx = obj["dx"] as? Double, let dy = obj["dy"] as? Double {
                lastCursorActivityAt = Date()
                inputInjector?.handleScroll(dx: dx, dy: dy)
            }
        case "pencil":
            if let phase = obj["phase"] as? String,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                inputInjector?.handlePencil(
                    phase: phase, x: x, y: y,
                    pressure: obj["pressure"] as? Double ?? 0,
                    azimuth: obj["azimuth"] as? Double ?? 0,
                    altitude: obj["altitude"] as? Double ?? (.pi / 2),
                    rotation: obj["rotation"] as? Double ?? 0)
                if let t = obj["t"] as? Double {
                    let delta = Date().timeIntervalSince1970 * 1000 - t
                    if delta > -50, delta < 1000 {
                        inputLatencies.append(max(delta, 0))
                        if inputLatencies.count > 240 { inputLatencies.removeFirst(120) }
                    }
                }
            }
        case "proximity":
            if let entering = obj["entering"] as? Bool,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                inputInjector?.handleProximity(entering: entering, x: x, y: y)
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
            // Unknown types are a normal consequence of the additive wire
            // protocol: a newer peer can send messages this build predates.
            // Log each type once per session, never per message. A peer can
            // drive this at input rates (a pencil stroke is ~240 messages/sec),
            // so the policy also caps distinct types and reports that cap once.
            switch unknownTypeLogPolicy.record(type) {
            case .logType(let type):
                Log.info("unknown control message type: \(type) — ignoring (logged once)")
            case .logSuppression(let limit):
                Log.info("additional unknown control message types suppressed after \(limit) distinct types")
            case .none:
                break
            }
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

    private func setupEncoder(width: Int, height: Int,
                              inputPixelFormat: OSType) {
        // ProRes 4444 is the paired-Mac fidelity experiment. It preserves
        // 10-bit 4:4:4 and makes every frame independently decodable. If the
        // hardware session is unavailable, fall through to the established
        // HEVC/H.264 path so mixed-version installs remain usable.
        let wantProRes4444 = shouldUseProRes4444
        let wantProRes4444XQ = shouldUseProRes4444XQ
        // HEVC when the receiver offered it in its hello (Mac receivers):
        // better quality per bit, and the hardware encoder sustains 60fps at
        // sizes where the H.264 engine falls over. iOS receivers don't send
        // the offer and stay on H.264. Falls back if session creation fails
        // (e.g. an older Intel machine without an HEVC encoder) — the
        // receiver auto-detects the codec from the bitstream either way.
        let wantHEVC = shouldUseHEVC
        if (lastHello?.prores4444 ?? false), !wantProRes4444 {
            Log.info("ProRes 4444 offer overridden — using HEVC/H.264")
        }
        if (lastHello?.hevc ?? false), !wantHEVC {
            Log.info("HEVC offer overridden — using H.264")
        }
        // Apple's low-latency HEVC rate controller is excellent below 4K,
        // but throttles a 4480x2520 stream to ~19fps. Let VideoToolbox use its
        // normal hardware pipeline above 4K (measured 47–48fps with 3 slots).
        // Keep the hidden override for diagnostics.
        let pixels = width * height
        let accurate10Bit = (wantProRes4444 || wantHEVC)
            && inputPixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        let lowLatency = UserDefaults.standard.object(forKey: "lowlatency") != nil
            ? UserDefaults.standard.bool(forKey: "lowlatency")
            : !(wantHEVC && pixels > 3840 * 2160) && !wantProRes4444
        // Native Mac-receiver best quality is the fidelity path. BaseFrameQP
        // is only honored by VideoToolbox's low-latency controller; the 4.5K
        // path uses normal rate control for throughput, so constrain it with
        // MaxAllowedFrameQP instead of logging a fixed QP that is ignored.
        let nativeFidelity = accurate10Bit && quality == .best
        // Asking the hardware encoder to spend extra time on mode decisions
        // works well through 4K, but measured ~68ms/frame and ~20fps at the
        // iMac's 4480x2520. At 4.5K, retain the real-time search path and get
        // fidelity from the tighter QP ceiling, larger bit budget and QP-8
        // idle refresh instead.
        let qualityFirstEncoder = nativeFidelity && pixels <= 3840 * 2160
        fixedDesktopQP = !wantProRes4444 && nativeFidelity && lowLatency ? 12 : nil
        let maxFrameQP = nativeFidelity ? 16 : 20
        var proResCodecType = wantProRes4444XQ
            ? kCMVideoCodecType_AppleProRes4444XQ
            : kCMVideoCodecType_AppleProRes4444
        let proResEncoderID = wantProRes4444XQ
            ? "com.apple.videotoolbox.videoencoder.appleproreshw.4444xq"
            : "com.apple.videotoolbox.videoencoder.appleproreshw.4444"
        let spec: CFDictionary? = wantProRes4444
            ? [kVTVideoEncoderSpecification_EncoderID:
                proResEncoderID as CFString] as CFDictionary
            : (lowLatency
                ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
                : nil)
        var usingProRes4444 = wantProRes4444
        var usingProRes4444XQ = wantProRes4444XQ
        var usingHEVC = !wantProRes4444 && wantHEVC
        let inputAttributes = [
            kCVPixelBufferPixelFormatTypeKey: inputPixelFormat,
        ] as CFDictionary
        VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width), height: Int32(height),
            codecType: wantProRes4444
                ? proResCodecType
                : (wantHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264),
            encoderSpecification: spec,
            imageBufferAttributes: inputAttributes,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder
        )
        if encoder == nil, wantProRes4444XQ {
            Log.info("hardware ProRes 4444 XQ session creation failed — falling back to hardware 4444")
            proResCodecType = kCMVideoCodecType_AppleProRes4444
            usingProRes4444XQ = false
            let fallbackSpec = [kVTVideoEncoderSpecification_EncoderID:
                "com.apple.videotoolbox.videoencoder.appleproreshw.4444" as CFString] as CFDictionary
            VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width), height: Int32(height),
                codecType: proResCodecType,
                encoderSpecification: fallbackSpec,
                imageBufferAttributes: inputAttributes,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &encoder
            )
        }
        if encoder == nil, wantProRes4444 {
            Log.info("hardware ProRes session creation failed — trying generic ProRes 4444")
            proResCodecType = kCMVideoCodecType_AppleProRes4444
            usingProRes4444XQ = false
            VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_AppleProRes4444,
                encoderSpecification: nil,
                imageBufferAttributes: inputAttributes,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &encoder
            )
        }
        if encoder == nil, wantProRes4444 {
            Log.info("ProRes 4444 session creation failed — falling back to HEVC")
            usingProRes4444 = false
            usingProRes4444XQ = false
            usingHEVC = wantHEVC
            let fallbackSpec: CFDictionary? = lowLatency
                ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
                : nil
            VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width), height: Int32(height),
                codecType: wantHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                encoderSpecification: fallbackSpec,
                imageBufferAttributes: inputAttributes,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &encoder
            )
        }
        if encoder == nil, wantHEVC {
            Log.info("HEVC session creation failed — falling back to H.264")
            usingProRes4444 = false
            usingProRes4444XQ = false
            usingHEVC = false
            VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: inputAttributes,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &encoder
            )
        }
        guard let encoder else {
            Log.info("FATAL: VTCompressionSessionCreate failed")
            return
        }
        // Real-time, no B-frames. ProRes is intra-only; inter-frame controls
        // and rate-control/QP properties below are only meaningful to HEVC/H.264.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        if !usingProRes4444 {
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: usingHEVC
                                    ? (accurate10Bit
                                        ? kVTProfileLevel_HEVC_Main10_AutoLevel
                                        : kVTProfileLevel_HEVC_Main_AutoLevel)
                                    : kVTProfileLevel_H264_High_AutoLevel)
        }
        if let workingICCProfile {
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ICCProfile,
                                 value: workingICCProfile as CFData)
        }
        // ICC and named metadata are complementary here. In particular,
        // Apple's ProRes encoder accepts ICC but does not put it in the
        // compressed format description; explicit P3/sRGB prevents the
        // decoder from guessing a contradictory Rec.709 colour space.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ColorPrimaries,
                             value: workingColorSpace == .displayP3
                                ? kCMFormatDescriptionColorPrimaries_P3_D65
                                : kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_TransferFunction,
                             value: kCMFormatDescriptionTransferFunction_sRGB)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_YCbCrMatrix,
                             value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
        if !usingProRes4444 {
            // No periodic IDRs: each one is a bitrate spike → transmit-time hiccup.
            // TCP never loses data, and we force a keyframe on reconnect/drop.
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        // Preset bitrates were tuned on iPad-class panels (~5.6MP). Scale
        // with the actual encode size so 4K Mac receivers aren't starved —
        // 18Mbps at 3840x2160 visibly blurs text. Capped for sanity; WiFi
        // users pick a lower quality preset, same as before.
        let referencePixels = 2732.0 * 2048.0
        let ratio = max(1.0, Double(width * height) / referencePixels)
        let bitrateScale = nativeFidelity ? 4.0 : (accurate10Bit ? 3.0 : 1.5)
        let bitrateCap = nativeFidelity ? 180_000_000
            : (accurate10Bit ? 120_000_000 : 60_000_000)
        let bitrate = min(Int(Double(quality.bitrate) * ratio * bitrateScale),
                          bitrateCap)
        // HEVC benefits from two in-flight frames at smaller sizes. Native
        // 4480x2520 reaches its best throughput with three: 47–48fps versus
        // 41–44 with two; four adds ~20ms without increasing throughput.
        // Beyond iPad-class sizes H.264 also needs a second slot.
        // `defaults write <bundle-id> encodeSlots -int N` overrides (1-6):
        // deeper pipelines trade ~16ms queue latency per slot for throughput
        // on encoders with internal parallel stages. 0/absent = automatic.
        let slotsOverride = UserDefaults.standard.integer(forKey: "encodeSlots")
        pipelineLock.lock()
        maxPendingEncodes = slotsOverride > 0
            ? min(slotsOverride, 6)
            : (usingProRes4444
                ? 6
                : (usingHEVC
                ? (pixels > 3840 * 2160 ? 3 : 2)
                : (Double(pixels) > referencePixels ? 2 : 1)))
        pipelineLock.unlock()
        if slotsOverride > 0 {
            Log.info("encode pipeline depth overridden: \(min(slotsOverride, 6)) slots")
        }
        if !usingProRes4444 {
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        // Extra quality search is too slow at 4.5K. Through 4K the native
        // preset can use it; above 4K the lower maximum QP and larger bit
        // budget preserve detail while the encoder remains real-time.
        VTSessionSetProperty(
            encoder,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: qualityFirstEncoder ? kCFBooleanFalse : kCFBooleanTrue)
        if accurate10Bit && !usingProRes4444 {
            // Prevent the rate controller from turning smooth desktop fills
            // into coarse, differently quantized coding blocks. Native
            // fidelity uses 16; lower presets retain the previous ceiling.
            VTSessionSetProperty(encoder,
                                 key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                                 value: maxFrameQP as CFNumber)
            VTSessionSetProperty(encoder,
                                 key: kVTCompressionPropertyKey_Quality,
                                 value: (nativeFidelity ? 0.95 : 0.9) as CFNumber)
            if #available(macOS 15.0, *), !lowLatency {
                VTSessionSetProperty(
                    encoder,
                    key: kVTCompressionPropertyKey_SpatialAdaptiveQPLevel,
                    value: 0 as CFNumber)
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(encoder)
        // The static-refresh session must match the main session's geometry;
        // recreate it lazily after any (re)configuration.
        encoderIsHEVC = usingHEVC
        encoderIsProRes4444 = usingProRes4444
        encoderIsProRes4444XQ = usingProRes4444XQ
        encoderWidth = width
        encoderHeight = height
        encoderInputPixelFormat = inputPixelFormat
        if let refreshEncoder { VTCompressionSessionInvalidate(refreshEncoder) }
        refreshEncoder = nil
        refreshEncoderFailed = false
        let qpMode = fixedDesktopQP != nil ? "fixedQP12" : "maxQP\(maxFrameQP)"
        let colorMode = (usingProRes4444
            ? "10-bit 4:4:4 intra"
            : accurate10Bit
            ? "Main10 x444-video \(qpMode) \(qualityFirstEncoder ? "quality-search" : "realtime-search")"
            : "8-bit")
            + " \(workingColorSpace.rawValue) ICC=\(workingICCProfile?.count ?? 0)B"
        let codecName = usingProRes4444XQ
            ? "ProRes 4444 XQ"
            : (usingProRes4444 ? "ProRes 4444" : (usingHEVC ? "HEVC" : "H.264"))
        let rateDescription = usingProRes4444 ? "intra VBR" : "\(bitrate / 1_000_000)Mbps"
        Log.info("encoder ready: \(width)x\(height) \(codecName) \(rateDescription) \(colorMode) quality=\(quality.rawValue) lowLatencyRC=\(lowLatency) staticRefresh=\(usingHEVC && staticRefreshEnabled)")
    }

    // MARK: - Capture callback

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        // Blank/suspended/idle status buffers contain no new display image.
        // Encoding them can replace the receiver's last good frame with a
        // transient black one, so only complete/started frames are eligible.
        if let status = frameStatus(of: sampleBuffer),
           status != .complete, status != .started {
            return
        }

        if !firstFrameLogged {
            firstFrameLogged = true
            Log.info(String(format: "first capture frame %.0fms after capture start",
                            Date().timeIntervalSince(captureStartedAt) * 1000))
        }
        let capturedAt = Date()
        noteCaptureForStaticRefresh(at: capturedAt)
        lastCaptureAt = capturedAt
        capFrames += 1

        // Some macOS versions label the cursor-entry glitch as a complete
        // frame. Reject only a truly frame-wide black buffer; withholding all
        // frames makes the receiver's video layer itself clear to black.
        // Requiring an existing good frame also keeps startup safe.
        let capturedNow = Date()
        // The capture callback can beat the 120Hz cursor timer when the
        // sending Mac's physical mouse enters the virtual display. Detect
        // that transition here as well so the very first suspect frame is
        // held instead of waiting up to 8ms for pollCursorPosition().
        if lastPixelBuffer != nil,
           !lastCursorSent.visible,
           isCursorCurrentlyOnCaptureDisplay() {
            armCursorEntryFrameGuard(reason: "capture observed cursor entry")
        }
        if lastPixelBuffer != nil,
           capturedNow <= suppressCursorEntryBlackFramesUntil,
            isNearlyBlackFrame(pixelBuffer) {
            Log.info("suppressed transient black capture frame on cursor entry")
            return
        }
        lastPixelBuffer = pixelBuffer

        // No receiver, or a pipeline stage is backed up: skip this frame.
        guard connectionReady else { return }
        if shouldDropFrame(reason: "pending_encode") { return }  // encoder busy
        if shouldDropFrame(reason: "pending_sends") { return }   // TCP send queue full

        encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// ScreenCaptureKit's per-frame status attachment. Missing status remains
    /// eligible for compatibility with older systems/alternate producers.
    private func frameStatus(of sample: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    private func isCursorCurrentlyOnCaptureDisplay() -> Bool {
        guard captureDisplayID != 0,
              let location = CGEvent(source: nil)?.location else { return false }
        return CGDisplayBounds(captureDisplayID).contains(location)
    }

    /// Fast whole-frame black check for both capture formats supported by
    /// startCapture (BGRA and bi-planar YUV). This only runs for ~250 ms on
    /// cursor entry, not on every frame.
    private func isNearlyBlackFrame(_ buf: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(buf, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        guard w > 0, h > 0 else { return false }

        let format = CVPixelBufferGetPixelFormatType(buf)
        let samplesPerAxis = 5
        var darkCount = 0
        let total = samplesPerAxis * samplesPerAxis

        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(buf) else { return false }
            let stride = CVPixelBufferGetBytesPerRow(buf)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<samplesPerAxis {
                for col in 0..<samplesPerAxis {
                    let x = (col + 1) * w / (samplesPerAxis + 1)
                    let y = (row + 1) * h / (samplesPerAxis + 1)
                    let offset = y * stride + x * 4
                    if ptr[offset] <= 4, ptr[offset + 1] <= 4, ptr[offset + 2] <= 4 {
                        darkCount += 1
                    }
                }
            }

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard CVPixelBufferGetPlaneCount(buf) > 0,
                  let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0) else { return false }
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
            let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
            // Video-range black is Y=16; full-range black is Y=0.
            let threshold: UInt8 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 20 : 4
            for row in 0..<samplesPerAxis {
                for col in 0..<samplesPerAxis {
                    let x = (col + 1) * w / (samplesPerAxis + 1)
                    let y = (row + 1) * h / (samplesPerAxis + 1)
                    if yPtr[y * yStride + x] <= threshold { darkCount += 1 }
                }
            }

        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            guard CVPixelBufferGetPlaneCount(buf) > 0,
                  let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0) else { return false }
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0) / 2
            let yPtr = yBase.assumingMemoryBound(to: UInt16.self)
            // 10 useful bits live in the MSBs of each UInt16. Allow code
            // values 0...4, matching the 8-bit full-range black threshold.
            let threshold = UInt16(4 << 6)
            for row in 0..<samplesPerAxis {
                for col in 0..<samplesPerAxis {
                    let x = (col + 1) * w / (samplesPerAxis + 1)
                    let y = (row + 1) * h / (samplesPerAxis + 1)
                    if yPtr[y * yStride + x] <= threshold { darkCount += 1 }
                }
            }

        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
            guard CVPixelBufferGetPlaneCount(buf) > 0,
                  let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0) else { return false }
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0) / 2
            let yPtr = yBase.assumingMemoryBound(to: UInt16.self)
            // Video-range 10-bit black is code value 64, stored in the most
            // significant ten bits. Allow a small capture tolerance.
            let threshold = UInt16(68 << 6)
            for row in 0..<samplesPerAxis {
                for col in 0..<samplesPerAxis {
                    let x = (col + 1) * w / (samplesPerAxis + 1)
                    let y = (row + 1) * h / (samplesPerAxis + 1)
                    if yPtr[y * yStride + x] <= threshold { darkCount += 1 }
                }
            }

        default:
            return false
        }

        return darkCount >= total - 2
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
            // While a pointer owns the receiver, keep at most one video frame
            // in TCP. Cursor JSON then waits behind one frame at worst instead
            // of a three-frame video burst. Latest-wins capture dropping keeps
            // latency bounded and recovers immediately when the pointer leaves.
            let sendLimit = cursorOwnsReceiver ? 1 : maxPendingSends
            drop = pendingSends >= sendLimit
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
        var properties: [CFString: Any] = [:]
        if encoderIsProRes4444 {
            // Every ProRes frame is independently decodable. Clear the
            // reconnect flags on the first submitted frame so the watchdog
            // does not keep replaying a static frame as a fictitious IDR.
            needsKeyframe = false
            resyncMainOnNextFrame = false
        } else if needsKeyframe || resyncMainOnNextFrame {
            // resyncMainOnNextFrame: the receiver last displayed a refresh
            // IDR the main session never encoded — its reference chain is
            // foreign, so this frame must be an IDR too.
            properties[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue
            needsKeyframe = false
            resyncMainOnNextFrame = false
        }
        if let fixedDesktopQP {
            // BaseFrameQP disables normal rate control for this frame. It is
            // intentionally supplied on every frame, as required by VT, so
            // smooth fills cannot silently fall back to coarse VBR blocks.
            properties[kVTEncodeFrameOptionKey_BaseFrameQP] = fixedDesktopQP as CFNumber
        }
        let frameProperties = properties.isEmpty ? nil : properties as CFDictionary
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
            guard status == noErr, let buffer else {
                // A session rejecting every frame looks healthy in all other
                // counters — the receiver just stays black. Don't be silent.
                self.pipelineLock.lock()
                let logAction = self.encodeOutputFailureLogPolicy.record(
                    status,
                    at: ProcessInfo.processInfo.systemUptime
                )
                self.pipelineLock.unlock()
                self.handleEncodeOutputFailureLogAction(logAction)
                return
            }
            let sndMs = Int64(Date().timeIntervalSince1970 * 1000)
            if self.encoderIsProRes4444,
               let data = self.sampleData(from: buffer) {
                let wireCodec = self.encoderIsProRes4444XQ
                    ? "prores4444xq" : "prores4444"
                var framed = Data("{\"cap\":\(capturedAtMs),\"snd\":\(sndMs),\"codec\":\"\(wireCodec)\",\"w\":\(self.encoderWidth),\"h\":\(self.encoderHeight)}\n".utf8)
                framed.append(data)
                self.sendFramed(framed)
            } else if let data = self.annexB(from: buffer) {
                var framed = Data("{\"cap\":\(capturedAtMs),\"snd\":\(sndMs)}".utf8)
                framed.append(data)
                self.sendFramed(framed)
            }
        }
        if submitStatus != noErr {
            pipelineLock.lock()
            pendingEncodes = max(0, pendingEncodes - 1)
            // A dead encoder session keeps failing, and this runs per frame, so
            // an unthrottled line here is ~60/sec for as long as the problem
            // lasts. Report at most once a second and carry the count: the
            // status code is the diagnosis, the rate is just a number.
            let logAction = encodeFailureLogPolicy.record(
                submitStatus,
                at: ProcessInfo.processInfo.systemUptime
            )
            pipelineLock.unlock()
            handleEncodeFailureLogAction(logAction)
        }
    }

    private func handleEncodeFailureLogAction(_ action: ThrottledLogPolicy<OSStatus>.Action) {
        switch action {
        case .report(let report):
            reportEncodeFailures(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushEncodeFailureLog()
            }
        case .none:
            break
        }
    }

    private func flushEncodeFailureLog() {
        pipelineLock.lock()
        let report = encodeFailureLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime)
        pipelineLock.unlock()
        if let report { reportEncodeFailures(report) }
    }

    private func reportEncodeFailures(_ report: ThrottledLogPolicy<OSStatus>.Report) {
        Log.info("VTCompressionSessionEncodeFrame failed: \(report.detail) (\(report.count) since last report)")
    }

    private func handleEncodeOutputFailureLogAction(_ action: ThrottledLogPolicy<OSStatus>.Action) {
        switch action {
        case .report(let report):
            reportEncodeOutputFailures(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushEncodeOutputFailureLog()
            }
        case .none:
            break
        }
    }

    private func flushEncodeOutputFailureLog() {
        pipelineLock.lock()
        let report = encodeOutputFailureLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime)
        pipelineLock.unlock()
        if let report { reportEncodeOutputFailures(report) }
    }

    private func reportEncodeOutputFailures(_ report: ThrottledLogPolicy<OSStatus>.Report) {
        // VideoToolbox can reject a frame with noErr + a nil buffer (e.g.
        // above the H.264 level pixel-rate ceiling) — call that case out.
        let cause = report.detail == noErr ? "nil buffer despite noErr" : "status \(report.detail)"
        Log.info("encoder output rejected: \(cause) (\(report.count) since last report)")
    }

    // Runs on `queue`, where the policy and the control connection both live.
    private func handleUnparseableControlLogAction(_ action: ThrottledLogPolicy<Int>.Action) {
        switch action {
        case .report(let report):
            reportUnparseableControl(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushUnparseableControlLog()
            }
        case .none:
            break
        }
    }

    private func flushUnparseableControlLog() {
        if let report = unparseableControlLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime) {
            reportUnparseableControl(report)
        }
    }

    private func reportUnparseableControl(_ report: ThrottledLogPolicy<Int>.Report) {
        Log.info("unparseable control message (\(report.detail) bytes, \(report.count) since last report)")
    }

    /// Copy a self-contained compressed sample (used by ProRes). Unlike the
    /// Annex-B codecs, ProRes has no out-of-band parameter sets or NAL framing.
    private func sampleData(from sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let total = CMBlockBufferGetDataLength(block)
        guard total > 0 else { return nil }
        var data = Data(count: total)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total,
                                       destination: bytes.baseAddress!)
        }
        return status == noErr ? data : nil
    }

    // MARK: - H.264 / HEVC -> Annex B

    private func annexB(from sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &len, totalLengthOut: &total,
                dataPointerOut: &ptr) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 256)
        // On keyframes, prepend the parameter sets (they live in the format
        // description). Query the REAL count instead of assuming 3 (HEVC) or
        // 2 (H.264): the low-latency static-refresh session emits 1 VPS +
        // 1 SPS + FOUR PPS entries whose ids its slices reference — with the
        // count hardcoded to 3, PPS 1-3 never reached the receiver and every
        // refresh IDR failed decode (-12909), looping keyframe requests.
        if isKeyframe(sample), let fmt = CMSampleBufferGetFormatDescription(sample) {
            let isHEVC = CMFormatDescriptionGetMediaSubType(fmt) == kCMVideoCodecType_HEVC
            var psCount = 0
            let countStatus = isHEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: 0,
                    parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                    parameterSetCountOut: &psCount, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: 0,
                    parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                    parameterSetCountOut: &psCount, nalUnitHeaderLengthOut: nil)
            if countStatus != noErr { psCount = isHEVC ? 3 : 2 }
            for i in 0..<psCount {
                var psPtr: UnsafePointer<UInt8>?
                var psLen = 0
                let status = isHEVC
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if status == noErr, let psPtr {
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

    private func configureCursorChannel(_ info: PhoneInfo) {
        guard let host = info.cursorHost,
              let rawPort = info.cursorPort,
              (1...65535).contains(rawPort),
              let port = NWEndpoint.Port(rawValue: UInt16(rawPort)) else {
            cursorConnection?.cancel()
            cursorConnection = nil
            cursorConnectionReady = false
            cursorEndpointKey = ""
            return
        }
        let key = "\(host):\(rawPort)"
        guard key != cursorEndpointKey || cursorConnection?.state != .ready else { return }
        cursorConnection?.cancel()
        cursorConnectionReady = false
        cursorEndpointKey = key
        let params = NWParameters.udp
        params.includePeerToPeer = true
        params.serviceClass = .responsiveData
        if let requiredInterface = connection?.currentPath?.availableInterfaces.first {
            params.requiredInterface = requiredInterface
        }
        let conn = NWConnection(
            host: NWEndpoint.Host(host), port: port, using: params)
        cursorConnection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, self.cursorConnection === conn else { return }
            switch state {
            case .ready:
                self.cursorConnectionReady = true
                Log.info("cursor UDP channel ready: \(key)")
            case .failed(let error):
                self.cursorConnectionReady = false
                Log.info("cursor UDP channel failed: \(error) — using TCP fallback")
            case .cancelled:
                self.cursorConnectionReady = false
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func sendCursorFrame(_ json: String) {
        if let cursorConnection, cursorConnectionReady {
            cursorConnection.send(content: Data(json.utf8),
                                  completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.cursorConnectionReady = false
                    Log.info("cursor UDP send failed: \(error) — using TCP fallback")
                }
            })
        } else {
            sendJSONFrame(json)
        }
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
