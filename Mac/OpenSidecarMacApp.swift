import SwiftUI
import Network

@main
struct OpenSidecarMacApp: App {
    @StateObject private var controller = SenderController()

    var body: some Scene {
        WindowGroup("OpenSidecar") {
            ContentView(controller: controller)
        }
        .windowResizability(.contentSize)
    }
}

enum ConnectionTarget: Hashable {
    case usb                          // iproxy tunnel on localhost
    case wifi(NWBrowser.Result)       // discovered via Bonjour

    var label: String {
        switch self {
        case .usb:
            return "USB (wired)"
        case .wifi(let result):
            if case .service(let name, _, _, _) = result.endpoint { return "\(name) (WiFi)" }
            return "WiFi device"
        }
    }
}

@MainActor
final class SenderController: ObservableObject {
    @Published var status = "Idle"
    @Published var framesSent = 0
    @Published var mbps = 0.0
    @Published var running = false
    @Published var discovered: [NWBrowser.Result] = []
    @Published var target: ConnectionTarget = .usb
    // `-host x.x.x.x` / `-port n` override the USB tunnel endpoint.
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1"
    @Published var port = UserDefaults.standard.string(forKey: "port") ?? "9000"
    // `-mode mirror` / `-mode extend` launch argument also works.
    @Published var mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .extend

    private var sender: MacSender?
    private var browser: NWBrowser?

    init() {
        startBrowsing()
        // Auto-start unless explicitly disabled (`-autostart NO`).
        if UserDefaults.standard.object(forKey: "autostart") == nil
            || UserDefaults.standard.bool(forKey: "autostart") {
            start()
        }
    }

    private func startBrowsing() {
        let browser = NWBrowser(for: .bonjour(type: "_opensidecar._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.discovered = Array(results)
                self.reselectSavedTarget()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// The connection choice survives relaunches: if the user last used a
    /// WiFi device, re-select it as soon as discovery finds it again.
    private func reselectSavedTarget() {
        guard case .usb = target,
              let saved = UserDefaults.standard.string(forKey: "lastTarget"),
              saved != "usb" else { return }
        for result in discovered {
            if case .service(let name, _, _, _) = result.endpoint, name == saved {
                target = .wifi(result)
                restartIfRunning()
                return
            }
        }
    }

    func rememberTarget() {
        switch target {
        case .usb:
            UserDefaults.standard.set("usb", forKey: "lastTarget")
        case .wifi(let result):
            if case .service(let name, _, _, _) = result.endpoint {
                UserDefaults.standard.set(name, forKey: "lastTarget")
            }
        }
    }

    func start() {
        guard !running else { return }
        let endpoint: NWEndpoint
        switch target {
        case .usb:
            guard let portNum = UInt16(port) else { return }
            endpoint = .hostPort(host: NWEndpoint.Host(host),
                                 port: NWEndpoint.Port(rawValue: portNum)!)
        case .wifi(let result):
            endpoint = result.endpoint
        }

        running = true
        status = "Starting…"
        let sender = MacSender(endpoint: endpoint, name: target.label, mode: mode)
        sender.onStatus = { [weak self] text in
            self?.status = text
            Log.info("status: \(text)")
        }
        sender.onStats = { [weak self] frames, mbps in
            self?.framesSent = frames
            self?.mbps = mbps
        }
        self.sender = sender
        Task {
            do {
                try await sender.start()
            } catch {
                Log.info("sender failed to start: \(error)")
                self.status = "Failed: \(error.localizedDescription)"
                self.running = false
            }
        }
    }

    func stop() {
        sender?.stop()
        sender = nil
        running = false
        status = "Stopped"
    }

    func restartIfRunning() {
        if running {
            stop()
            start()
        }
    }
}

/// Polls the permission states the app depends on so the UI can surface
/// exactly what's missing instead of failing silently.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published var screenRecording = false
    @Published var accessibility = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: SenderController
    @StateObject private var permissions = PermissionMonitor()

    private var statusColor: Color {
        if !controller.running { return .secondary.opacity(0.5) }
        if controller.status.hasPrefix("Extending") || controller.status.hasPrefix("Mirroring") {
            return .green
        }
        if controller.status.hasPrefix("Failed") || controller.status.contains("stopped") {
            return .red
        }
        return .orange
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenSidecar")
                        .font(.title3.bold())
                    Text("Your iPhone as a second display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(controller.running ? "Stop" : "Start") {
                    controller.running ? controller.stop() : controller.start()
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            // Settings
            Form {
                Picker("Connection", selection: $controller.target) {
                    Text(ConnectionTarget.usb.label).tag(ConnectionTarget.usb)
                    ForEach(controller.discovered, id: \.self) { result in
                        Text(ConnectionTarget.wifi(result).label)
                            .tag(ConnectionTarget.wifi(result))
                    }
                }
                .onChange(of: controller.target) {
                    controller.rememberTarget()
                    controller.restartIfRunning()
                }

                Picker("Mode", selection: $controller.mode) {
                    Text("Extend").tag(CaptureMode.extend)
                    Text("Mirror").tag(CaptureMode.mirror)
                }
                .pickerStyle(.segmented)
                .onChange(of: controller.mode) { controller.restartIfRunning() }

                Section("Permissions") {
                    permissionRow(
                        "Screen Recording",
                        granted: permissions.screenRecording,
                        help: "Required to capture the display.",
                        anchor: "Privacy_ScreenCapture"
                    )
                    permissionRow(
                        "Accessibility",
                        granted: permissions.accessibility,
                        help: "Required for touch input from the phone.",
                        anchor: "Privacy_Accessibility"
                    )
                    // macOS offers no API to query Local Network access, so
                    // infer from discovery results and let the user check.
                    permissionRow(
                        "Local Network",
                        granted: !controller.discovered.isEmpty,
                        uncertain: controller.discovered.isEmpty,
                        help: "Required for WiFi mode. If no device appears in the Connection menu, allow OpenSidecar under Privacy & Security → Local Network on this Mac AND on the iPhone — and keep the iPhone app open.",
                        anchor: "Privacy_LocalNetwork"
                    )
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Spacer(minLength: 0)

            Divider()

            // Status bar
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(controller.status)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if controller.running, controller.mbps > 0 {
                    Text("\(String(format: "%.1f", controller.mbps)) Mbit/s")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 440)
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, uncertain: Bool = false,
                               help: String, anchor: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: uncertain ? "questionmark.circle.fill"
                            : granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(uncertain ? .orange : granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if uncertain || !granted {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if uncertain || !granted {
                Button("Open Settings") {
                    PermissionMonitor.openPrivacyPane(anchor)
                }
                .controlSize(.small)
            }
        }
    }
}
