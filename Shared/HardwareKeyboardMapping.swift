import Foundation

/// A receiver-side, reversible physical-key mapping. The sender and wire stay
/// unchanged. Swapping both keys and flags preserves held shortcuts and drags.
enum HardwareKeyboardMapping: Equatable {
    case standard
    case commandOption

    func modifiers(_ flags: UInt) -> UInt {
        guard self == .commandOption else { return flags }
        let command: UInt = 1 << 20
        let option: UInt = 1 << 19
        var result = flags & ~(command | option)
        if flags & command != 0 { result |= option }
        if flags & option != 0 { result |= command }
        return result
    }

    func key(_ input: HardwareInput.Key) -> HardwareInput.Key {
        guard self == .commandOption else { return input }
        let code: Int
        switch input.code {
        case 226: code = 227  // Left Option -> Left Command
        case 227: code = 226
        case 230: code = 231  // Right Option -> Right Command
        case 231: code = 230
        default: code = input.code
        }
        return .init(code: code, down: input.down, mod: modifiers(input.mod))
    }
}
