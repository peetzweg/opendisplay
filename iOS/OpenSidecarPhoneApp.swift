import SwiftUI
import VideoToolbox
import AVFoundation
import UIKit
import Combine

/// "iPad" or "iPhone" — so UI copy names the device the user is holding.
let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

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
    @AppStorage(VideoLayerView.VideoView.actionsButtonKey) private var actionsButton = true
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
                    Toggle("Mac actions button", isOn: $actionsButton)
                } header: {
                    Text("Touch")
                } footer: {
                    Text("A floating button for Mission Control, App Exposé, Show Desktop, Apps, Spotlight and Spaces. Drag it to any edge.")
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

// MARK: - Model

@MainActor
final class ReceiverModel: ObservableObject {
    let receiver: StreamReceiver
    private var started = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Offer HEVC wherever the hardware decodes it (A9 and later; the A8/A8X
        // iPads stay on H.264). Panels here fit H.264's raster anyway, so HEVC
        // buys quality per bit, which matters most over WiFi. Bounded by the
        // panel in either orientation, so a large mirrored Mac display is
        // scaled to what this screen can show instead of sent in full.
        let native = UIScreen.main.nativeBounds.size   // portrait pixels
        let longSide = Int(max(native.width, native.height))
        var decodesHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        #if DEBUG
        // The simulator has no hardware decoder; -forceHEVCOffer YES exercises
        // the HEVC receive path there with software decode.
        if UserDefaults.standard.bool(forKey: "forceHEVCOffer") { decodesHEVC = true }
        #endif
        let hevc = decodesHEVC
            ? VideoCapability(codec: "hevc", maxWidth: longSide, maxHeight: longSide,
                              maxFrameRate: 60)
            : nil
        receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                  deviceKind: deviceKind,
                                  fallbackServiceName: UIDevice.current.name,
                                  hevcCapability: hevc)
        // Announce the native panel size to the Mac.
        receiver.setNativePanel(long: Int(max(native.width, native.height)),
                                short: Int(min(native.width, native.height)),
                                scale: Double(UIScreen.main.nativeScale))
        receiver.setDisplayMaxFrameRate(UIScreen.main.maximumFramesPerSecond)
        if let budget = DecodeBudget.maxPixelsPerSecond(model: DecodeBudget.currentModel) {
            receiver.setDecodeBudget(maxPixelsPerSecond: budget)
        }
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

    // MARK: - Lock vs app switch vs app quit

    // A plain app switch keeps the session (and the Mac's virtual display,
    // and therefore the user's window arrangement) alive INDEFINITELY. The
    // assertion buys ~30s of live pings; after iOS suspends us the kernel
    // still accepts the Mac's redials, so the session survives untouched
    // until we return. Only a device lock (deliberate "screen off") or the
    // app being quit ends the session. Known hole: a lock that happens
    // after we're already suspended is undetectable — no code runs and the
    // kernel behaves identically — so the display stays up until the user
    // returns or the app dies.
    private var backgroundToken: UIBackgroundTaskIdentifier = .invalid

    func sceneDidBackground() {
        // Known limitation: lock detection rides the protected-data signal,
        // which only fires when a passcode is set AND "Require Passcode" is
        // Immediately (the Face ID default). Other configurations make a
        // lock indistinguishable from an app switch, so those keep the
        // session like a backgrounded app would.
        if !UIApplication.shared.isProtectedDataAvailable {
            // Backgrounded because the device locked, not an app switch.
            Log.info("backgrounded by device lock — sleeping now")
            goToSleep()
            return
        }
        Log.info("app switched away — keeping the session, rendering paused")
        beginBackgroundAssertion()
        receiver.setRenderingPaused(true)
    }

    func sceneDidActivate() {
        endBackgroundAssertion()
        receiver.setRenderingPaused(false)
        receiver.ensureListening()
    }

    func deviceWillLock() {
        Log.info("device locking — sleeping now")
        goToSleep()
    }

    /// Unlock arrives via the protected-data notification, which also fires
    /// when the user unlocks into ANOTHER app while we sit in the background
    /// — don't re-arm the listener or unpause rendering off-screen there;
    /// the real return still comes through scenePhase.
    func deviceDidUnlock() {
        guard UIApplication.shared.applicationState == .active else {
            Log.info("unlocked while backgrounded — staying dormant")
            return
        }
        sceneDidActivate()
    }

    /// User swiped the app away (or iOS terminates us while still running):
    /// ~5s of runtime remain, plenty for the "closing" goodbye that lets the
    /// Mac end the session immediately instead of after its silence grace.
    func appWillTerminate() {
        Log.info("app terminating — closing session")
        receiver.shutDown()
    }

    private func goToSleep() {
        receiver.enterSleep { [weak self] in
            DispatchQueue.main.async { self?.endBackgroundAssertion() }
        }
    }

    private func beginBackgroundAssertion() {
        guard backgroundToken == .invalid else { return }
        backgroundToken = UIApplication.shared.beginBackgroundTask { [weak self] in
            // Suspension takes us now; the session stays up by design (the
            // kernel keeps accepting for us) — just release the assertion.
            self?.endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundToken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundToken)
        backgroundToken = .invalid
    }
}

// MARK: - Touch sampling

extension UIEvent {
    /// Every position UIKit recorded for `touch` in this update, oldest first.
    ///
    /// The panel samples faster than UIKit delivers, so a single `touchesMoved`
    /// stands for several real positions. This batch is that whole history and
    /// its *last* entry is `touch` itself, so forward the list as it comes:
    /// sending `touch` alongside it puts the newest sample ahead of its own
    /// history and emits it twice, which reads as backtracking on fast strokes.
    /// Falls back to the touch alone when UIKit coalesced nothing.
    func samples(for touch: UITouch) -> [UITouch] {
        let batch = coalescedTouches(for: touch) ?? []
        return batch.isEmpty ? [touch] : batch
    }
}

// MARK: - Video layer host view

/// UIView whose backing layer is the AVSampleBufferDisplayLayer.
/// Forwards touches as normalized video-space coordinates (touchscreen mode).
struct VideoLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let receiver: StreamReceiver
    let useMetal: Bool

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        view.receiver = receiver
        view.installActionsButton()

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

        view.inputEngine.normalize = { [weak view] point in view?.normalized(point) }
        view.inputEngine.onPencil = { [weak receiver] phase, x, y, pressure, azimuth, altitude in
            receiver?.sendPencil(phase: phase, x: x, y: y,
                                 pressure: pressure, azimuth: azimuth,
                                 altitude: altitude)
        }
        view.inputEngine.onProximity = { [weak receiver] entering, x, y in
            receiver?.sendProximity(entering: entering, x: x, y: y)
        }
        view.inputEngine.install(on: view)

        let pan = UIPanGestureRecognizer(target: view, action: #selector(VideoView.didTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        // Two-finger tap = secondary click, as on a Mac trackpad.
        let twoFingerTap = UITapGestureRecognizer(target: view, action: #selector(VideoView.didTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        // Single-finger taps must not wait for this recognizer to give up.
        twoFingerTap.delaysTouchesEnded = false
        view.addGestureRecognizer(twoFingerTap)

        // Pinch = trackpad magnify. Not simultaneous with the two-finger pan:
        // whichever the fingers commit to first wins, as on a trackpad.
        let pinch = UIPinchGestureRecognizer(target: view, action: #selector(VideoView.didPinch(_:)))
        // A one-finger lift must not wait for the pinch to give up: held
        // back past the long-press delay, a tap would read as a hold.
        pinch.delaysTouchesEnded = false
        view.addGestureRecognizer(pinch)

        // Local cursor echo: position updates ride the ~2ms control path
        // instead of the ~30ms video path, so the pointer feels native.
        receiver.onCursor = { [weak view] x, y, visible in
            view?.moveCursor(x: x, y: y, visible: visible)
        }
        receiver.onCursorImage = { [weak view] image, anchor, normSize in
            view?.setCursorSprite(image, anchor: anchor, normSize: normSize)
        }
        // Replay the sprite/position that arrived before this view existed
        // (first frames land after the connect-time sprite) or that the
        // previous view held (metal-renderer toggle rebuilds the view tree).
        if let sprite = receiver.cursorSprite {
            view.setCursorSprite(sprite.image, anchor: sprite.anchor, normSize: sprite.normSize)
        }
        let state = receiver.cursorState
        view.moveCursor(x: state.x, y: state.y, visible: state.visible)
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        // videoSize arrives after the format description — re-fit the layers.
        uiView.setNeedsLayout()
    }

    final class VideoView: UIView {
        weak var receiver: StreamReceiver?
        var metalRenderer: MetalVideoRenderer?
        let inputEngine = InputCaptureEngine()

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

        /// The video layer: the Metal layer or the AVSBDL, found by type —
        /// subviews (the actions button) add sublayers of their own.
        private var videoLayer: CALayer? {
            metalRenderer?.metalLayer ?? layer.sublayers?.first { $0 is AVSampleBufferDisplayLayer }
        }

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
                videoLayer?.frame = bounds
            }
            if cursorLayer.superlayer == nil { layer.addSublayer(cursorLayer) }
            updateCursorLayout()
            CATransaction.commit()
            layoutActionsButton()
            // Rotation diagnostics — one line per layout change.
            let video = receiver?.videoSize ?? .zero
            let line = "layout: bounds=\(Int(bounds.width))x\(Int(bounds.height))"
                + " video=\(Int(video.width))x\(Int(video.height))"
                + " layer=\(Int(videoLayer?.frame.width ?? -1))x\(Int(videoLayer?.frame.height ?? -1))"
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

        func setCursorSprite(_ image: CGImage, anchor: CGPoint, normSize: CGSize) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.contents = image
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
        fileprivate func normalized(_ point: CGPoint) -> (x: Double, y: Double)? {
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

        private func isFinger(_ touch: UITouch) -> Bool {
            switch touch.type {
            case .direct, .indirectPointer: return true
            default: return false
            }
        }

        private func isPencil(_ touch: UITouch) -> Bool {
            touch.type == .pencil
        }

        private var twoFingerActive = false
        private var lastPan = CGPoint.zero
        private var lastNorm: (x: Double, y: Double) = (0.5, 0.5)

        /// This gesture's scroll carries phases (the Mac announced `scrollPhase`).
        private var scrollPhased = false
        private var scrollStarted = false

        @objc func didTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let video = receiver?.videoSize, video != .zero else { return }
            let scale = min(bounds.width / video.width, bounds.height / video.height)
            switch recognizer.state {
            case .began:
                stopMomentum()
                twoFingerActive = true
                // Start from where recognition happened: the slop the fingers
                // travelled before it would otherwise land as one jump.
                lastPan = recognizer.translation(in: self)
                scrollPhased = receiver?.macSupportsScrollPhase ?? false
                scrollStarted = false
                // macOS delivers scroll to whatever sits under the cursor, and
                // the cursor no longer follows the fingers now that a press is
                // withheld until it commits. Put it on the gesture once, up
                // front, so the scroll lands on the window being touched. Once
                // only: a real trackpad does not drag the cursor while
                // scrolling, and moving it mid-gesture would change the target.
                if let n = normalized(recognizer.location(in: self)) {
                    lastNorm = n
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
            case .changed:
                let t = recognizer.translation(in: self)
                // Deltas in video pixels, natural-scrolling direction.
                let dx = (t.x - lastPan.x) / scale, dy = (t.y - lastPan.y) / scale
                lastPan = t
                if scrollPhased {
                    receiver?.sendScroll(dx: dx, dy: dy, phase: scrollStarted ? "changed" : "began")
                    scrollStarted = true
                } else {
                    receiver?.sendScroll(dx: dx, dy: dy)
                }
            default:
                twoFingerActive = false
                guard scrollPhased, scrollStarted else { return }
                scrollStarted = false
                receiver?.sendScroll(dx: 0, dy: 0, phase: "ended")
                if recognizer.state == .ended {
                    startMomentum(velocity: recognizer.velocity(in: self), videoScale: scale)
                }
            }
        }

        // MARK: Scroll momentum
        //
        // A flick keeps the content coasting after the fingers lift, like a Mac
        // trackpad. Generated here rather than on the Mac: the phone has the
        // real finger velocity, the Mac only deltas after network jitter.
        // Constants from Sill (#372): 0.96 decay per 1/60 s gives a 1–2 s
        // coast, within a trackpad's 1.5–2.5 s.

        private var momentumLink: CADisplayLink?
        /// View points per second, natural-scrolling sign.
        private var momentumVelocity = CGPoint.zero
        private var momentumVideoScale: CGFloat = 1
        private var momentumStarted = false
        private var momentumLastTimestamp: CFTimeInterval = 0
        /// Slower lift-offs are a deliberate stop, not a flick.
        private let momentumMinimumSpeed: CGFloat = 150
        private let momentumDecayPerFrame: CGFloat = 0.96
        /// Coasting stops once a 60 Hz frame would move less than this (points).
        private let momentumStopDelta: CGFloat = 0.3

        private func startMomentum(velocity: CGPoint, videoScale: CGFloat) {
            stopMomentum()
            guard hypot(velocity.x, velocity.y) >= momentumMinimumSpeed else { return }
            momentumVelocity = velocity
            momentumVideoScale = videoScale
            momentumStarted = false
            momentumLastTimestamp = 0
            let link = CADisplayLink(target: MomentumTarget(self), selector: #selector(MomentumTarget.tick(_:)))
            // 60 Hz on ProMotion too, so the Mac's message rate does not double.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            momentumLink = link
        }

        fileprivate func momentumTick(_ link: CADisplayLink) {
            let dt = momentumLastTimestamp == 0 ? 1.0 / 60 : link.timestamp - momentumLastTimestamp
            momentumLastTimestamp = link.timestamp
            let frames = CGFloat(dt * 60)
            let decay = pow(momentumDecayPerFrame, frames)
            momentumVelocity = CGPoint(x: momentumVelocity.x * decay, y: momentumVelocity.y * decay)
            let dx = momentumVelocity.x * CGFloat(dt), dy = momentumVelocity.y * CGFloat(dt)
            guard hypot(dx, dy) >= momentumStopDelta * frames else {
                stopMomentum()
                return
            }
            receiver?.sendScroll(dx: dx / momentumVideoScale, dy: dy / momentumVideoScale,
                                 phase: momentumStarted ? "momentumChanged" : "momentumBegan")
            momentumStarted = true
        }

        /// Stop coasting, e.g. because a finger landed: a touch on a trackpad
        /// catches the content too.
        private func stopMomentum() {
            momentumLink?.invalidate()
            momentumLink = nil
            if momentumStarted {
                momentumStarted = false
                receiver?.sendScroll(dx: 0, dy: 0, phase: "momentumEnded")
            }
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil { stopMomentum() }
        }

        // MARK: Mac actions button
        //
        // An AssistiveTouch-style floating button: tap for a menu of the Mac's
        // system actions (`welcome.actions`), drag it to either edge. Shown
        // only when the Mac offers actions and the user has not turned it off.

        static let actionsButtonKey = "actionsButton"
        private static let actionsButtonRightKey = "actionsButtonRight"
        private static let actionsButtonYKey = "actionsButtonY"
        private static let actionItems: [(name: String, title: String, symbol: String)] = [
            ("missionControl", "Mission Control", "rectangle.3.group"),
            ("appExpose", "App Exposé", "macwindow.on.rectangle"),
            ("showDesktop", "Show Desktop", "menubar.dock.rectangle"),
            ("apps", "Apps", "square.grid.3x3"),
            ("spotlight", "Spotlight", "magnifyingglass"),
            ("spaceLeft", "Previous Space", "arrow.left.square"),
            ("spaceRight", "Next Space", "arrow.right.square"),
        ]
        private let actionsButtonSize: CGFloat = 52
        private let actionsButtonIdleAlpha: CGFloat = 0.7
        private var actionsButton: UIButton?
        private var draggingActionsButton = false
        private var actionsSubscriptions = Set<AnyCancellable>()

        func installActionsButton() {
            guard let receiver, actionsButton == nil else { return }
            var config = UIButton.Configuration.filled()
            config.image = UIImage(systemName: "circle.grid.2x2.fill")
            config.cornerStyle = .capsule
            config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
            config.baseForegroundColor = .white
            let button = RoundButton(configuration: config)
            button.bounds = CGRect(x: 0, y: 0, width: actionsButtonSize, height: actionsButtonSize)
            button.alpha = actionsButtonIdleAlpha
            button.layer.zPosition = 20   // above the cursor layer
            button.showsMenuAsPrimaryAction = true
            if #available(iOS 16.0, *) { button.preferredMenuElementOrder = .fixed }
            button.accessibilityLabel = "Mac actions"
            button.isHidden = true
            button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragActionsButton(_:))))
            addSubview(button)
            actionsButton = button

            receiver.$macActions
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.updateActionsButton($0) }
                .store(in: &actionsSubscriptions)
            // The settings toggle writes this one default; watch only it.
            UserDefaults.standard.publisher(for: \.actionsButton)
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateActionsButton(self?.receiver?.macActions ?? []) }
                .store(in: &actionsSubscriptions)
        }

        private func updateActionsButton(_ actions: [String]) {
            guard let button = actionsButton else { return }
            let enabled = UserDefaults.standard.actionsButton
            let items = Self.actionItems.filter { actions.contains($0.name) }.map { item in
                UIAction(title: item.title, image: UIImage(systemName: item.symbol)) { [weak self] _ in
                    self?.receiver?.sendGesture(action: item.name)
                }
            }
            button.menu = UIMenu(children: items)
            button.isHidden = !enabled || items.isEmpty
            setNeedsLayout()
        }

        /// The usable area for the button: inside the safe area, off the edge.
        private func actionsButtonArea() -> CGRect {
            bounds.inset(by: safeAreaInsets).insetBy(dx: 8, dy: 8)
        }

        private func layoutActionsButton() {
            guard let button = actionsButton, !button.isHidden, !draggingActionsButton else { return }
            let area = actionsButtonArea()
            guard area.width > actionsButtonSize, area.height > actionsButtonSize else { return }
            let defaults = UserDefaults.standard
            let right = defaults.object(forKey: Self.actionsButtonRightKey) as? Bool ?? true
            let fraction = defaults.object(forKey: Self.actionsButtonYKey) as? Double ?? 0.75
            let half = actionsButtonSize / 2
            button.center = CGPoint(x: right ? area.maxX - half : area.minX + half,
                                    y: area.minY + half + CGFloat(fraction) * (area.height - actionsButtonSize))
        }

        /// Drag anywhere; on release it snaps to the nearer side edge and
        /// remembers the side and height, so it survives rotation.
        @objc private func dragActionsButton(_ recognizer: UIPanGestureRecognizer) {
            guard let button = actionsButton else { return }
            switch recognizer.state {
            case .began:
                draggingActionsButton = true
                button.alpha = 1
            case .changed:
                let t = recognizer.translation(in: self)
                button.center = CGPoint(x: button.center.x + t.x, y: button.center.y + t.y)
                recognizer.setTranslation(.zero, in: self)
            default:
                draggingActionsButton = false
                let area = actionsButtonArea()
                let travel = max(area.height - actionsButtonSize, 1)
                let fraction = (button.center.y - area.minY - actionsButtonSize / 2) / travel
                UserDefaults.standard.set(button.center.x > bounds.midX, forKey: Self.actionsButtonRightKey)
                UserDefaults.standard.set(Double(min(max(fraction, 0), 1)), forKey: Self.actionsButtonYKey)
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8,
                               initialSpringVelocity: 0) {
                    self.layoutActionsButton()
                    button.alpha = self.actionsButtonIdleAlpha
                }
            }
        }

        private var lastPinchScale: CGFloat = 1

        /// A Mac without `magnify` would drop the pinch, so don't let it take
        /// two fingers away from scrolling there.
        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            if recognizer is UIPinchGestureRecognizer, receiver?.macSupportsMagnify != true { return false }
            return super.gestureRecognizerShouldBegin(recognizer)
        }

        @objc func didPinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                stopMomentum()
                // The Mac magnifies the window under the pointer: put it on the pinch.
                if let n = normalized(recognizer.location(in: self)) {
                    lastNorm = n
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
                lastPinchScale = 1
                fallthrough
            case .changed:
                // Relative change, so the Mac's running product equals the pinch.
                let m = recognizer.scale / lastPinchScale - 1
                lastPinchScale = recognizer.scale
                receiver?.sendMagnify(phase: recognizer.state == .began ? "began" : "changed",
                                      magnification: m)
            case .ended:
                receiver?.sendMagnify(phase: "ended", magnification: 0)
            default:
                receiver?.sendMagnify(phase: "cancelled", magnification: 0)
            }
        }

        @objc func didTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, receiver?.macSupportsTouchButtons == true,
                  let n = normalized(recognizer.location(in: self)) else { return }
            lastNorm = n
            press(at: n, button: "right")
            receiver?.sendTouch(phase: "ended", x: n.x, y: n.y, button: "right")
        }

        // A press is only a click once we know a second finger is not coming.
        // Sending `began` on contact posted a mouse-down we then had to take
        // back, and taking it back only works when UIKit happens to deliver
        // `cancelled`; when the pan recognizer misses and we get a plain
        // `ended` instead, that down/up pair *is* a click, which is why every
        // other two-finger scroll opened whatever sat under the first finger.
        // So hold the down until the gesture commits to being one.
        private var pendingDown: (x: Double, y: Double)?
        private var downSent = false
        private var holdTimer: DispatchWorkItem?

        /// Movement (in points) that turns a held press into a drag.
        private let dragSlop: CGFloat = 10
        /// A press this long with no second finger is a deliberate hold, so
        /// commit it: press-and-hold menus and drag handles need the button.
        /// Only for Macs without the touchscreen rules (see `touchScrolls`),
        /// which get `longPressDelay` instead.
        private let holdDelay: TimeInterval = 0.12
        /// A press held this long without moving is a secondary click, the way
        /// macOS 27 Sidecar and UIKit's long press read it. Moving first is a drag.
        private let longPressDelay: TimeInterval = 0.5
        private var pendingDownPoint: CGPoint = .zero
        private let secondaryClickFeedback = UIImpactFeedbackGenerator(style: .medium)

        /// Emit the withheld `began`, at the point the finger first landed so a
        /// drag starts where the user touched rather than where slop was crossed.
        private func commitPendingDown() {
            guard let p = pendingDown, !downSent else { return }
            downSent = true
            holdTimer?.cancel()
            holdTimer = nil
            press(at: p)
        }

        /// Move the pointer to the press, then press. Some apps act on the
        /// position the last mouse move left (#310), so the button must not
        /// arrive with the jump.
        private func press(at p: (x: Double, y: Double), button: String? = nil) {
            receiver?.sendTouch(phase: "moved", x: p.x, y: p.y)
            receiver?.sendTouch(phase: "began", x: p.x, y: p.y, button: button)
        }

        /// Drop the press without a trace. Nothing reached the Mac, so there is
        /// no button to release and no click to suppress.
        private func discardPendingDown() {
            pendingDown = nil
            downSent = false
            holdTimer?.cancel()
            holdTimer = nil
            intent = .deciding
        }

        // MARK: One finger, touchscreen style
        //
        // With a Mac that takes `touch.button` and `scroll.phase`, one finger
        // behaves as on the iPhone itself and as in macOS 27 Sidecar: dragging
        // scrolls; to select or drag something, hold still for
        // `longPressDelay` (a tap of haptics confirms), then move; holding and
        // lifting without moving is a secondary click; a tap is a click.

        private enum FingerIntent { case deciding, scrolling, held, pressing }
        private var intent = FingerIntent.deciding
        /// Fixed per press: the touchscreen-style rules apply to this one.
        private var touchScrolls = false
        private var fingerScrollStarted = false
        private var lastFingerPoint = CGPoint.zero
        /// Recent (timestamp, location) samples for the lift-off velocity.
        private var fingerSamples: [(t: TimeInterval, p: CGPoint)] = []
        /// When the finger landed (UITouch clock), to judge a hold by when the
        /// finger actually lifted rather than when UIKit delivered the lift.
        private var fingerDownTime: TimeInterval = 0

        private func videoScale() -> CGFloat? {
            guard let video = receiver?.videoSize, video != .zero else { return nil }
            return min(bounds.width / video.width, bounds.height / video.height)
        }

        /// The finger stayed put for `longPressDelay`: from now on moving drags
        /// with the button down, lifting is a secondary click.
        private func armHold() {
            guard intent == .deciding, pendingDown != nil else { return }
            intent = .held
            holdTimer = nil
            secondaryClickFeedback.impactOccurred()
        }

        private func beginFingerScroll(at location: CGPoint, time: TimeInterval) {
            intent = .scrolling
            holdTimer?.cancel()
            holdTimer = nil
            // The Mac scrolls whatever is under the pointer: put it where the
            // finger landed, once, as the two-finger pan does.
            if let p = pendingDown { receiver?.sendTouch(phase: "moved", x: p.x, y: p.y) }
            pendingDown = nil
            fingerScrollStarted = false
            // Start from here, not from the landing point, so the slop is not
            // one jump.
            lastFingerPoint = location
            fingerSamples = [(time, location)]
        }

        private func continueFingerScroll(_ touch: UITouch, _ event: UIEvent?) {
            guard let scale = videoScale() else { return }
            var dx: CGFloat = 0, dy: CGFloat = 0
            for t in event?.samples(for: touch) ?? [touch] {
                let p = t.location(in: self)
                dx += p.x - lastFingerPoint.x
                dy += p.y - lastFingerPoint.y
                lastFingerPoint = p
                fingerSamples.append((t.timestamp, p))
            }
            if let last = fingerSamples.last?.t {
                fingerSamples.removeAll { last - $0.t > 0.1 }
            }
            guard dx != 0 || dy != 0 else { return }
            // Natural direction: content follows the finger.
            receiver?.sendScroll(dx: dx / scale, dy: dy / scale,
                                 phase: fingerScrollStarted ? "changed" : "began")
            fingerScrollStarted = true
        }

        private func endFingerScroll(liftedAt time: TimeInterval?) {
            if fingerScrollStarted {
                receiver?.sendScroll(dx: 0, dy: 0, phase: "ended")
                // Velocity over the last ~0.1 s; a finger that stopped before
                // lifting has none (it set the content down, no flick).
                if let time, let scale = videoScale(),
                   let first = fingerSamples.first, let last = fingerSamples.last,
                   last.t - first.t > 0.008, time - last.t < 0.05 {
                    let dt = CGFloat(last.t - first.t)
                    startMomentum(velocity: CGPoint(x: (last.p.x - first.p.x) / dt,
                                                    y: (last.p.y - first.p.y) / dt),
                                  videoScale: scale)
                }
            }
            fingerScrollStarted = false
            fingerSamples = []
            intent = .deciding
        }

        private func sendTouchscreen(_ phase: String, _ touch: UITouch, _ norm: (x: Double, y: Double), _ event: UIEvent?) {
            let location = touch.location(in: self)
            switch phase {
            case "began":
                pendingDown = norm
                pendingDownPoint = location
                fingerDownTime = touch.timestamp
                downSent = false
                intent = .deciding
                secondaryClickFeedback.prepare()
                let work = DispatchWorkItem { [weak self] in self?.armHold() }
                holdTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay, execute: work)
            case "moved":
                let moved = hypot(location.x - pendingDownPoint.x, location.y - pendingDownPoint.y)
                switch intent {
                case .deciding:
                    if moved > dragSlop { beginFingerScroll(at: location, time: touch.timestamp) }
                case .scrolling:
                    continueFingerScroll(touch, event)
                case .held:
                    guard moved > dragSlop else { return }
                    intent = .pressing
                    commitPendingDown()
                    forwardMoves(touch, event)
                case .pressing:
                    forwardMoves(touch, event)
                }
            case "ended":
                // A lift delivered late (a gesture recognizer held it back)
                // after a short press is still a tap, not a hold.
                if intent == .held, touch.timestamp - fingerDownTime < longPressDelay {
                    intent = .deciding
                }
                switch intent {
                case .deciding:
                    // A tap: nothing was posted yet, so post the whole click now.
                    commitPendingDown()
                    if downSent { receiver?.sendTouch(phase: "ended", x: norm.x, y: norm.y) }
                case .held:
                    if let p = pendingDown {
                        press(at: p, button: "right")
                        receiver?.sendTouch(phase: "ended", x: p.x, y: p.y, button: "right")
                    }
                case .scrolling:
                    endFingerScroll(liftedAt: touch.timestamp)
                case .pressing:
                    receiver?.sendTouch(phase: "ended", x: norm.x, y: norm.y)
                }
                discardPendingDown()
            default:   // cancelled
                if intent == .scrolling { endFingerScroll(liftedAt: nil) }
                if downSent { receiver?.sendTouch(phase: "cancelled", x: norm.x, y: norm.y) }
                discardPendingDown()
            }
        }

        /// Forward every coalesced sample so the Mac gets the full-rate drag,
        /// then UIKit's predicted touch so the cursor leads toward where the
        /// finger will be (~1 frame of perceived latency back; corrected by the
        /// next real sample).
        private func forwardMoves(_ touch: UITouch, _ event: UIEvent?) {
            for t in event?.samples(for: touch) ?? [touch] {
                if let n = normalized(t.location(in: self)) {
                    lastNorm = n
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
            }
            if let predicted = event?.predictedTouches(for: touch)?.last,
               let n = normalized(predicted.location(in: self)) {
                receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
            }
        }

        private func send(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            let fingers = touches.filter { isFinger($0) }
            guard !fingers.isEmpty else { return }
            // Ignore single-finger events while a two-finger gesture runs,
            // and end the click if a second finger joins mid-press.
            if twoFingerActive || (event?.allTouches?.filter { isFinger($0) }.count ?? 1) > 1 {
                if intent == .scrolling { endFingerScroll(liftedAt: nil) }
                if downSent {
                    receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y)
                }
                discardPendingDown()
                return
            }
            guard let touch = fingers.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm

            if phase == "began" {
                touchScrolls = (receiver?.macSupportsTouchButtons ?? false)
                    && (receiver?.macSupportsScrollPhase ?? false)
            }
            if touchScrolls {
                sendTouchscreen(phase, touch, norm, event)
                return
            }

            switch phase {
            case "began":
                let location = touch.location(in: self)
                pendingDown = norm
                pendingDownPoint = location
                downSent = false
                let work = DispatchWorkItem { [weak self] in self?.commitPendingDown() }
                holdTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
                return
            case "ended":
                // A tap: nothing was posted yet, so post the whole click now.
                if pendingDown != nil, !downSent { commitPendingDown() }
                // No down means the press was already discarded (a second
                // finger took it), so there is nothing to release.
                if downSent { receiver?.sendTouch(phase: "ended", x: norm.x, y: norm.y) }
                discardPendingDown()
                return
            case "cancelled":
                if downSent {
                    receiver?.sendTouch(phase: "cancelled", x: norm.x, y: norm.y)
                }
                discardPendingDown()
                return
            case "moved":
                if pendingDown != nil, !downSent {
                    let moved = hypot(touch.location(in: self).x - pendingDownPoint.x,
                                      touch.location(in: self).y - pendingDownPoint.y)
                    // Below slop the finger is still deciding: track the cursor
                    // (the Mac turns a move without a down into mouseMoved) but
                    // keep the button up so a second finger can still cancel.
                    if moved > dragSlop { commitPendingDown() }
                }
            default:
                break
            }

            if phase == "moved" {
                forwardMoves(touch, event)
                return
            }
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
        }

        private func sendPencilAsTouch(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            guard let touch = touches.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm
            if phase == "moved" {
                forwardMoves(touch, event)
                return
            }
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
        }

        private func routeTouches(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?, ended: Bool) {
            let pencil = touches.filter { isPencil($0) }
            let finger = touches.filter { isFinger($0) }
            let usePencilWire = receiver?.macSupportsPencilWire ?? false

            if !pencil.isEmpty {
                if usePencilWire {
                    inputEngine.handle(pencil, event: event, ended: ended)
                } else {
                    sendPencilAsTouch(phase, pencil, event)
                }
            }
            // Palm rejection: ignore resting fingers while the pen is down.
            if !finger.isEmpty && !inputEngine.hasActivePen {
                send(phase, finger, event)
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            stopMomentum()
            routeTouches("began", touches, event, ended: false)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("moved", touches, event, ended: false)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("ended", touches, event, ended: true)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("cancelled", touches, event, ended: true)
        }
    }
}

extension UserDefaults {
    /// KVO-observable `VideoView.actionsButtonKey` (the property name must
    /// equal the key for UserDefaults to emit changes).
    @objc dynamic var actionsButton: Bool {
        object(forKey: VideoLayerView.VideoView.actionsButtonKey) as? Bool ?? true
    }
}

/// A button that only takes touches inside its circle, so the square's
/// corners don't steal taps meant for the desktop around it.
private final class RoundButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hypot(point.x - bounds.midX, point.y - bounds.midY) <= min(bounds.width, bounds.height) / 2
    }
}

/// CADisplayLink retains its target; this keeps the link from retaining the
/// view, so a view torn down mid-coast is not kept alive by its own momentum.
private final class MomentumTarget {
    weak var view: VideoLayerView.VideoView?
    init(_ view: VideoLayerView.VideoView) { self.view = view }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.momentumTick(link)
    }
}

// MARK: - Apple Pencil capture

/// Captures Apple Pencil hover and stroke on a host view.
/// Finger touches stay on VideoView's existing `touch` wire path.
///
/// TODO: Capture Apple Pencil Pro barrel roll (UIKit rollAngle, iOS 17.5+) once
/// hardware is available for testing.
final class InputCaptureEngine: NSObject {
    var onPencil: ((_ phase: String, _ x: Double, _ y: Double,
                    _ pressure: Double, _ azimuth: Double, _ altitude: Double) -> Void)?
    var onProximity: ((_ entering: Bool, _ x: Double, _ y: Double) -> Void)?

    /// True while at least one pen contact is on the glass (palm rejection).
    var hasActivePen: Bool { !activePens.isEmpty }

    /// Map a point in the host view to normalized video coordinates.
    var normalize: ((CGPoint) -> (x: Double, y: Double)?)?

    private weak var hostView: UIView?
    private var activePens: Set<UInt64> = []
    private var proximityActive = false

    func install(on view: UIView) {
        hostView = view
        view.isMultipleTouchEnabled = true

        // Hover tilt/azimuth on the recognizer is iOS 16.4. Pencil hover needs
        // an M2 iPad Pro or newer, which never runs anything older, so
        // skipping the recognizer below 16.4 loses nothing on those devices.
        if #available(iOS 16.4, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
            hover.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
            view.addGestureRecognizer(hover)
        }
    }

    @objc private func hoverChanged(_ gr: UIHoverGestureRecognizer) {
        guard #available(iOS 16.4, *) else { return }
        guard activePens.isEmpty, let view = hostView else { return }
        guard let n = normalize?(gr.location(in: view)) else { return }
        switch gr.state {
        case .began:
            openProximity(x: n.x, y: n.y)
            fallthrough
        case .changed:
            let azimuth = Double(gr.azimuthAngle(in: view))
            let altitude = Double(gr.altitudeAngle)
            onPencil?("hover", n.x, n.y, 0, azimuth, altitude)
        case .ended, .cancelled, .failed:
            guard activePens.isEmpty else { return }
            closeProximity(x: n.x, y: n.y)
        default:
            break
        }
    }

    func handle(_ touches: Set<UITouch>, event: UIEvent?, ended: Bool) {
        guard hostView != nil else { return }
        for touch in touches where touch.type == .pencil {
            emitPen(touch, event: event, ended: ended)
        }
    }

    private func openProximity(x: Double, y: Double) {
        guard !proximityActive else { return }
        proximityActive = true
        onProximity?(true, x, y)
    }

    private func closeProximity(x: Double, y: Double) {
        guard proximityActive else { return }
        proximityActive = false
        onProximity?(false, x, y)
    }

    private func emitPen(_ touch: UITouch, event: UIEvent?, ended: Bool) {
        guard let view = hostView else { return }
        let id = UInt64(bitPattern: Int64(ObjectIdentifier(touch).hashValue))
        let loc = touch.location(in: view)
        guard let n = normalize?(loc) else { return }
        let (nx, ny) = (n.x, n.y)

        let pressure = min(Double(touch.force), 1.0)
        let azimuth = Double(touch.azimuthAngle(in: view))
        let altitude = Double(touch.altitudeAngle)

        if !ended && !activePens.contains(id) {
            activePens.insert(id)
            openProximity(x: nx, y: ny)
            emitPencil("down", x: nx, y: ny, pressure: pressure,
                       azimuth: azimuth, altitude: altitude)
            return
        }

        if !ended {
            for c in event?.samples(for: touch) ?? [touch] {
                guard let cn = normalize?(c.location(in: view)) else { continue }
                emitPencil("move", x: cn.x, y: cn.y,
                           pressure: min(Double(c.force), 1.0),
                           azimuth: Double(c.azimuthAngle(in: view)),
                           altitude: Double(c.altitudeAngle))
            }
            return
        }

        defer { activePens.remove(id) }
        emitPencil("up", x: nx, y: ny, pressure: 0,
                   azimuth: azimuth, altitude: altitude)
        closeProximity(x: nx, y: ny)
    }

    private func emitPencil(_ phase: String, x: Double, y: Double,
                            pressure: Double, azimuth: Double, altitude: Double) {
        onPencil?(phase, x, y, pressure, azimuth, altitude)
    }
}
