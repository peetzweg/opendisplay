import Foundation

/// Additive semantic receiver gestures understood by supported senders.
enum ReceiverGesture: String, CaseIterable {
    case missionControl
    case appExpose
    case nextSpace
    case previousSpace
    case showDesktop
    case launchpad

    static let swipeMinimumDistance = 80.0
    static let swipeDominanceRatio = 1.5
    static let spreadMinimumChange = 36.0
    static let spreadMinimumRatio = 1.2

    static func swipe(translationX: Double, translationY: Double) -> Self? {
        let x = abs(translationX)
        let y = abs(translationY)
        if y >= swipeMinimumDistance, y >= x * swipeDominanceRatio {
            return translationY < 0 ? .missionControl : .appExpose
        }
        if x >= swipeMinimumDistance, x >= y * swipeDominanceRatio {
            return translationX < 0 ? .nextSpace : .previousSpace
        }
        return nil
    }

    static func spreadGesture(start: Double, current: Double) -> Self? {
        let change = current - start
        guard abs(change) >= spreadMinimumChange,
              max(start, current) >= min(start, current) * spreadMinimumRatio else { return nil }
        return change > 0 ? .showDesktop : .launchpad
    }

    static func shouldRoute(name: String, inputAllowed: Bool) -> Bool {
        inputAllowed && Self(rawValue: name) != nil
    }
}

/// The mean of every active fingertip pair gives pinch/spread a symmetric
/// measure that does not assume one particular contact is the thumb.
enum ReceiverGestureGeometry {
    static func meanPairwiseDistance(_ points: [(x: Double, y: Double)]) -> Double? {
        guard (4...5).contains(points.count) else { return nil }
        var total = 0.0
        var pairs = 0
        for first in 0..<points.count {
            for second in (first + 1)..<points.count {
                let dx = points[first].x - points[second].x
                let dy = points[first].y - points[second].y
                total += (dx * dx + dy * dy).squareRoot()
                pairs += 1
            }
        }
        return total / Double(pairs)
    }
}

/// Tracks one pinch/spread across 4↔5 contact changes. Each contact-count
/// segment uses its own geometry baseline so adding or lifting a finger does
/// not look like a sudden spread change. Movement within each segment
/// accumulates toward the same distance and relative-change thresholds.
struct ReceiverGestureSpreadSession {
    private(set) var activeTouchCount: Int?
    private(set) var hasEmitted = false
    private(set) var isCancelled = false
    private var segmentStartSpread: Double?
    private var lastSpread: Double?
    private var accumulatedChange = 0.0
    private var accumulatedLogRatio = 0.0

    mutating func update(touchCount: Int, spread: Double) -> ReceiverGesture? {
        guard !isCancelled else { return nil }
        guard (4...5).contains(touchCount), spread.isFinite, spread >= 0 else {
            if activeTouchCount != nil || touchCount > 5 { isCancelled = true }
            activeTouchCount = nil
            return nil
        }
        guard !hasEmitted else {
            activeTouchCount = touchCount
            return nil
        }
        guard let activeTouchCount,
              let segmentStartSpread,
              let lastSpread else {
            self.activeTouchCount = touchCount
            self.segmentStartSpread = spread
            self.lastSpread = spread
            return nil
        }

        if activeTouchCount != touchCount {
            accumulate(from: segmentStartSpread, to: lastSpread)
            self.activeTouchCount = touchCount
            self.segmentStartSpread = spread
            self.lastSpread = spread
            return nil
        }

        self.lastSpread = spread
        let totalChange = accumulatedChange + spread - segmentStartSpread
        let totalLogRatio = accumulatedLogRatio + logRatio(from: segmentStartSpread, to: spread)
        let minimumLogRatio = log(ReceiverGesture.spreadMinimumRatio)
        guard abs(totalChange) >= ReceiverGesture.spreadMinimumChange else {
            return nil
        }
        if totalChange > 0, totalLogRatio >= minimumLogRatio {
            hasEmitted = true
            return .showDesktop
        }
        if totalChange < 0, totalLogRatio <= -minimumLogRatio {
            hasEmitted = true
            return .launchpad
        }
        return nil
    }

    mutating func reset() {
        activeTouchCount = nil
        hasEmitted = false
        isCancelled = false
        segmentStartSpread = nil
        lastSpread = nil
        accumulatedChange = 0
        accumulatedLogRatio = 0
    }

    private mutating func accumulate(from start: Double, to end: Double) {
        accumulatedChange += end - start
        accumulatedLogRatio += logRatio(from: start, to: end)
    }

    private func logRatio(from start: Double, to end: Double) -> Double {
        // Pairwise spread can be zero only when every contact is coincident;
        // clamping keeps the ratio finite while the independent 36 pt test
        // prevents that edge case from triggering on a tiny movement.
        log(max(end, 0.001) / max(start, 0.001))
    }
}

struct GestureEmissionGate {
    private(set) var hasEmitted = false

    mutating func claim() -> Bool {
        guard !hasEmitted else { return false }
        hasEmitted = true
        return true
    }

    mutating func reset() {
        hasEmitted = false
    }
}

enum ReceiverTouchOwnershipAction: Equatable {
    case sendCancellation
    case discardPendingPress
}

enum ReceiverTouchOwnership {
    /// Release a posted synthetic down before discarding local pending state.
    static func cancellationActions(downWasSent: Bool) -> [ReceiverTouchOwnershipAction] {
        downWasSent ? [.sendCancellation, .discardPendingPress] : [.discardPendingPress]
    }
}
