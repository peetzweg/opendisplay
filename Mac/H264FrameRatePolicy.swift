import Foundation

/// Conservative sender-side workaround for large H.264 streams (issue #271).
/// This is a rate policy, not a guarantee of encoder/decoder capabilities.
struct H264FrameRatePolicy {
    let framesPerSecond: Int
    private var nextDeadline: Double?

    init(width: Int, height: Int) {
        // High@L5.2 permits 2,073,600 macroblocks/sec. Leave one fps of
        // headroom when 60 fps exceeds that budget: 4096x2304 becomes 55 fps.
        let macroblocks = max(1, ((width + 15) / 16) * ((height + 15) / 16))
        let levelRate = max(1, min(60, 2_073_600 / macroblocks))
        framesPerSecond = levelRate < 60 ? max(1, levelRate - 1) : 60
    }

    /// False means defer the latest frame, including when capture goes idle.
    /// All calls use the same capture/host clock as the encoder timestamps.
    mutating func shouldSubmit(at time: Double) -> Bool {
        // Preserve existing behavior for streams that fit the 60 fps budget.
        guard framesPerSecond < 60, time.isFinite else { return true }
        let interval = 1.0 / Double(framesPerSecond)
        if let next = nextDeadline {
            guard time + 0.0005 >= next else { return false }
            // Keep the fractional cadence instead of setting time + interval,
            // which would turn a 60 Hz source into a 30 fps stream. Skip idle
            // gaps in constant time, never submitting a burst to catch up.
            // Include the early-admission tolerance when advancing. Otherwise
            // a late frame that lands just before the next slot could be
            // admitted twice with the same timestamp.
            let steps = max(1, floor((time + 0.0005 - next) / interval) + 1)
            nextDeadline = next + steps * interval
        } else {
            nextDeadline = time + interval
        }
        return true
    }
}
