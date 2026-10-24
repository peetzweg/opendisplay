import CoreGraphics
import Foundation

/// Multi-click counting for synthetic presses. Events we post get no click
/// state from the Window Server, so we mirror its rule: a press continues the
/// previous click when it lands within `interval` of that click's release and
/// within `distance` of its press. A press that wandered further than
/// `distance` before release is a drag and breaks the chain.
struct ClickCounter {
    let interval: TimeInterval
    let distance: CGFloat

    private struct Press {
        let location: CGPoint
        let clickState: Int
    }

    private struct CompletedClick {
        let upTime: TimeInterval
        let downLocation: CGPoint
        let clickState: Int
    }

    private var press: Press?
    private var lastClick: CompletedClick?

    init(interval: TimeInterval, distance: CGFloat) {
        self.interval = interval
        self.distance = distance
    }

    /// Click state for a mouse-down at `point`.
    mutating func down(at point: CGPoint, now: TimeInterval) -> Int {
        var state = 1
        if let last = lastClick, now - last.upTime <= interval,
           hypot(point.x - last.downLocation.x, point.y - last.downLocation.y) <= distance {
            state = last.clickState + 1
        }
        press = Press(location: point, clickState: state)
        return state
    }

    /// Click state for the matching mouse-up at `point`.
    mutating func up(at point: CGPoint, now: TimeInterval) -> Int {
        guard let press else { return 1 }
        self.press = nil
        if hypot(point.x - press.location.x, point.y - press.location.y) <= distance {
            lastClick = CompletedClick(upTime: now, downLocation: press.location,
                                       clickState: press.clickState)
        } else {
            lastClick = nil
        }
        return press.clickState
    }

    /// The press was taken back (it became a scroll): no click, no chain.
    mutating func cancel() {
        press = nil
        lastClick = nil
    }
}
