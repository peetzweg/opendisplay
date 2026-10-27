import CoreGraphics
import Foundation

/// Decides, tick by tick, whether a virtual display's origin is ours to
/// enforce or the user's to persist (#116).
///
/// For a few seconds after creation (or a resize), macOS may restore ITS
/// saved arrangement for the display identity, which is stale whenever the
/// identity is fresh. During that window we re-assert `target`. Afterwards,
/// an origin change is the user rearranging and gets reported.
///
/// The window is measured from the first tick, not from when it was armed:
/// a tick stalled behind a wedged WindowServer (seen after sleep, a 10 s
/// mode change) must not burn the window before it ever ran, or macOS's
/// default spot is reported as a drag and overwrites the saved placement
/// (#390).
struct OriginRestore {
    enum Action: Equatable {
        case none
        /// Move the display here, then pass where it settled to `settled(at:)`.
        case apply(CGPoint)
        /// The user moved the display: persist this origin.
        case report(CGPoint)
    }

    static let window: TimeInterval = 6

    private var target: CGPoint?
    private var deadline: Date?
    private var lastObserved: CGPoint?

    init(target: CGPoint?) {
        self.target = target
    }

    /// Enforce `origin` for a fresh window, e.g. after a mode change that
    /// already placed the display there. `origin` counts as observed.
    mutating func rearm(at origin: CGPoint) {
        target = origin
        deadline = nil
        lastObserved = origin
    }

    mutating func tick(origin: CGPoint, now: Date = Date()) -> Action {
        if let target {
            let deadline = self.deadline ?? now.addingTimeInterval(Self.window)
            self.deadline = deadline
            if now < deadline {
                // Initial arrangement is system state, not a user drag (#203).
                if origin == target {
                    lastObserved = origin
                    return .none
                }
                return .apply(target)
            }
            self.target = nil
            // A window that closed without one observation (every apply
            // failed) still had a placement to protect: start observing
            // here instead of persisting wherever macOS left the display.
            if lastObserved == nil {
                lastObserved = origin
                return .none
            }
        }
        // With no saved placement (first contact), the first origin is
        // reported so the device gains one.
        guard origin != lastObserved else { return .none }
        lastObserved = origin
        return .report(origin)
    }

    /// WindowServer snaps a requested origin to the nearest valid
    /// arrangement. Adopt the snap as the target, or every remaining tick of
    /// the window re-applies against it; a snap is system state too, so it
    /// is observed, not reported.
    mutating func settled(at origin: CGPoint) {
        target = origin
        lastObserved = origin
    }
}
