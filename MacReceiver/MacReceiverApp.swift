// OpenDisplay Receiver — run this on a spare Mac (an iMac gathering dust, an
// old MacBook) to turn it into a second monitor for another Mac running the
// OpenDisplay sender app. Speaks the same wire protocol as the iOS receiver,
// so the sender needs no changes: this Mac shows up in its device list like
// an iPhone would, over WiFi or wired LAN (Ethernet / Thunderbolt bridge).

import SwiftUI
import AVFoundation
import AppKit
import Combine

@main
struct MacReceiverApp: App {
    @NSApplicationDelegateAdaptor(ReceiverAppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single window (no Cmd+N): the display layer can only live in one
        // view, so a second window would steal the video from the first.
        Window("OpenDisplay Receiver", id: "main") {
            ReceiverRootView()
        }
        .commands {
            CommandMenu("Receiver") {
                PerfHUDToggle()
            }
        }
    }
}

/// Menu item bound to the HUD preference so it stays reachable while the
/// video covers the whole screen.
private struct PerfHUDToggle: View {
    @AppStorage("showAnalytics") private var showAnalytics = false

    var body: some View {
        Toggle("Performance HUD", isOn: $showAnalytics)
            .keyboardShortcut("i", modifiers: [.command])
    }
}

final class ReceiverAppDelegate: NSObject, NSApplicationDelegate {
    /// Announce "closing" before dying so the sender tears the session down
    /// immediately instead of waiting out its silence grace. shutDown's
    /// internal 1s deadline guarantees the completion fires even on a dead
    /// link, so this can never hang the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ReceiverModel.shared.receiver.shutDown {
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Model

@MainActor
final class ReceiverModel: ObservableObject {
    static let shared = ReceiverModel()

    let receiver: DisplayReceiver
    // The hosting window, once known — panel announcements follow the screen
    // this window actually sits on, not whichever screen owns the menu bar.
    weak var window: NSWindow? {
        didSet { if window !== oldValue { applyPanel() } }
    }
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var distObservers: [NSObjectProtocol] = []
    private var lastWindowColorDescription = ""
    // Keeps the panel awake while a sender is connected — a second monitor
    // that falls asleep mid-use isn't one. (The iOS app's isIdleTimerDisabled.)
    private var activityToken: NSObjectProtocol?

    /// The virtual display is always HiDPI: announced pixels / 2 become its
    /// logical point size. Read CGDisplayMode.pixelWidth/pixelHeight rather
    /// than NSScreen.frame so a 24-inch 4.5K iMac announces 4480×2520 even
    /// though macOS exposes its default desktop as 2240×1260 logical points.

    init() {
        receiver = DisplayReceiver(displayLayer: AVSampleBufferDisplayLayer())
        let savedName = UserDefaults.standard.string(forKey: "deviceName")
        if let savedName, !savedName.isEmpty { receiver.serviceName = savedName }
        receiver.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        receiver.$connected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.setKeepAwake(connected)
            }
            .store(in: &cancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        applyPanel()
        receiver.start(port: 9000)

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyPanel() }
        })
        // A user can change the active ICC profile without changing the
        // display mode. Keep both the announced stream gamut and AppKit's
        // window backing store synchronized with the new profile.
        observers.append(center.addObserver(
            forName: NSScreen.colorSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyPanel() }
        })
        // The window moving to another display changes which panel we should
        // announce (multi-monitor spare Macs).
        observers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, note.object as? NSWindow === self.window else { return }
                self.applyPanel()
            }
        })

        // Sleep = the panel goes dark — announce it (the sender drops the
        // virtual display so the cursor isn't stranded) and stop accepting
        // until the screen is back. The Mac analogue of the iOS device lock.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                Log.info("sleeping (\(name.rawValue))")
                Task { @MainActor in self?.receiver.enterSleep() }
            })
        }
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     // Fast user switching back in: our session is visible again.
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                Log.info("awake (\(name.rawValue))")
                Task { @MainActor in self?.receiver.ensureListening() }
            })
        }
        // Fast user switching away: the stream is hidden behind another
        // user's session (which keeps the panel awake, so screensDidSleep
        // never fires) — announce sleeping like a lock would.
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            Log.info("session resigned (fast user switch) — sleeping")
            Task { @MainActor in self?.receiver.enterSleep() }
        })

        // Screen lock (Ctrl⌘Q / idle lock) hides the stream without any
        // workspace sleep notification — the direct analogue of the iOS
        // device lock, delivered only on the distributed center. enterSleep/
        // ensureListening are idempotent, so overlap with the sleep/wake
        // pair above is harmless.
        let dist = DistributedNotificationCenter.default()
        distObservers.append(dist.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in
            Log.info("screen locked — sleeping")
            Task { @MainActor in self?.receiver.enterSleep() }
        })
        distObservers.append(dist.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] _ in
            Log.info("screen unlocked — re-arming listener")
            Task { @MainActor in self?.receiver.ensureListening() }
        })
    }

    /// Announce this screen's size (see maxEncodePixels). The user's density
    /// setting scales the announcement down: fewer announced pixels → a
    /// smaller virtual display in points → larger UI.
    func applyPanel() {
        guard let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        syncWindowColorSpace(to: screen)
        let density = UserDefaults.standard.double(forKey: "announceScale")
        let user = density > 0 ? density : 1.0
        let displayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
        let mode = displayID.flatMap(CGDisplayCopyDisplayMode)
        let backing = screen.backingScaleFactor
        let nativeWidth = mode?.pixelWidth ?? Int(screen.frame.width * backing)
        let nativeHeight = mode?.pixelHeight ?? Int(screen.frame.height * backing)
        let w = Double(nativeWidth) * user
        let h = Double(nativeHeight) * user
        let profileName = screen.colorSpace?.localizedName
        let workingColorSpace = ICCProfileGamut.preferredWorkingSpace(
            profileData: screen.colorSpace?.iccProfileData,
            name: profileName)
        Log.info("panel mode: logical=\(Int(screen.frame.width))x\(Int(screen.frame.height)) "
            + "backing=\(backing)x native=\(nativeWidth)x\(nativeHeight) density=\(user) "
            + "ICC=\(profileName ?? "unnamed") streamColor=\(workingColorSpace.rawValue)")
        receiver.setPanel(pixelsWide: Int(w) & ~1, pixelsHigh: Int(h) & ~1,
                          scale: 2, colorSpace: workingColorSpace,
                          iccProfileData: screen.colorSpace?.iccProfileData)
    }

    /// AppKit otherwise creates the window backing store in its default RGB
    /// space. That intermediate can clip Display P3 before Core Animation has
    /// a chance to map the Metal layer to the receiving iMac's active ICC
    /// profile. Make the backing store use the exact current screen profile.
    private func syncWindowColorSpace(to screen: NSScreen) {
        guard let window, let target = screen.colorSpace else {
            receiver.setDestinationColorDiagnostic("window-or-screen-profile-unavailable")
            return
        }
        let previous = window.colorSpace
        let matchedBefore = previous?.iccProfileData == target.iccProfileData
        if !matchedBefore { window.colorSpace = target }

        let applied = window.colorSpace
        let matchedAfter = applied?.iccProfileData == target.iccProfileData
        let targetName = target.localizedName ?? "unnamed"
        let windowName = applied?.localizedName ?? "unnamed"
        let targetBytes = target.iccProfileData?.count ?? 0
        let windowBytes = applied?.iccProfileData?.count ?? 0
        if let targetCGColorSpace = target.cgColorSpace {
            receiver.metalRenderer?.setDestinationColorSpace(
                targetCGColorSpace,
                description: "\(targetName)|\(targetBytes)B")
        }
        let description = "window=\(windowName)|\(windowBytes)B|display="
            + "\(targetName)|\(targetBytes)B|match=\(matchedAfter)"
        receiver.setDestinationColorDiagnostic(description)
        guard description != lastWindowColorDescription else { return }
        lastWindowColorDescription = description
        Log.info("ColorSync window target: \(description)"
            + (matchedBefore ? "" : " (updated)"))
    }

    private func setKeepAwake(_ on: Bool) {
        if on, activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Streaming as a second display")
        } else if !on, let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
}

// MARK: - Root view

struct ReceiverRootView: View {
    @ObservedObject private var model = ReceiverModel.shared
    @StateObject private var fullscreen = FullscreenCoordinator()
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("autoFullscreen") private var autoFullscreen = true

    // Streaming = connected and the video format is known.
    private var isStreaming: Bool {
        model.receiver.connected && model.receiver.videoSize != .zero
    }

    var body: some View {
        ZStack {
            if isStreaming {
                Color.black.ignoresSafeArea()
                VideoHostView(displayLayer: model.receiver.displayLayer,
                              receiver: model.receiver)
                    .ignoresSafeArea()
                if showAnalytics {
                    VStack {
                        Spacer()
                        PerfHUD(stats: model.receiver.perf,
                                videoSize: model.receiver.videoSize)
                            .padding(.bottom, 10)
                    }
                    .allowsHitTesting(false)   // never block mouse input
                }
                // A compatibility demand from the sender must survive the
                // idle view being swapped out (the iOS app gates the stream
                // with a cover; a banner is the lightweight equivalent).
                if let message = model.receiver.peerMessage {
                    VStack {
                        Text(message)
                            .font(.callout.bold())
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.red.opacity(0.85),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 12)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            } else {
                IdleView(model: model)
            }
        }
        .background(WindowAccessor { window in
            model.window = window
            fullscreen.attach(window)
        })
        .onChange(of: isStreaming) { _, streaming in
            fullscreen.streamingChanged(streaming, autoFullscreen: autoFullscreen)
        }
        .onAppear { model.start() }
        .navigationTitle("OpenDisplay Receiver")
        .frame(minWidth: 520, minHeight: 460)
    }
}

/// Drives native fullscreen from streaming state. NSWindow fullscreen
/// transitions animate for ~1s and AppKit silently drops toggleFullScreen
/// calls made mid-transition — so this tracks the transition via the window
/// notifications and reconciles a *desired* state once each transition
/// settles, instead of firing one-shot toggles against a styleMask snapshot
/// (which strands the idle view fullscreen when a sender disconnects during
/// the enter animation). Only fullscreen WE entered is auto-exited: a user
/// who fullscreened manually keeps their window state when the stream ends.
@MainActor
final class FullscreenCoordinator: ObservableObject {
    private weak var window: NSWindow?
    private var transitioning = false
    private var desired: Bool?          // pending target; nil = settled
    private var autoEntered = false
    private var generation = 0          // guards the stuck-transition rescue
    private var tokens: [NSObjectProtocol] = []

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.collectionBehavior.insert(.fullScreenPrimary)
        let nc = NotificationCenter.default
        tokens.forEach(nc.removeObserver)
        let starting: [Notification.Name] = [NSWindow.willEnterFullScreenNotification,
                                             NSWindow.willExitFullScreenNotification]
        let settledEnter = NSWindow.didEnterFullScreenNotification
        let settledExit = NSWindow.didExitFullScreenNotification
        tokens = starting.map { name in
            nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.transitioning = true }
            }
        }
        tokens.append(nc.addObserver(forName: settledEnter, object: window, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.settled(fullscreen: true) }
        })
        tokens.append(nc.addObserver(forName: settledExit, object: window, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.settled(fullscreen: false) }
        })
        reconcile()   // a stream may have started before the window was known
    }

    func streamingChanged(_ streaming: Bool, autoFullscreen: Bool) {
        if streaming {
            desired = autoFullscreen ? true : nil
        } else {
            desired = autoEntered ? false : nil
        }
        reconcile()
    }

    private func reconcile() {
        guard !transitioning, let window, let want = desired else { return }
        let isFullscreen = window.styleMask.contains(.fullScreen)
        guard want != isFullscreen else {
            desired = nil
            return
        }
        if want { autoEntered = true }
        transitioning = true
        generation += 1
        let expected = generation
        window.toggleFullScreen(nil)
        // AppKit can swallow a toggle without any notification (e.g. issued
        // in a dead spot right after a transition) — don't stay wedged.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.generation == expected, self.transitioning else { return }
            Log.info("fullscreen transition never settled — reconciling")
            self.transitioning = false
            self.reconcile()
        }
    }

    private func settled(fullscreen: Bool) {
        transitioning = false
        generation += 1
        if let want = desired {
            if want == fullscreen {
                desired = nil
            } else {
                reconcile()   // e.g. the stream ended mid-enter: now leave
            }
        } else {
            // A transition we didn't request is the user's own toggle — from
            // here on, their choice owns the window state.
            autoEntered = false
        }
    }
}

/// Grabs the hosting NSWindow so streaming can drive native fullscreen.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { onWindow(window) }
        }
    }
}

// MARK: - Idle view (no sender connected)

struct IdleView: View {
    @ObservedObject var model: ReceiverModel
    @AppStorage("deviceName") private var deviceName =
        Host.current().localizedName ?? "Mac"
    @AppStorage("announceScale") private var announceScale = 1.0
    @AppStorage("autoFullscreen") private var autoFullscreen = true
    @AppStorage("showAnalytics") private var showAnalytics = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 6) {
                Text("OpenDisplay Receiver")
                    .font(.largeTitle.bold())
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.receiver.connected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.receiver.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let message = model.receiver.peerMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Run the OpenDisplay app on the Mac whose screen you want to extend",
                      systemImage: "macbook")
                Label("Both Macs on the same network — WiFi, Ethernet, or a Thunderbolt bridge",
                      systemImage: "network")
                Label("Pick this Mac in the sender's device list — streaming starts automatically",
                      systemImage: "play.circle")
            }
            .font(.subheadline)
            .padding(18)
            .frame(maxWidth: 460)
            .background(.quaternary.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 14))

            Form {
                TextField("Name", text: $deviceName)
                    .onChange(of: deviceName) { _, name in
                        model.receiver.setServiceName(name)
                    }
                    .help("Shown in the sender's device list.")
                Picker("Text size", selection: $announceScale) {
                    Text("Match this display").tag(1.0)
                    Text("Larger").tag(0.75)
                    Text("Largest").tag(0.5)
                }
                .onChange(of: announceScale) { model.applyPanel() }
                .help("Larger sizes announce a smaller virtual display, so everything on it is bigger — and cheaper to stream.")
                Toggle("Enter fullscreen while streaming", isOn: $autoFullscreen)
                Toggle("Performance HUD (⌘I)", isOn: $showAnalytics)
            }
            .formStyle(.columns)
            .frame(maxWidth: 460)

            Spacer(minLength: 8)

            Text("v\(version) · same LAN, port 9000 · github.com/peetzweg/opendisplay")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Performance HUD (compact cousin of the iOS overlay)

struct PerfHUD: View {
    let stats: PerfStats
    let videoSize: CGSize

    var body: some View {
        HStack(spacing: 14) {
            Text(stats.transport)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(stats.transport == "WiFi" ? Color.blue.opacity(0.4)
                            : Color.gray.opacity(0.3),
                            in: Capsule())
                .foregroundStyle(.white)
            if stats.e2eP50 > 0 {
                metric("latency", String(format: "%.0f ms", stats.e2eP50))
                metric("p95", String(format: "%.0f ms", stats.e2eP95))
                metric("encode", String(format: "%.0f ms", stats.encodeP50))
            }
            if stats.inputP50 > 0 {
                metric("input", String(format: "%.0f ms", stats.inputP50))
            }
            metric("rtt", String(format: "%.0f ms", stats.rttMs))
            metric("FPS", "\(stats.fps)")
            if stats.capFps > 0 {
                metric("sender cap", "\(stats.capFps)")
            }
            metric("Mbit/s", String(format: "%.1f", stats.mbps))
            metric("stalls", "\(stats.stalls)")
            if stats.macDrops > 0 {
                metric("drops", "\(stats.macDrops)")
            }
            metric("res", "\(Int(videoSize.width))×\(Int(videoSize.height))")
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
}
