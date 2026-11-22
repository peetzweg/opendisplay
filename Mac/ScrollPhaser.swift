import CoreGraphics
import Foundation

/// Turns the receiver's phased `scroll` messages into the scroll-wheel events
/// a Mac trackpad posts: a touch phase (began, changed, ended) while fingers
/// are down, then a momentum phase (begin, continue, end) while the content
/// coasts. AppKit needs those phases to rubber-band and spring back, and
/// wheel-acceleration utilities leave phased events alone instead of treating
/// them as a physical wheel (#372).
///
/// Deltas arrive in points with fractions; events carry whole points, so the
/// remainder is carried into the next event instead of being dropped (slow
/// drags would otherwise lose their movement to rounding).
struct ScrollPhaser {
    struct Event: Equatable {
        var dx: Int32
        var dy: Int32
        var scrollPhase: CGScrollPhase.RawValue = 0
        var momentumPhase: CGMomentumScrollPhase.RawValue = 0
    }

    /// Fingers are on the glass (a touch phase is open).
    private(set) var touching = false
    /// The content is coasting (a momentum phase is open).
    private(set) var coasting = false
    private var remainderX = 0.0
    private var remainderY = 0.0

    /// Events for one wire message. Unknown phases produce nothing; a phase
    /// that arrives without its opener opens the gesture itself, so a lost
    /// message never leaves AppKit waiting for a `began`.
    mutating func events(phase: String, dx: Double, dy: Double) -> [Event] {
        switch phase {
        case "began":
            var out = close()
            touching = true
            out.append(delta(dx, dy, scroll: CGScrollPhase.began.rawValue))
            return out
        case "changed":
            guard touching else { return events(phase: "began", dx: dx, dy: dy) }
            return [delta(dx, dy, scroll: CGScrollPhase.changed.rawValue)]
        case "ended", "cancelled":
            guard touching else { return [] }
            var out: [Event] = []
            if dx != 0 || dy != 0 { out.append(delta(dx, dy, scroll: CGScrollPhase.changed.rawValue)) }
            touching = false
            out.append(Event(dx: 0, dy: 0, scrollPhase: CGScrollPhase.ended.rawValue))
            return out
        case "momentumBegan":
            var out = close()
            coasting = true
            out.append(delta(dx, dy, momentum: CGMomentumScrollPhase.begin.rawValue))
            return out
        case "momentumChanged":
            guard coasting else { return events(phase: "momentumBegan", dx: dx, dy: dy) }
            return [delta(dx, dy, momentum: CGMomentumScrollPhase.continuous.rawValue)]
        case "momentumEnded":
            guard coasting else { return [] }
            coasting = false
            return [Event(dx: 0, dy: 0, momentumPhase: CGMomentumScrollPhase.end.rawValue)]
        default:
            return []
        }
    }

    /// Ends whatever is open, e.g. when the receiver goes away mid-gesture —
    /// otherwise content stays stretched past its edge waiting for an end.
    mutating func close() -> [Event] {
        var out: [Event] = []
        if touching { out.append(Event(dx: 0, dy: 0, scrollPhase: CGScrollPhase.ended.rawValue)) }
        if coasting { out.append(Event(dx: 0, dy: 0, momentumPhase: CGMomentumScrollPhase.end.rawValue)) }
        touching = false
        coasting = false
        remainderX = 0
        remainderY = 0
        return out
    }

    private mutating func delta(_ dx: Double, _ dy: Double,
                                scroll: CGScrollPhase.RawValue = 0,
                                momentum: CGMomentumScrollPhase.RawValue = 0) -> Event {
        remainderX += dx
        remainderY += dy
        let x = remainderX.rounded()
        let y = remainderY.rounded()
        remainderX -= x
        remainderY -= y
        return Event(dx: Int32(x), dy: Int32(y), scrollPhase: scroll, momentumPhase: momentum)
    }
}
