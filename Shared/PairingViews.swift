// Receiver-side pairing UI (issue #16), shared by the iOS app and the Mac
// receiver: the code a sender waits for, and the list of paired senders.
// SwiftUI only, no UIKit/AppKit.

import SwiftUI

/// The code to type on the other Mac, large enough to read across a desk.
struct PairingCodeCard: View {
    let prompt: PairingListener.Prompt

    private var spacedCode: String {
        let code = prompt.code
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            Text("Pair with “\(prompt.senderName)”")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Enter this code on \(prompt.senderName):")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text(spacedCode)
                .font(.system(size: 56, weight: .semibold, design: .monospaced))
                .accessibilityLabel(prompt.code.map(String.init).joined(separator: " "))
                .padding(.vertical, 4)
            Text("Pairing once lets that Mac connect over Wi-Fi encrypted. "
                 + "If you didn't start this, ignore it: nothing is shared without the code.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(28)
        .frame(maxWidth: 460)
    }
}

/// Full-window overlay version for when the receiver shows its idle screen
/// or video: dims what is behind the card.
struct PairingCodeOverlay: View {
    @ObservedObject var receiver: StreamReceiver

    var body: some View {
        if let prompt = receiver.pairingPrompt {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                PairingCodeCard(prompt: prompt)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.platformBackground))
                    .padding(24)
            }
            .transition(.opacity)
        } else if let notice = receiver.pairedNotice {
            VStack {
                Label(notice, systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.platformBackground))
                    .padding(.top, 24)
                Spacer()
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// "Paired Macs" with a Forget per row, for a settings Form.
struct PairedSendersSection: View {
    @ObservedObject var receiver: StreamReceiver

    var body: some View {
        Section {
            if receiver.pairedSenders.isEmpty {
                Text("None yet. A Mac pairs the first time it connects over Wi-Fi: this screen shows a code to type there.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(receiver.pairedSenders, id: \.id) { sender in
                HStack {
                    Label(sender.name, systemImage: "lock.laptopcomputer")
                    Spacer()
                    Button("Forget") { receiver.forget(senderID: sender.id) }
                        .foregroundColor(.red)
                }
            }
        } header: {
            Text("Paired Macs")
        } footer: {
            Text(receiver.encrypted
                 ? "The current connection is encrypted."
                 : "Paired Macs connect over Wi-Fi encrypted. A Mac that can't pair (an older version) connects unencrypted, and only after its user confirms that.")
        }
    }
}

extension Color {
    static var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }
}
