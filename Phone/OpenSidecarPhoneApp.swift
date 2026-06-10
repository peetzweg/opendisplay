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
                                   receiver: model.receiver)
                        .ignoresSafeArea()
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(model.receiver.fps) fps")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(6)
                        }
                        Spacer()
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

// MARK: - Settings / help sheet

struct SettingsView: View {
    @ObservedObject var receiver: PhoneReceiver
    @Environment(\.dismiss) private var dismiss

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

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        view.receiver = receiver
        displayLayer.frame = view.bounds
        view.layer.addSublayer(displayLayer)

        let pan = UIPanGestureRecognizer(target: view, action: #selector(VideoView.didTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {}

    final class VideoView: UIView {
        weak var receiver: PhoneReceiver?

        override func layoutSubviews() {
            super.layoutSubviews()
            // Keep the display layer sized to the view without implicit animation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayers?.first?.frame = bounds
            CATransaction.commit()
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
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send("began", touches, event) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send("moved", touches, event) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send("ended", touches, event) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send("cancelled", touches, event) }
    }
}
