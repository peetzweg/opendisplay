import SwiftUI
import AVFoundation
import UIKit
import Combine

@main
struct OpenSidecarPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            ReceiverScreen()
        }
    }
}

// MARK: - Shake to open settings

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

// MARK: - Root screen

struct ReceiverScreen: View {
    @StateObject private var model = ReceiverModel()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("metalRenderer") private var metalRenderer = false

    // Streaming = connected and the video format is known.
    private var isStreaming: Bool {
        model.receiver.connected && model.receiver.videoSize != .zero
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if isStreaming {
                    Color.black.ignoresSafeArea()
                    VideoLayerView(displayLayer: model.receiver.displayLayer,
                                   receiver: model.receiver,
                                   useMetal: metalRenderer)
                        .id(metalRenderer)   // rebuild the layer tree on toggle
                        .ignoresSafeArea()
                    if showAnalytics {
                        VStack {
                            Spacer()
                            PerfOverlay(stats: model.receiver.perf,
                                        videoSize: model.receiver.videoSize)
                                .padding(.bottom, 10)
                        }
                        .allowsHitTesting(false)   // never block touch input
                    }
                } else {
                    IdleView(receiver: model.receiver, showSettings: $showSettings)
                }
            }
            .onAppear { model.receiver.setOrientation(portrait: geo.size.height > geo.size.width) }
            .onChange(of: geo.size) { _, size in
                model.receiver.setOrientation(portrait: size.height > size.width)
            }
        }
        .ignoresSafeArea(edges: isStreaming ? .all : [])
        .statusBarHidden(isStreaming)
        .persistentSystemOverlays(isStreaming ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) {
            SettingsView(receiver: model.receiver)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            showSettings = true
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS may tear the listener down while suspended — recover.
            if phase == .active { model.receiver.ensureListening() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
        }
    }
}

// MARK: - Idle view (no Mac connected) — regular iOS look, follows light/dark

struct IdleView: View {
    @ObservedObject var receiver: PhoneReceiver
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("OpenSidecar")
                    .font(.largeTitle.bold())
                HStack(spacing: 8) {
                    Circle()
                        .fill(receiver.connected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(receiver.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                Label("Plug in the USB cable and start the Mac app",
                      systemImage: "cable.connector")
                Label("Or choose this iPhone under WiFi in the Mac app",
                      systemImage: "wifi")
                Label("Keep this app open — streaming starts automatically",
                      systemImage: "play.circle")
            }
            .font(.subheadline)
            .padding(20)
            .frame(maxWidth: 420)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16))

            Spacer()

            Button {
                showSettings = true
            } label: {
                Label("Settings & Help", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)

            Text("Tip: shake the phone to open settings anytime")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - Performance overlay (Steam-Deck style, opt-in via Settings)

struct PerfOverlay: View {
    let stats: PerfStats
    let videoSize: CGSize

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                // Transport badge — the question "is this cable or WiFi?"
                Text(stats.transport)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(stats.transport == "USB" ? Color.green.opacity(0.35)
                                : stats.transport == "WiFi" ? Color.blue.opacity(0.4)
                                : Color.gray.opacity(0.3),
                                in: Capsule())
                    .foregroundStyle(.white)

                if stats.e2eP50 > 0 {
                    metric("latency", String(format: "%.0f ms", stats.e2eP50))
                    metric("p95", String(format: "%.0f ms", stats.e2eP95))
                    metric("encode", String(format: "%.0f ms", stats.encodeP50))
                }
                if stats.decodeP50 > 0 {
                    metric("decode", String(format: "%.1f ms", stats.decodeP50))
                }
                if stats.photonP50 > 0 {
                    // True capture→glass latency (Metal presented handler) —
                    // the only number that includes display vsync.
                    metric("photon", String(format: "%.0f ms", stats.photonP50))
                }
                if stats.inputP50 > 0 {
                    // touch→CGEvent on the Mac; full touch-to-photon adds
                    // the render+capture wait and one e2e on top.
                    metric("input", String(format: "%.0f ms", stats.inputP50))
                }
                metric("rtt", String(format: "%.0f ms", stats.rttMs))
                metric("FPS", "\(stats.fps)")
                if stats.capFps > 0 {
                    metric("Mac cap", "\(stats.capFps)")
                }
                metric("Mbit/s", String(format: "%.1f", stats.mbps))
                metric("stalls", "\(stats.stalls)")
                metric("drops", "\(stats.macDrops)")
                if stats.macPending > 0 {
                    metric("queue", "\(stats.macPending)")
                }
                if stats.decodeFlushes > 0 {
                    metric("flushes", "\(stats.decodeFlushes)")
                }
                metric("res", "\(Int(videoSize.width))×\(Int(videoSize.height))")
            }
            HStack(spacing: 14) {
                graph("latency ms (cap→display)",
                      BarGraph(samples: stats.e2eSamples, ceiling: 80,
                               good: 25, warn: 40, reference: nil))
                graph("frame interval ms",
                      BarGraph(samples: stats.samples, ceiling: 60,
                               good: 25, warn: 50, reference: 16.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func graph(_ label: String, _ content: BarGraph) -> some View {
        VStack(spacing: 2) {
            content.frame(width: 220, height: 38)
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Bar graph over a rolling sample window with green/yellow/red thresholds
/// and an optional reference line (e.g. 16.7 ms = 60 fps).
struct BarGraph: View {
    let samples: [Double]
    let ceiling: Double
    let good: Double
    let warn: Double
    let reference: Double?

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let barWidth = size.width / CGFloat(max(samples.count, 1))
            for (i, ms) in samples.enumerated() {
                let h = min(ms / ceiling, 1.0) * size.height
                let rect = CGRect(x: CGFloat(i) * barWidth,
                                  y: size.height - h,
                                  width: max(barWidth - 0.5, 0.5),
                                  height: h)
                let color: Color = ms <= good ? .green : ms <= warn ? .yellow : .red
                context.fill(Path(rect), with: .color(color.opacity(0.85)))
            }
            if let reference {
                let y = size.height - (reference / ceiling) * size.height
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Settings / help sheet

struct SettingsView: View {
    @ObservedObject var receiver: PhoneReceiver
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("metalRenderer") private var metalRenderer = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Listening", value: "Port 9000")
                    LabeledContent("Connection",
                                   value: receiver.connected ? "Connected" : "Waiting for Mac")
                    if receiver.videoSize != .zero {
                        LabeledContent("Stream",
                                       value: "\(Int(receiver.videoSize.width))×\(Int(receiver.videoSize.height)) @ \(receiver.fps) fps")
                    }
                }

                Section {
                    Toggle("Performance overlay", isOn: $showAnalytics)
                    Toggle("Metal renderer (experimental)", isOn: $metalRenderer)
                } header: {
                    Text("Analytics")
                } footer: {
                    Text("The overlay shows FPS, bitrate, frame timing, stalls, and latency graphs at the bottom of the screen while streaming. The experimental Metal renderer decodes and presents frames manually — it adds decode and true on-glass latency metrics to the overlay, but in our measurements the system video layer displays frames faster. Leave it off unless you're debugging.")
                }

                Section {
                    Button("Open iOS Settings for OpenSidecar") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("WiFi mode needs Local Network access. If your Mac can't find this iPhone, enable it under Settings → Privacy & Security → Local Network → OpenSidecar. USB mode works without it.")
                }

                Section {
                    Label("USB: plug in the cable, run the Mac app — it connects automatically through the wire (lowest latency).",
                          systemImage: "cable.connector")
                    Label("WiFi: both devices on the same network, then pick this iPhone in the Mac app's Connection menu.",
                          systemImage: "wifi")
                    Label("Rotate the phone for a vertical second monitor.",
                          systemImage: "rectangle.portrait.rotate")
                    Label("Touch: tap to click, drag to drag, two-finger pan to scroll.",
                          systemImage: "hand.tap")
                } header: {
                    Text("How to connect")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    Link(destination: URL(string: "https://github.com/peetzweg/opensidecar")!) {
                        Label("GitHub — peetzweg/opensidecar", systemImage: "link")
                    }
                    Link(destination: URL(string: "https://peetzweg.github.io/opensidecar/")!) {
                        Label("Website", systemImage: "globe")
                    }
                }
            }
            .navigationTitle("OpenSidecar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Model

@MainActor
final class ReceiverModel: ObservableObject {
    let receiver: PhoneReceiver
    private var started = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        receiver = PhoneReceiver(displayLayer: AVSampleBufferDisplayLayer())
        // Announce the native panel size to the Mac.
        let native = UIScreen.main.nativeBounds.size   // portrait pixels
        receiver.setNativePanel(long: Int(max(native.width, native.height)),
                                short: Int(min(native.width, native.height)),
                                scale: Double(UIScreen.main.nativeScale))
        receiver.serviceName = UIDevice.current.name
        receiver.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        receiver.start(port: 9000)
    }
}

// MARK: - Video layer host view

/// UIView whose backing layer is the AVSampleBufferDisplayLayer.
/// Forwards touches as normalized video-space coordinates (touchscreen mode).
struct VideoLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let receiver: PhoneReceiver
    let useMetal: Bool

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        view.receiver = receiver

        Log.info("video view: metal=\(useMetal)")
        if useMetal, let renderer = MetalVideoRenderer() {
            Log.info("metal renderer active")
            view.metalRenderer = renderer
            view.layer.addSublayer(renderer.metalLayer)
            receiver.onDecodedFrame = { [weak renderer] pixelBuffer, captureMs in
                renderer?.render(pixelBuffer, captureMs: captureMs)
            }
            renderer.onPresented = { [weak receiver] presentedTime, captureMs in
                receiver?.recordPresented(presentedTime: presentedTime, captureMs: captureMs)
            }
        } else {
            receiver.onDecodedFrame = nil   // route frames back to AVSBDL
            displayLayer.frame = view.bounds
            view.layer.addSublayer(displayLayer)
        }

        let pan = UIPanGestureRecognizer(target: view, action: #selector(VideoView.didTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        // Local cursor echo: position updates ride the ~2ms control path
        // instead of the ~30ms video path, so the pointer feels native.
        receiver.onCursor = { [weak view] x, y, visible in
            view?.moveCursor(x: x, y: y, visible: visible)
        }
        receiver.onCursorImage = { [weak view] image, anchor, normSize in
            view?.setCursorSprite(image, anchor: anchor, normSize: normSize)
        }
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        // videoSize arrives after the format description — re-fit the layers.
        uiView.setNeedsLayout()
    }

    final class VideoView: UIView {
        weak var receiver: PhoneReceiver?
        var metalRenderer: MetalVideoRenderer?

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

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let renderer = metalRenderer {
                // The metal layer scales its drawable to fill its frame, so
                // the frame itself must be the aspect-fit rect.
                renderer.metalLayer.frame = videoRect() ?? bounds
            } else {
                // AVSBDL aspect-fits internally (videoGravity) — full bounds.
                layer.sublayers?.first?.frame = bounds
            }
            if cursorLayer.superlayer == nil { layer.addSublayer(cursorLayer) }
            updateCursorLayout()
            CATransaction.commit()
        }

        /// Aspect-fit rect of the video inside the view (inverse of normalized()).
        private func videoRect() -> CGRect? {
            guard let video = receiver?.videoSize, video != .zero,
                  bounds.width > 0, bounds.height > 0 else { return nil }
            let scale = min(bounds.width / video.width, bounds.height / video.height)
            let size = CGSize(width: video.width * scale, height: video.height * scale)
            return CGRect(x: (bounds.width - size.width) / 2,
                          y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        }

        func moveCursor(x: Double, y: Double, visible: Bool) {
            cursorNorm = CGPoint(x: x, y: y)
            cursorVisible = visible
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.isHidden = !visible || cursorLayer.contents == nil
            updateCursorLayout()
            CATransaction.commit()
        }

        func setCursorSprite(_ image: UIImage, anchor: CGPoint, normSize: CGSize) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.contents = image.cgImage
            cursorLayer.anchorPoint = anchor
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
            cursorLayer.position = CGPoint(x: rect.minX + cursorNorm.x * rect.width,
                                           y: rect.minY + cursorNorm.y * rect.height)
        }

        // The video is aspect-fit inside the view; map view coords into the
        // displayed video rect and normalize to [0,1].
        private func normalized(_ point: CGPoint) -> (x: Double, y: Double)? {
            guard let video = receiver?.videoSize, video != .zero,
                  bounds.width > 0, bounds.height > 0 else { return nil }
            let scale = min(bounds.width / video.width, bounds.height / video.height)
            let size = CGSize(width: video.width * scale, height: video.height * scale)
            let origin = CGPoint(x: (bounds.width - size.width) / 2,
                                 y: (bounds.height - size.height) / 2)
            let x = (point.x - origin.x) / size.width
            let y = (point.y - origin.y) / size.height
            return (min(max(x, 0), 1), min(max(y, 0), 1))
        }

        private var twoFingerActive = false
        private var lastPan = CGPoint.zero
        private var lastNorm: (x: Double, y: Double) = (0.5, 0.5)

        @objc func didTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let video = receiver?.videoSize, video != .zero else { return }
            switch recognizer.state {
            case .began:
                twoFingerActive = true
                lastPan = .zero
            case .changed:
                let t = recognizer.translation(in: self)
                let scale = min(bounds.width / video.width, bounds.height / video.height)
                // Deltas in video pixels, natural-scrolling direction.
                receiver?.sendScroll(dx: (t.x - lastPan.x) / scale,
                                     dy: (t.y - lastPan.y) / scale)
                lastPan = t
            default:
                twoFingerActive = false
            }
        }

        private func send(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            // Ignore single-finger events while a two-finger gesture runs,
            // and end the click if a second finger joins mid-press.
            if twoFingerActive || (event?.allTouches?.count ?? 1) > 1 {
                if phase != "began" {
                    receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y)
                }
                return
            }
            guard let touch = touches.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm
            if phase == "moved", let event {
                // The panel samples touches at 120Hz but UIKit delivers at
                // display refresh — forward every coalesced sample so the Mac
                // gets the full-rate drag, then UIKit's predicted touch so the
                // cursor leads toward where the finger will be (~1 frame of
                // perceived latency back; corrected by the next real sample).
                for t in event.coalescedTouches(for: touch) ?? [touch] {
                    if let n = normalized(t.location(in: self)) {
                        lastNorm = n
                        receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                    }
                }
                if let predicted = event.predictedTouches(for: touch)?.last,
                   let n = normalized(predicted.location(in: self)) {
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
                return
            }
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send("began", touches, event) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send("moved", touches, event) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send("ended", touches, event) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send("cancelled", touches, event) }
    }
}
