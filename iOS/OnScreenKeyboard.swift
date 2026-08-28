import SwiftUI
import UIKit

struct OnScreenKeyboard: View {

    let receiver: PhoneReceiver

    /// Caps Lock is a two-state latch: off by default, tap to turn on/off.
    /// Sent via the shared sticky-modifier bits (alphaShift = 1 << 16).
    @State private var capsOn = false

    private let rows: [[KeyboardKey]] = [
        [
            KeyboardKey(title: "Esc", code: 0x29),
            KeyboardKey(title: "1", code: 0x1E),
            KeyboardKey(title: "2", code: 0x1F),
            KeyboardKey(title: "3", code: 0x20),
            KeyboardKey(title: "4", code: 0x21),
            KeyboardKey(title: "5", code: 0x22),
            KeyboardKey(title: "6", code: 0x23),
            KeyboardKey(title: "7", code: 0x24),
            KeyboardKey(title: "8", code: 0x25),
            KeyboardKey(title: "9", code: 0x26),
            KeyboardKey(title: "0", code: 0x27),
            KeyboardKey(title: "-", code: 0x2D),
            KeyboardKey(title: "=", code: 0x2E),
            KeyboardKey(title: "⌫", code: 0x2A)
        ],
        [
            KeyboardKey(title: "Tab", code: 0x2B),
            KeyboardKey(title: "Q", code: 0x14),
            KeyboardKey(title: "W", code: 0x1A),
            KeyboardKey(title: "E", code: 0x08),
            KeyboardKey(title: "R", code: 0x15),
            KeyboardKey(title: "T", code: 0x17),
            KeyboardKey(title: "Y", code: 0x1C),
            KeyboardKey(title: "U", code: 0x18),
            KeyboardKey(title: "I", code: 0x0C),
            KeyboardKey(title: "O", code: 0x12),
            KeyboardKey(title: "P", code: 0x13),
            KeyboardKey(title: "[", code: 0x2F),
            KeyboardKey(title: "]", code: 0x30),
            KeyboardKey(title: "\\", code: 0x31)
        ],
        [
            KeyboardKey(title: "Caps", code: 0x39),
            KeyboardKey(title: "A", code: 0x04),
            KeyboardKey(title: "S", code: 0x16),
            KeyboardKey(title: "D", code: 0x07),
            KeyboardKey(title: "F", code: 0x09),
            KeyboardKey(title: "G", code: 0x0A),
            KeyboardKey(title: "H", code: 0x0B),
            KeyboardKey(title: "J", code: 0x0D),
            KeyboardKey(title: "K", code: 0x0E),
            KeyboardKey(title: "L", code: 0x0F),
            KeyboardKey(title: ";", code: 0x33),
            KeyboardKey(title: "'", code: 0x34),
            KeyboardKey(title: "Enter", code: 0x28)
        ],
        [
            KeyboardKey(title: "Z", code: 0x1D),
            KeyboardKey(title: "X", code: 0x1B),
            KeyboardKey(title: "C", code: 0x06),
            KeyboardKey(title: "V", code: 0x19),
            KeyboardKey(title: "B", code: 0x05),
            KeyboardKey(title: "N", code: 0x11),
            KeyboardKey(title: "M", code: 0x10),
            KeyboardKey(title: ",", code: 0x36),
            KeyboardKey(title: ".", code: 0x37),
            KeyboardKey(title: "/", code: 0x38)
        ],
        // No modifier keys here — ⌘ / ⌥ / ⌃ / ⇧ live in the sidebar (ModifierSidebarView),
        // which sends latched/sticky modifiers via sendStickyModifiers. The keyboard's own
        // momentary modifier taps posted *real* physical modifier keypresses on the Mac,
        // which fought with the sidebar's sticky state.
        [
            // Arrows removed per request — the whole bottom row is one wide space bar.
            KeyboardKey(title: "Space", code: 0x2C)
        ]
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 5) {
                    ForEach(rows[rowIndex]) { key in
                        KeyboardButton(key: key, isActive: key.code == 0x39 && capsOn) {
                            press(key)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // Re-assert latched modifiers on (re)connect — a new Mac session starts
        // with cleared sticky state, so the keyboard's Caps latch would otherwise
        // look on while the Mac ignores it.
        .onChange(of: receiver.connected) { connected in
            if connected { receiver.sendStickyModifiers(receiver.latchedModifierFlags) }
        }
    }

    private func press(_ key: KeyboardKey) {
        // Caps Lock is a latch (like the sidebar modifiers), not a momentary key:
        // toggle the alphaShift sticky bit on/off and skip the key event.
        guard key.code != 0x39 else {
            capsOn = receiver.toggleLatchedModifier(1 << 16)
            return
        }

        // Letters are sent in lowercase. The Mac inserts `char` verbatim when no
        // modifier flag is active, so sending the uppercase label would always
        // produce capitals. Uppercase comes from the caps/shift sticky flag
        // instead (the Mac maps those key events by keycode + flag).
        let char = key.title.count == 1 ? key.title.lowercased() : nil

        // mod is always 0 here: modifiers come exclusively from the sticky flags,
        // which the Mac merges into every key/tap event.
        receiver.sendKey(
            code: key.code,
            down: true,
            mod: 0,
            char: char
        )

        receiver.sendKey(
            code: key.code,
            down: false,
            mod: 0,
            char: char
        )
    }
}

private struct KeyboardKey: Identifiable {
    let id = UUID()
    let title: String
    let code: Int
    var width: CGFloat = 1.0
}

private struct KeyboardButton: View {
    let key: KeyboardKey
    let action: () -> Void
    var isActive = false

    var body: some View {
        Button(action: action) {
            Text(key.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(isActive ? Color.blue : Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .frame(maxWidth: .infinity)
    }
}

