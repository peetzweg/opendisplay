import Foundation

/// Optional hardware-input messages. Raw modifier bits match UIKeyModifierFlags
/// and CGEventFlags, but are validated before reaching platform APIs.
enum HardwareInput {
    static let modifierMask: UInt = 0x3f0000
    static func validModifiers(_ value: UInt) -> Bool { value & ~modifierMask == 0 }
    static func supportedKey(_ code: Int) -> Bool {
        (4...69).contains(code) || (73...100).contains(code)
            || (103...111).contains(code) || [135, 137, 144, 145].contains(code)
            || (224...231).contains(code)
    }

    struct Key: Codable, Equatable {
        let code: Int
        let down: Bool
        let mod: UInt
        var isValid: Bool {
            HardwareInput.supportedKey(code) && HardwareInput.validModifiers(mod)
        }
    }

    struct Pointer: Codable, Equatable {
        enum Phase: String, Codable { case moved, began, ended, cancelled }
        let phase: Phase
        let x: Double
        let y: Double
        let button: Int
        let clicks: Int
        let mod: UInt
        var isValid: Bool {
            x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
                && (1...3).contains(button) && (1...3).contains(clicks)
                && HardwareInput.validModifiers(mod)
        }
    }

    struct RelativePointer: Codable, Equatable {
        let phase: Pointer.Phase
        /// Relative desktop points. Buttons use zero deltas, never a new anchor.
        let dx: Double
        let dy: Double
        let button: Int
        let clicks: Int
        let mod: UInt
        var isValid: Bool {
            dx.isFinite && dy.isFinite && abs(dx) <= 10000 && abs(dy) <= 10000
                && (1...3).contains(button) && (1...3).contains(clicks)
                && HardwareInput.validModifiers(mod)
        }
    }

    struct PreciseScroll: Codable, Equatable {
        enum Phase: String, Codable { case began, changed, ended, cancelled }
        let dx: Double
        let dy: Double
        let mod: UInt
        let phase: Phase
        var isValid: Bool {
            dx.isFinite && dy.isFinite && abs(dx) <= 10000 && abs(dy) <= 10000
                && HardwareInput.validModifiers(mod)
                && ((phase != .ended && phase != .cancelled) || (dx == 0 && dy == 0))
        }
    }

    struct Scroll: Codable, Equatable {
        /// Same video-pixel units and natural-scrolling sign as legacy scroll.
        let dx: Double
        let dy: Double
        let mod: UInt
        var isValid: Bool {
            dx.isFinite && dy.isFinite && abs(dx) <= 10000 && abs(dy) <= 10000
                && HardwareInput.validModifiers(mod)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
