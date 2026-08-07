// Send to Mac (issue #122, iPad -> Mac): the reverse direction. This screen
// discovers Macs advertising ReverseWire.serviceType, lets the user pick one,
// and hosts the system broadcast picker that starts the ReplayKit extension.
//
// The actual capture + streaming happens in the broadcast extension (its own
// process — see Broadcast/SampleHandler.swift); this view and the extension
// meet in the app-group defaults: we write the chosen Mac and device name,
// the extension writes its status back.

import Network
import ReplayKit
import SwiftUI

/// Discovers Macs that have "Receive from iPad / iPhone" enabled.
final class MacReceiverBrowser: ObservableObject {
    @Published var macs: [String] = []

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: ReverseWire.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }.sorted()
            DispatchQueue.main.async { self?.macs = names }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

struct SendToMacView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = MacReceiverBrowser()
    @State private var targetName: String?
    @State private var broadcastStatus = ""
    // The extension has no UI of its own — poll the status it mirrors into
    // the app group while this screen is visible.
    private let statusTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var groupDefaults: UserDefaults? { UserDefaults(suiteName: ReverseWire.appGroup) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("This mirrors your \(deviceKind)'s screen into a window on the Mac. macOS apps can't act as a true external display for iPadOS, so it's view-only — keep using the \(deviceKind) by touch.",
                          systemImage: "info.circle")
                        .font(.subheadline)
                }

                Section {
                    if browser.macs.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for Macs…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.macs, id: \.self) { name in
                        Button {
                            targetName = name
                            groupDefaults?.set(name, forKey: ReverseWire.targetNameKey)
                        } label: {
                            HStack {
                                Label(name, systemImage: "desktopcomputer")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if isSelected(name) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Send to")
                } footer: {
                    Text("Macs appear here when the OpenDisplay Mac app is running with “Receive from iPad / iPhone” enabled, on the same WiFi network.")
                }

                Section {
                    HStack(spacing: 16) {
                        BroadcastPicker()
                            .frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start / stop broadcasting")
                            Text("iOS asks for confirmation, then everything on this \(deviceKind)'s screen streams to the Mac — including notifications.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if !broadcastStatus.isEmpty {
                        Text(broadcastStatus)
                    }
                }
            }
            .navigationTitle("\(deviceKind) → Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            browser.start()
            targetName = groupDefaults?.string(forKey: ReverseWire.targetNameKey)
            // Hand the user-chosen device name to the extension — iOS gives
            // extensions the same generic UIDevice name it gives the app.
            let savedName = UserDefaults.standard.string(forKey: "deviceName")
            if let savedName, !savedName.isEmpty {
                groupDefaults?.set(savedName, forKey: "deviceName")
            }
        }
        .onDisappear { browser.stop() }
        .onReceive(statusTicker) { _ in
            broadcastStatus = groupDefaults?.string(forKey: ReverseWire.statusKey) ?? ""
        }
    }

    /// The row that will be dialed: the explicit selection, or the only Mac.
    private func isSelected(_ name: String) -> Bool {
        if let targetName, browser.macs.contains(targetName) { return name == targetName }
        return browser.macs.count == 1
    }
}

/// The system broadcast picker, pinned to our extension so the sheet doesn't
/// list every broadcast app on the device.
private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
