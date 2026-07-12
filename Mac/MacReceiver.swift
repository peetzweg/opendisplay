// Receiver mode (issues #82/#17): this Mac listens exactly like the iPhone
// does — Bonjour-advertised TCP listener, hello with its own panel size — and
// renders the incoming stream, so a spare Mac becomes a display for another
// Mac. The pipeline is the shared StreamReceiver core; this file is only the
// AppKit shell around it: lifecycle, the video window, cursor drawing, and
// keeping the machine awake while it serves as a screen.
//
// Display-only for now: the receiving Mac's keyboard/trackpad are not
// forwarded to the sender (KVM-style input is a follow-up).

import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class ReceiverController: ObservableObject {
    static let shared = ReceiverController()

    // A fresh StreamReceiver per activation: stop() tears the old one down
    // and drops it, so listener/decoder state can't leak across mode flips.
    // Nil whenever receiver mode is off.
    @Published private(set) var receiver: StreamReceiver?
    // Summaries for views that don't observe the receiver itself (menu bar
    // icon, status bar): a sender is connected / frames are on screen.
    @Published private(set) var connected = false
    @Published private(set) var streaming = false

    var active: Bool { receiver != nil }

    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var sleepActivity: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    private var fallbackName: String { Host.current().localizedName ?? "Mac" }

    func start() {
        guard receiver == nil else { return }
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                      deviceKind: "Mac",
                                      fallbackServiceName: fallbackName)
        let saved = UserDefaults.standard.string(forKey: "receiverName")
        receiver.serviceName = (saved?.isEmpty == false) ? saved! : fallbackName
        announcePanel(to: receiver)
        self.receiver = receiver
        receiver.start(port: 9000)

        receiver.$connected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.connected = connected
                self?.updateSleepAssertion(connected)
            }
            .store(in: &cancellables)
        // Streaming = connected and the video format is known — that's when
        // the window has something to show (and when to take it down again).
        receiver.$connected.combineLatest(receiver.$videoSize)
            .map { $0 && $1 != .zero }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] streaming in
                self?.streaming = streaming
                if streaming { self?.showWindow() } else { self?.closeWindow() }
            }
            .store(in: &cancellables)

        // Display-mode changes move the goalposts mid-session (the announced
        // panel is the sender's virtual-display size) — re-announce, the
        // sender rebuilds. The Mac analogue of iPhone rotation.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let receiver = self.receiver else { return }
                self.announcePanel(to: receiver)
            }
        }
        Log.info("receiver mode started (advertising \"\(receiver.serviceName)\")")
    }

    func stop() {
        guard let receiver else { return }
        cancellables.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        receiver.stop()
        self.receiver = nil
        connected = false
        streaming = false
        closeWindow()
        updateSleepAssertion(false)
        Log.info("receiver mode stopped")
    }

    /// Re-published name from the panel's text field. Empty falls back to the
    /// computer name (mirrors the iOS Settings behavior).
    func setAdvertisedName(_ name: String) {
        UserDefaults.standard.set(name, forKey: "receiverName")
        receiver?.setServiceName(name)
    }

    /// The panel this Mac offers as a display: the primary screen's current
    /// framebuffer. A Retina panel announces its @2x pixels, which maps 1:1
    /// onto the sender's @2x HiDPI virtual display.
    ///
    /// Minus the menu-bar/notch strip: native full screen never covers it on
    /// notched panels (the fullscreen window is the screen shrunk by
    /// safeAreaInsets.top — zero on notch-less displays). Announcing the
    /// full panel would letterbox full screen on every side AND render the
    /// remote menu bar physically behind the notch; announcing the safe
    /// rect makes full screen exactly 1:1.
    private func announcePanel(to receiver: StreamReceiver) {
        guard let screen = NSScreen.screens.first else { return }
        let scale = screen.backingScaleFactor
        let height = screen.frame.height - screen.safeAreaInsets.top
        receiver.setPanel(pixelsWide: Int(screen.frame.width * scale),
                          pixelsHigh: Int(height * scale),
                          scale: Double(scale))
    }

    // MARK: - Video window

    /// Bring the video window (back) up — also bound to the panel button for
    /// when the user closed the window while the stream keeps running.
    func showWindow() {
        guard let receiver, streaming || window != nil else { return }
        if window == nil {
            let w = NSWindow(contentRect: initialContentRect(video: receiver.videoSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "OpenDisplay"
            w.contentView = ReceiverVideoView(receiver: receiver)
            w.isReleasedWhenClosed = false
            w.collectionBehavior.insert(.fullScreenPrimary)
            w.center()
            window = w
        }
        // Resizes keep the stream's shape; re-set on every show because a
        // reconnect can arrive with new dimensions in the same window.
        if receiver.videoSize != .zero { window?.contentAspectRatio = receiver.videoSize }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWindow() {
        window?.close()
        window = nil
    }

    /// Windowed at ~70% of the screen to start — the green button (native
    /// full screen) is the "use the whole panel" gesture.
    private func initialContentRect(video: CGSize) -> NSRect {
        let visible = NSScreen.screens.first?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
        let size = video == .zero ? CGSize(width: 960, height: 600) : video
        let scale = min(0.7 * visible.width / size.width,
                        0.7 * visible.height / size.height, 1)
        return NSRect(x: 0, y: 0,
                      width: size.width * scale, height: size.height * scale)
    }

    // MARK: - Stay awake

    /// This Mac *is* the display while a sender streams — never let it doze.
    private func updateSleepAssertion(_ receiving: Bool) {
        if receiving, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "OpenDisplay is receiving a display stream")
        } else if !receiving, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
}

// MARK: - Video view (AppKit sibling of the iOS VideoLayerView)

/// NSView hosting the AVSampleBufferDisplayLayer plus the local cursor-echo
/// layer. The sender hides the real cursor from capture and streams its
/// position/sprite on the control channel — without drawing it here the
/// extended desktop would have no visible pointer.
final class ReceiverVideoView: NSView {
    private weak var receiver: StreamReceiver?
    private let displayLayer: AVSampleBufferDisplayLayer
    private var videoSizeObserver: AnyCancellable?

    private let cursorLayer: CALayer = {
        let layer = CALayer()
        layer.isHidden = true
        layer.zPosition = 10
        // Position updates arrive at 120Hz — implicit animations would
        // smear the cursor behind every move.
        layer.actions = ["position": NSNull(), "contents": NSNull(),
                         "bounds": NSNull(), "hidden": NSNull()]
        return layer
    }()
    private var cursorNormSize = CGSize.zero
    private var cursorNorm = CGPoint(x: 0.5, y: 0.5)
    private var cursorVisible = false

    init(receiver: StreamReceiver) {
        self.receiver = receiver
        self.displayLayer = receiver.displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // AVSBDL aspect-fits internally (videoGravity) — give it full bounds.
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
        layer?.addSublayer(cursorLayer)

        receiver.onCursor = { [weak self] x, y, visible in
            self?.moveCursor(x: x, y: y, visible: visible)
        }
        receiver.onCursorImage = { [weak self] image, anchor, normSize in
            self?.setCursorSprite(image, anchor: anchor, normSize: normSize)
        }
        // Replay the sprite/position that arrived before this view existed —
        // the sender re-sends them only on change, so without this the
        // cursor stays invisible until it happens to change shape.
        if let sprite = receiver.cursorSprite {
            setCursorSprite(sprite.image, anchor: sprite.anchor, normSize: sprite.normSize)
        }
        let state = receiver.cursorState
        moveCursor(x: state.x, y: state.y, visible: state.visible)
        // videoSize arrives after the format description — re-fit the layers.
        videoSizeObserver = receiver.$videoSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsLayout = true }

        // The shared perf HUD (same as iOS), toggled by "showAnalytics".
        let overlay = OverlayHostingView(rootView: ReceiverPerfOverlay(receiver: receiver))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: blankCursor)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        updateCursorLayout()
        CATransaction.commit()
    }

    /// Aspect-fit rect of the video inside the view (same math as iOS).
    private func videoRect() -> CGRect? {
        guard let video = receiver?.videoSize, video != .zero,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func moveCursor(x: Double, y: Double, visible: Bool) {
        cursorNorm = CGPoint(x: x, y: y)
        cursorVisible = visible
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = !visible || cursorLayer.contents == nil
        updateCursorLayout()
        CATransaction.commit()
    }

    private func setCursorSprite(_ image: CGImage, anchor: CGPoint, normSize: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = image
        // The wire anchor is the hotspot from the image's TOP-left; AppKit
        // layer unit coords run bottom-up — flip y once here.
        cursorLayer.anchorPoint = CGPoint(x: anchor.x, y: 1 - anchor.y)
        cursorNormSize = normSize
        cursorLayer.isHidden = !cursorVisible
        updateCursorLayout()
        CATransaction.commit()
    }

    private func updateCursorLayout() {
        guard let rect = videoRect(), cursorNormSize != .zero else { return }
        cursorLayer.bounds = CGRect(x: 0, y: 0,
                                    width: cursorNormSize.width * rect.width,
                                    height: cursorNormSize.height * rect.height)
        // Video-space y grows downward, view coords grow upward — flip.
        cursorLayer.position = CGPoint(x: rect.minX + cursorNorm.x * rect.width,
                                       y: rect.maxY - cursorNorm.y * rect.height)
    }
}

// MARK: - Performance overlay host

// This Mac's own pointer over the video reads as a second, dead cursor on
// what acts as a monitor — blank it there. The streamed sender cursor
// (cursorLayer) is the pointer that matters. File-scope so both the video
// view and the overlay above it use the same cursor.
private let blankCursor: NSCursor = {
    let size = NSSize(width: 1, height: 1)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.clear.set()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    return NSCursor(image: image, hotSpot: .zero)
}()

/// The shared PerfOverlay pinned to the bottom of the video, driven by the
/// same "showAnalytics" default the iOS app uses (toggled in the panel).
struct ReceiverPerfOverlay: View {
    @ObservedObject var receiver: StreamReceiver
    @AppStorage("showAnalytics") private var showAnalytics = false

    var body: some View {
        if showAnalytics {
            VStack {
                Spacer()
                PerfOverlay(stats: receiver.perf, videoSize: receiver.videoSize)
                    .padding(.bottom, 10)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Full-bleed, non-interactive layer above the video. Subclassed only so the
/// blank-cursor rect covers the HUD area too.
private final class OverlayHostingView: NSHostingView<ReceiverPerfOverlay> {
    required init(rootView: ReceiverPerfOverlay) {
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: blankCursor)
    }
}
