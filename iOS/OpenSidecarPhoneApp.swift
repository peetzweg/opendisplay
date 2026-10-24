import SwiftUI
import VideoToolbox
import AVFoundation
import UIKit
import Combine

/// Landing page — hosts the Mac app download and explains the two-app setup.
let macAppURL = URL(string: "https://opendisplay.app/")!

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
    @StateObject private var versionGate = VersionGate()
    @State private var showSettings = false
    @State private var showOnboarding = false
    @State private var nagDismissed = false
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

    // Below the force floor → present the blocking gate (issue #135). The
    // fullScreenCover binding's setter is a no-op so the user can't dismiss it.
    private var requiredUpdate: VersionGate.Update? {
        if case let .required(update) = versionGate.status { return update }
        return nil
    }

    // Soft nag: shown once per launch, dismissible.
    private var recommendedUpdate: VersionGate.Update? {
        if case let .recommended(update) = versionGate.status, !nagDismissed { return update }
        return nil
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
            .onChange(of: geo.size) { size in
                model.receiver.setOrientation(portrait: size.height > size.width)
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView { onboardingDismissed = true }
            }
        }
        .ignoresSafeArea(edges: isStreaming ? .all : [])
        .statusBarHidden(isStreaming)
        .systemOverlaysHidden(isStreaming)
        .sheet(isPresented: $showSettings) {
            SettingsView(receiver: model.receiver)
        }
        // Below the force floor → blocking gate. Setter is a no-op: the user
        // cannot dismiss it, only update.
        .fullScreenCover(item: Binding(get: { requiredUpdate }, set: { _ in })) { update in
            UpdateRequiredView(update: update)
        }
        // At/above the floor but behind the recommended version → soft nag.
        .alert("Update available",
               isPresented: Binding(get: { recommendedUpdate != nil },
                                    set: { if !$0 { nagDismissed = true } })) {
            Button("Update") {
                if let update = recommendedUpdate { UIApplication.shared.open(update.url) }
            }
            Button("Later", role: .cancel) { nagDismissed = true }
        } message: {
            if let update = recommendedUpdate { Text(update.message) }
        }
        .task { await versionGate.check() }
        // Merge the connected Mac's compatibility signal into the same gate.
        .onReceive(model.receiver.$peerSignal) { versionGate.applyPeer($0) }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            showSettings = true
        }
        .onChange(of: scenePhase) { phase in
            Log.info("scenePhase -> \(String(describing: phase))")
            switch phase {
            case .active: model.sceneDidActivate()
            case .background: model.sceneDidBackground()
            default: break
            }
        }
        // The deliberate "screen off" signal: locking the device makes
        // protected data unavailable (a plain app switch doesn't). This is
        // what separates "put the iPhone to sleep — end the session now"
        // from "peeked at a message — keep the session alive".
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            Log.info("protected data will become unavailable (device locking)")
            model.deviceWillLock()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            Log.info("protected data available again (device unlocked)")
            model.deviceDidUnlock()
        }
        // Swiping the app away in the switcher (while we're still running)
        // grants a ~5s notice — enough for a clean goodbye so the Mac ends
        // the session at once. A kill without notice is covered Mac-side:
        // dead apps stop accepting redials, so the silence grace fires.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willTerminateNotification)) { _ in
            model.appWillTerminate()
        }
        .onChange(of: model.receiver.connected) { isConnected in
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
    @ObservedObject var receiver: StreamReceiver
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
                HintRow("Plug in the USB cable and open OpenDisplay on your computer",
                        systemImage: "cable.connector")
                HintRow("Or pick this \(deviceKind) under WiFi in OpenDisplay on your computer",
                        systemImage: "wifi")
                HintRow("Keep this app open. Streaming starts automatically.",
                        systemImage: "play.circle")
            }
            .font(.subheadline)
            .padding(20)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16))

            Spacer()

            Button {
                showSettings = true
            } label: {
                Label("Settings & Help", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)

            Text("Tip: shake the \(deviceKind) to open settings anytime")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

/// One hint line: the symbol centered in a fixed-width column, so every
/// row's text starts at the same edge whatever the symbol's width, and the
/// text wraps instead of truncating.
struct HintRow: View {
    let text: String
    let systemImage: String
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 24

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: iconWidth)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - First-run onboarding (the Mac app is required to connect)

/// Shown on first launch / while the device has never connected: OpenDisplay
/// is two apps, and the iOS side is useless without the Mac app running.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    let onClose: () -> Void

    var body: some View {
        AdaptiveNavigation {
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tint)
                        .padding(.top, 24)

                    VStack(spacing: 10) {
                        Text("One more app to go")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text("OpenDisplay turns this \(deviceKind) into a second screen for your Mac. It needs the **OpenDisplay Mac app** running on a Mac connected by the same USB cable or on the same WiFi network.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HintRow("Install the OpenDisplay Mac app on your Mac", systemImage: "1.circle.fill")
                        HintRow("Connect the \(deviceKind) by USB, or join the same WiFi", systemImage: "2.circle.fill")
                        HintRow("Keep this app open. Streaming starts automatically.", systemImage: "3.circle.fill")
                    }
                    .font(.subheadline)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 16))

                    Link(destination: macAppURL) {
                        Label("Get the Mac app", systemImage: "arrow.down.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("You can find this link again anytime in Settings — shake the \(deviceKind) to open it.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        onClose()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Settings / help sheet

struct SettingsView: View {
    @ObservedObject var receiver: StreamReceiver
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("metalRenderer") private var metalRenderer = false
    // Set once the user tapped "Rate on the App Store": the row is an
    // invitation, not a permanent fixture.
    @AppStorage("rateAppTapped") private var rateAppTapped = false
    @Environment(\.openURL) private var openURL

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        AdaptiveNavigation {
            Form {
                if !rateAppTapped {
                    Section {
                        Button {
                            // Hide only once the App Store actually opened
                            // (it can be restricted by Screen Time).
                            openURL(AppStore.reviewURL) { accepted in
                                if accepted { rateAppTapped = true }
                            }
                        } label: {
                            Label("Rate OpenDisplay on the App Store", systemImage: "star")
                        }
                    }
                }

                Section("Status") {
                    LabeledRow("Listening", value: "Port 9000")
                    LabeledRow("Connection",
                               value: receiver.connected ? "Connected" : "Waiting for a computer")
                    if receiver.videoSize != .zero {
                        LabeledRow("Stream",
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
                    Text("Name")
                } footer: {
                    Text("Shown in the WiFi list of OpenDisplay on your computer. iOS hides this \(deviceKind)'s real name from apps, so set it here once.")
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
                    Button("Open iOS Settings for OpenDisplay") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("WiFi mode needs Local Network access. If your computer can't find this \(deviceKind), enable it under Settings → Privacy & Security → Local Network → OpenDisplay. USB mode works without it.")
                }

                Section {
                    NavigationLink {
                        DiagnosticsLogView()
                    } label: {
                        Label("Connection log", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("What this \(deviceKind) saw while connecting: sessions, restarts, decoder trouble. No screen content and nothing leaves the \(deviceKind) unless you share it. Attach it to a GitHub issue if a connection won't come up.")
                }

                Section {
                    Label("USB: plug in the cable and open OpenDisplay on your computer. It connects through the wire on its own (lowest latency).",
                          systemImage: "cable.connector")
                    Label("WiFi: both devices on the same network, then pick this \(deviceKind) in OpenDisplay on your computer.",
                          systemImage: "wifi")
                    Label("Rotate the \(deviceKind) for a vertical second monitor.",
                          systemImage: "rotate.right")
                    Label("Touch: tap to click, drag to drag, two-finger pan to scroll.",
                          systemImage: "hand.tap")
                } header: {
                    Text("How to connect")
                }

                Section {
                    Link(destination: macAppURL) {
                        Label("Get the Mac app", systemImage: "arrow.down.circle")
                    }
                } footer: {
                    Text("OpenDisplay needs the Mac app running on a Mac on the same cable or WiFi network. Download it here if you haven't yet.")
                }

                Section("About") {
                    LabeledRow("Version", value: version)
                    Link(destination: URL(string: "https://opendisplay.app")!) {
                        Label("OpenDisplay.app", systemImage: "globe")
                    }
                    Link(destination: URL(string: "https://github.com/peetzweg/opendisplay")!) {
                        Label("GitHub: peetzweg/opendisplay", systemImage: "link")
                    }
                    Link(destination: URL(string: "https://ko-fi.com/peetzweg")!) {
                        Label("Support OpenDisplay on Ko-fi", systemImage: "cup.and.saucer")
                    }
                    // Permanent counterpart of the one-time row at the top.
                    Link(destination: AppStore.reviewURL) {
                        Label("Rate on the App Store", systemImage: "star")
                    }
                }
            }
            .navigationTitle("OpenDisplay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// `NavigationStack` where it exists (iOS 16), a single-column
/// `NavigationView` on the iOS 15 floor. Both sheets here are one level deep,
/// so the two behave the same; this keeps the modern API where it is available.
struct AdaptiveNavigation<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 16, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

/// `LabeledContent` where it exists (iOS 16, with its VoiceOver pairing of
/// label and value); the equivalent HStack on the iOS 15 floor.
struct LabeledRow: View {
    let title: String
    let value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        if #available(iOS 16, *) {
            LabeledContent(title, value: value)
        } else {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    /// Hide the home indicator while streaming. `persistentSystemOverlays`
    /// is iOS 16; on iOS 15 the indicator simply stays, which is what the
    /// app did before it existed.
    @ViewBuilder
    func systemOverlaysHidden(_ hidden: Bool) -> some View {
        if #available(iOS 16, *) {
            persistentSystemOverlays(hidden ? .hidden : .automatic)
        } else {
            self
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
        TextField("Device name", text: $deviceName)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .focused($focused)
            .onChange(of: deviceName) { name in onChange(name) }
    }
}

// MARK: - Video layer host view

/// SwiftUI host for `VideoView` (iOS/VideoView.swift).
struct VideoLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let receiver: StreamReceiver
    let useMetal: Bool

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.attach(receiver: receiver, displayLayer: displayLayer, useMetal: useMetal)
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        // videoSize arrives after the format description — re-fit the layers.
        uiView.setNeedsLayout()
    }
}
