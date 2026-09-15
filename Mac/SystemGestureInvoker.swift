import ApplicationServices
import CoreGraphics

/// Invokes built-in macOS system gestures through synthetic keyboard shortcuts.
@MainActor
enum SystemGestureInvoker {
    static func invoke(_ gesture: ReceiverGesture) {
        post(SystemGestureShortcutMapping.shortcut(for: gesture),
             description: gesture.rawValue)
    }

    private static func post(_ shortcut: SystemGestureShortcut, description: String) {
        guard AXIsProcessTrusted() else {
            Log.info("System gesture skipped: Accessibility permission is missing")
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.info("System gesture skipped: could not create CGEvent source")
            return
        }

        guard let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: shortcut.keyCode,
                                    keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: shortcut.keyCode,
                                  keyDown: false) else {
            Log.info("System gesture skipped: could not create key events for \(description)")
            return
        }

        keyDown.flags = shortcut.flags
        keyUp.flags = shortcut.flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
