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
