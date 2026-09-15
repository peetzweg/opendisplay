import CoreGraphics
import Foundation

enum InputTargetMode {
    case mirror
    case extend
}

/// Selects the display whose pixels are represented by normalized video input.
enum InputTargetResolver {
    static func displayID(mode: InputTargetMode,
                          mirrorDisplayID: CGDirectDisplayID,
                          virtualDisplayID: CGDirectDisplayID?) -> CGDirectDisplayID? {
        switch mode {
        case .mirror: return mirrorDisplayID
        case .extend: return virtualDisplayID
        }
    }
}

enum InputCoordinateMapper {
    /// Map top-left-origin normalized video coordinates into global CG bounds.
    static func point(x: Double, y: Double, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + x * bounds.width,
                y: bounds.minY + y * bounds.height)
    }
}

enum InputPolicy {
    static let defaultsKey = "allowInput"

    /// Missing preference means enabled, preserving behavior for existing installs.
    static func allowsInput(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

struct SystemGestureShortcut {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

/// Maps semantic receiver actions to documented macOS keyboard shortcuts.
/// The shortcuts are defaults; macOS does not expose a public API for reading
/// user-customized Mission Control hotkeys.
enum SystemGestureShortcutMapping {
    static func shortcut(for gesture: ReceiverGesture,
                         macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        -> SystemGestureShortcut {
        switch gesture {
        case .missionControl:
            // Control-Up also needs SecondaryFn in a posted CGEvent.
            return SystemGestureShortcut(keyCode: 126, flags: [.maskControl, .maskSecondaryFn])
        case .appExpose:
            return SystemGestureShortcut(keyCode: 125, flags: [.maskControl, .maskSecondaryFn])
        case .nextSpace:
            return SystemGestureShortcut(keyCode: 124, flags: [.maskControl, .maskSecondaryFn])
        case .previousSpace:
            return SystemGestureShortcut(keyCode: 123, flags: [.maskControl, .maskSecondaryFn])
        case .showDesktop:
            // Synthetic F11 needs SecondaryFn on the tested macOS setup.
            return SystemGestureShortcut(keyCode: 103, flags: .maskSecondaryFn)
        case .launchpad:
            if macOSMajorVersion >= 26 {
                // macOS Tahoe renamed Launchpad to Apps and documents Fn-Shift-A.
                return SystemGestureShortcut(keyCode: 0, flags: [.maskShift, .maskSecondaryFn])
            }
            return SystemGestureShortcut(keyCode: 118, flags: [])
        }
    }
}
