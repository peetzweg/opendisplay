// Send this device's screen to another iPad/iPhone (issue #123). The app only
// picks the target and hands it to the broadcast extension via app-group
// defaults — the actual capture/encode/stream pipeline lives in the extension
// (Broadcast/BroadcastSender.swift), because system-wide capture on iOS only
// exists there.

import SwiftUI
import Network
import ReplayKit

/// Discovers other OpenDisplay receivers over Bonjour. Excludes this device
/// by its own advertised service name — the browser sees our own listener
/// too, and streaming to yourself is a hall of mirrors. (TXT records with the
/// install id would be more precise, but NWBrowser often omits them — the
/// same reason the Mac's WiFi picker matches by name.)
final class ReceiverBrowser: ObservableObject {
    @Published var names: [String] = []
    private var browser: NWBrowser?
    private var ownName = ""

    func start(excluding own: String) {
        ownName = own
        stop()
        let params = NWParameters()
        // Match the sender's dial parameters: with peer-to-peer on both, two
        // iPads with no shared WiFi can still find each other over AWDL.
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_opensidecar._tcp", domain: nil),
                                using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let names = results.compactMap { result -> String? in
                guard case let .service(name, _, _, _) = result.endpoint,
                      name != self.ownName else { return nil }
                return name
            }
            let sorted = Array(Set(names)).sorted()
            DispatchQueue.main.async { self.names = sorted }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

struct SendScreen: View {
    @ObservedObject var receiver: PhoneReceiver
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = ReceiverBrowser()
    @State private var target = BroadcastTarget.serviceName

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if browser.names.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for OpenDisplay devices…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.names, id: \.self) { name in
                        Button {
                            target = name
                            BroadcastTarget.serviceName = name
                        } label: {
                            HStack {
                                Label(name, systemImage: "ipad.landscape")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if name == target {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Send to")
                } footer: {
                    Text("Open OpenDisplay on the other iPad or iPhone — it appears here when both devices are on the same WiFi or near each other.")
                }

                Section {
                    HStack(spacing: 12) {
                        BroadcastPickerButton()
                            .frame(width: 44, height: 44)
                        Text(target == nil ? "Choose a device above first"
                                           : "Start mirroring to “\(target!)”")
                            .foregroundStyle(target == nil ? .secondary : .primary)
                    }
                } footer: {
                    Text("Your entire screen is mirrored — everything you see, in every app — until you stop it from the red indicator in the status bar. Mirroring is view-only: touches on the other device are not sent back.")
                }
            }
            .navigationTitle("Send Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { browser.start(excluding: receiver.serviceName) }
            .onDisappear { browser.stop() }
        }
    }
}

/// The system's broadcast start/stop button. There is no API to start a
/// broadcast programmatically — this picker (or Control Center) is the only
/// entry point, so the row hosts the real control rather than imitating one.
private struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        // Pin the sheet to our extension so unrelated broadcast services
        // (other screen-recording apps) aren't offered.
        picker.preferredExtension = BroadcastTarget.extensionBundleID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
