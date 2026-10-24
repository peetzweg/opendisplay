import Foundation

/// Paces phased scrolling so it moves like a trackpad's.
///
/// A trackpad delivers small deltas at a steady ~120 Hz. Over WiFi the
/// receiver's scroll messages arrive in bursts with gaps between them, and
/// posting each one as it lands makes the content stutter and step even
/// though the total distance is right. So incoming deltas go into a reservoir
/// and a 120 Hz tick drains it exponentially (time constant `timeConstant`):
/// a burst becomes a smooth ramp and short gaps are bridged, at the price of
/// roughly `timeConstant` of extra latency.
///
/// Phase changes are deferred to the tick too, so an end never cuts off
/// movement still in the reservoir, and a flick's leftover keeps flowing into
/// its momentum instead of landing as one jump.
struct ScrollSmoother {
    /// Seconds; 0 posts every delta as it arrives.
    let timeConstant: TimeInterval
    private(set) var phaser = ScrollPhaser()

    private enum Mode { case idle, touch, momentum }
    private var mode = Mode.idle
    private var endRequested = false
    private var pendingX = 0.0
    private var pendingY = 0.0

    /// Below this many points the reservoir counts as drained.
    static let drained = 0.25

    init(timeConstant: TimeInterval) {
        self.timeConstant = timeConstant
    }

    /// True when nothing is in flight and the tick can stop.
    var isIdle: Bool { mode == .idle }

    /// Events to post right away for one wire message (deltas in points).
    mutating func receive(phase: String, dx: Double, dy: Double) -> [ScrollPhaser.Event] {
        guard timeConstant > 0 else { return phaser.events(phase: phase, dx: dx, dy: dy) }
        switch phase {
        case "began":
            // A finger landing catches coasting content: drop what was left.
            if mode == .momentum { pendingX = 0; pendingY = 0 }
            var out = finish()
            mode = .touch
            endRequested = false
            pendingX = dx; pendingY = dy
            out += phaser.events(phase: "began", dx: 0, dy: 0)
            return out
        case "changed":
            guard mode == .touch else { return receive(phase: "began", dx: dx, dy: dy) }
            pendingX += dx; pendingY += dy
            endRequested = false
            return []
        case "ended", "cancelled":
            guard mode == .touch else { return [] }
            pendingX += dx; pendingY += dy
            endRequested = true
            return []
        case "momentumBegan":
            var out: [ScrollPhaser.Event] = []
            if mode == .touch {
                // The fingers lifted: end the touch phase but keep what is
                // still in the reservoir flowing, now as momentum.
                out += phaser.events(phase: "ended", dx: 0, dy: 0)
            } else {
                out += finish()
            }
            mode = .momentum
            endRequested = false
            pendingX += dx; pendingY += dy
            out += phaser.events(phase: "momentumBegan", dx: 0, dy: 0)
            return out
        case "momentumChanged":
            guard mode == .momentum else { return receive(phase: "momentumBegan", dx: dx, dy: dy) }
            pendingX += dx; pendingY += dy
            return []
        case "momentumEnded":
            guard mode == .momentum else { return [] }
            endRequested = true
            return []
        default:
            return []
        }
    }

    /// Events for one tick, `dt` seconds after the previous one.
    mutating func tick(dt: TimeInterval) -> [ScrollPhaser.Event] {
        guard mode != .idle else { return [] }
        let changed = mode == .touch ? "changed" : "momentumChanged"
        if endRequested, hypot(pendingX, pendingY) < Self.drained {
            return finish()
        }
        let share = 1 - exp(-max(dt, 0) / timeConstant)
        let x = pendingX * share, y = pendingY * share
        pendingX -= x; pendingY -= y
        guard x != 0 || y != 0 else { return [] }
        return phaser.events(phase: changed, dx: x, dy: y)
    }

    /// Post what is left and close the open phase, e.g. on disconnect.
    mutating func finish() -> [ScrollPhaser.Event] {
        var out: [ScrollPhaser.Event] = []
        switch mode {
        case .touch:
            out = phaser.events(phase: "ended", dx: pendingX, dy: pendingY)
        case .momentum:
            if pendingX != 0 || pendingY != 0 {
                out = phaser.events(phase: "momentumChanged", dx: pendingX, dy: pendingY)
            }
            out += phaser.events(phase: "momentumEnded", dx: 0, dy: 0)
        case .idle:
            break
        }
        out += phaser.close()
        mode = .idle
        endRequested = false
        pendingX = 0; pendingY = 0
        return out
    }
}
