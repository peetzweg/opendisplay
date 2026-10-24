import Foundation

/// Per-chip H.264 decode budgets for the oldest hardware the app runs on.
///
/// iOS 15 (the deployment floor, #72) reaches back to the A8/A8X iPads. Their
/// panels are 2048×1536, which at 60 fps is ~189 Mpixel/s of H.264, more than
/// an A8-class decoder is rated for. The receiver announces a throughput
/// ceiling in `hello.videoCaps` (PROTOCOL.md 6.5) and the sender keeps the
/// raster sharp while lowering the frame rate to fit (#288).
///
/// The A8 value is H.264 Level 4.2's macroblock rate (522,240 MB/s × 256
/// px), which is what 1080p60 hardware of that generation is specified to.
/// It is deliberately conservative and **untested on a real A8 device**; tune
/// it once one is available (#72). Newer chips get no budget: A9 and later
/// decode 4K and are not the constraint.
enum DecodeBudget {
    /// H.264 Level 4.2: 522,240 macroblocks/s.
    static let level42PixelsPerSecond = 522_240 * 256

    /// Hardware model identifier, e.g. "iPad5,3" (iPad Air 2).
    static var currentModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// nil means "no budget, stream the panel at full rate".
    static func maxPixelsPerSecond(model: String) -> Int? {
        switch model {
        // A8X: iPad Air 2. A8: iPad mini 4. Both top out at iPadOS 15.
        case "iPad5,1", "iPad5,2", "iPad5,3", "iPad5,4":
            return level42PixelsPerSecond
        default:
            return nil
        }
    }
}
