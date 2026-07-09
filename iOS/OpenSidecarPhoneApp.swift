import SwiftUI
import AVFoundation
import UIKit
import Combine

/// "iPad" or "iPhone" — so UI copy names the device the user is holding.
let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

/// Landing page — hosts the Mac app download and explains the two-app setup.
let macAppURL = URL(string: "https://peetzweg.github.io/opendisplay/")!

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
    @State private var showOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("metalRenderer") private var metalRenderer = false
    // First-run onboarding (issue #49): explain the Mac app is required.
    // Shown until either the user dismisses it or the device connects once.
    @AppStorage("hasConnectedBefore") private var hasConnectedBefore = false
    @AppStorage("onboardingDismissed") private var onboardingDismissed = false

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
            .sheet(isPresented: $showOnboarding) {
                OnboardingView { onboardingDismissed = true }
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
        .onChange(of: model.receiver.connected) { _, isConnected in
            // The first valid connection retires the onboarding hint for good.
            if isConnected {
                hasConnectedBefore = true
                showOnboarding = false
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
            // Show the first-run hint unless the device has connected before
            // or the user already dismissed it.
            if !hasConnectedBefore && !onboardingDismissed {
                showOnboarding = true
            }
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

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 132)

            VStack(spacing: 6) {
                Text("OpenDisplay")
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
                Label("连接 USB 线，并启动 Mac 端 app",
                      systemImage: "cable.connector")
                Label("或在 Mac 端的 WiFi 列表中选择这台 \(deviceKind)",
                      systemImage: "wifi")
                Label("保持此 app 打开，画面会自动开始传输",
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
                Label("设置与帮助", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)

            Text("提示：随时摇一摇这台 \(deviceKind) 即可打开设置")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - First-run onboarding (the Mac app is required to connect)

/// Shown on first launch / while the device has never connected: OpenDisplay
/// is two apps, and the iOS side is useless without the Mac app running.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tint)
                        .padding(.top, 24)

                    VStack(spacing: 10) {
                        Text("还需要安装 Mac 端")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text("OpenDisplay 可以把这台 \(deviceKind) 变成 Mac 的第二块屏幕，但需要在通过同一根 USB 线连接、或处于同一 WiFi 网络的 Mac 上运行 **OpenDisplay Mac 端 app**。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Label("在 Mac 上安装 OpenDisplay Mac 端 app", systemImage: "1.circle.fill")
                        Label("用 USB 连接这台 \(deviceKind)，或加入同一 WiFi", systemImage: "2.circle.fill")
                        Label("保持此 app 打开，串流会自动开始", systemImage: "3.circle.fill")
                    }
                    .font(.subheadline)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 16))

                    Link(destination: macAppURL) {
                        Label("获取 Mac 端 app", systemImage: "arrow.down.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("之后也可以在设置里找到这个链接，摇一摇这台 \(deviceKind) 即可打开设置。")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("欢迎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") {
                        onClose()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Performance overlay (Steam-Deck style, opt-in via Settings)

struct PerfOverlay: View {
    let stats: PerfStats
    let videoSize: CGSize

    var body: some View {
        VStack(spacing: 8) {
            // Metrics wrap onto extra rows when the width doesn't fit —
            // portrait iPhone is ~390pt, far less than one full row.
            FlowLayout(hSpacing: 14, vSpacing: 8) {
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
                    metric("延迟", String(format: "%.0f ms", stats.e2eP50))
                    metric("p95", String(format: "%.0f ms", stats.e2eP95))
                    metric("编码", String(format: "%.0f ms", stats.encodeP50))
                }
                if stats.decodeP50 > 0 {
                    metric("解码", String(format: "%.1f ms", stats.decodeP50))
                }
                if stats.photonP50 > 0 {
                    // True capture→glass latency (Metal presented handler) —
                    // the only number that includes display vsync.
                    metric("上屏", String(format: "%.0f ms", stats.photonP50))
                }
                if stats.inputP50 > 0 {
                    // touch→CGEvent on the Mac; full touch-to-photon adds
                    // the render+capture wait and one e2e on top.
                    metric("输入", String(format: "%.0f ms", stats.inputP50))
                }
                metric("rtt", String(format: "%.0f ms", stats.rttMs))
                metric("FPS", "\(stats.fps)")
                if stats.capFps > 0 {
                    metric("Mac 捕获", "\(stats.capFps)")
                }
                metric("Mbit/s", String(format: "%.1f", stats.mbps))
                metric("卡顿", "\(stats.stalls)")
                metric("丢帧", "\(stats.macDrops)")
                if stats.macPending > 0 {
                    metric("队列", "\(stats.macPending)")
                }
                if stats.decodeFlushes > 0 {
                    metric("刷新", "\(stats.decodeFlushes)")
                }
                metric("分辨率", "\(Int(videoSize.width))×\(Int(videoSize.height))")
            }
            // Two graphs side by side where they fit (landscape), stacked
            // where they don't (portrait).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { graphs }
                VStack(spacing: 8) { graphs }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var graphs: some View {
        graph("延迟 ms（捕获→显示）",
              BarGraph(samples: stats.e2eSamples, ceiling: 80,
                       good: 25, warn: 40, reference: nil))
        graph("帧间隔 ms",
              BarGraph(samples: stats.samples, ceiling: 60,
                       good: 25, warn: 50, reference: 16.7))
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

/// Left-aligned wrapping row: children flow onto as many rows as the
/// proposed width requires. Keeps the perf overlay inside the screen in
/// portrait instead of clipping off both edges.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 14
    var vSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0
        var rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - hSpacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
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
                Section("状态") {
                    LabeledContent("监听", value: "端口 9000")
                    LabeledContent("连接",
                                   value: receiver.connected ? "已连接" : "正在等待 Mac")
                    if receiver.videoSize != .zero {
                        LabeledContent("画面",
                                       value: "\(Int(receiver.videoSize.width))×\(Int(receiver.videoSize.height)) @ \(receiver.fps) fps")
                    }
                }

                Section {
                    // Isolated from the receiver: the Status section above
                    // re-renders on every stream update, and a TextField that
                    // rebuilds mid-tap loses focus (the "tap twice to edit"
                    // bug). This subview owns its focus and doesn't observe
                    // the receiver, so it survives those rebuilds.
                    DeviceNameField { receiver.setServiceName($0) }
                } header: {
                    Text("名称")
                } footer: {
                    Text("此名称会显示在 Mac 端的 WiFi 连接菜单里。iOS 不允许 app 读取这台 \(deviceKind) 的真实设备名，所以请在这里设置一次。")
                }

                Section {
                    Toggle("性能浮层", isOn: $showAnalytics)
                    Toggle("Metal 渲染器（实验性）", isOn: $metalRenderer)
                } header: {
                    Text("性能分析")
                } footer: {
                    Text("性能浮层会在串流时显示 FPS、码率、帧间隔、卡顿和延迟图表。实验性 Metal 渲染器会手动解码并显示帧，可额外显示解码和真实上屏延迟；但实测系统视频层更快，除非调试，否则建议关闭。")
                }

                Section {
                    Button("打开 OpenDisplay 的 iOS 设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("权限")
                } footer: {
                    Text("WiFi 模式需要“本地网络”权限。如果 Mac 找不到这台 \(deviceKind)，请到“设置”→“隐私与安全性”→“本地网络”中允许 OpenDisplay。USB 模式不需要此权限。")
                }

                Section {
                    Label("USB：插上线并运行 Mac 端 app，它会自动通过线缆连接，延迟最低。",
                          systemImage: "cable.connector")
                    Label("WiFi：两台设备连接到同一网络，然后在 Mac 端连接菜单中选择这台 \(deviceKind)。",
                          systemImage: "wifi")
                    Label("旋转这台 \(deviceKind)，即可作为竖屏第二显示器使用。",
                          systemImage: "rectangle.portrait.rotate")
                    Label("触摸：轻点=点击，拖动=拖拽，双指滑动=滚动。",
                          systemImage: "hand.tap")
                } header: {
                    Text("如何连接")
                }

                Section {
                    Link(destination: macAppURL) {
                        Label("获取 Mac 端 app", systemImage: "arrow.down.circle")
                    }
                } footer: {
                    Text("OpenDisplay 需要 Mac 端 app 在同一根线缆或同一 WiFi 网络中的 Mac 上运行。如果还没有安装，可以从这里下载。")
                }

                Section("关于") {
                    LabeledContent("版本", value: version)
                    Link(destination: URL(string: "https://github.com/peetzweg/opendisplay")!) {
                        Label("GitHub — peetzweg/opendisplay", systemImage: "link")
                    }
                    Link(destination: macAppURL) {
                        Label("官网", systemImage: "globe")
                    }
                }
            }
            .navigationTitle("OpenDisplay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// The device-name editor, deliberately kept out of any high-frequency
/// @ObservedObject so streaming updates can't rebuild it and steal focus.
private struct DeviceNameField: View {
    @AppStorage("deviceName") private var deviceName = UIDevice.current.name
    @FocusState private var focused: Bool
    let onChange: (String) -> Void

    var body: some View {
        TextField("设备名称", text: $deviceName)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .focused($focused)
            .onChange(of: deviceName) { _, name in onChange(name) }
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
        let savedName = UserDefaults.standard.string(forKey: "deviceName")
        receiver.serviceName = (savedName?.isEmpty == false) ? savedName! : UIDevice.current.name
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

        private var lastLoggedLayout = ""

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
            // Rotation diagnostics — one line per layout change.
            let video = receiver?.videoSize ?? .zero
            let line = "layout: bounds=\(Int(bounds.width))x\(Int(bounds.height))"
                + " video=\(Int(video.width))x\(Int(video.height))"
                + " layer=\(Int(layer.sublayers?.first?.frame.width ?? -1))x\(Int(layer.sublayers?.first?.frame.height ?? -1))"
            if line != lastLoggedLayout {
                lastLoggedLayout = line
                Log.info(line)
            }
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
