import Foundation

struct TrackpadDelta: Equatable {
    let dx: Double
    let dy: Double
}

enum TrackpadTuning {
    static let defaultPointerSpeed = 1.25
    static let defaultScrollSpeed = 0.5
    static func bounded(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
    static func pointer(x: Double, y: Double, speed: Double) -> TrackpadDelta? {
        guard x.isFinite, y.isFinite else { return nil }
        let gain = bounded(speed, in: 0.5...4, fallback: defaultPointerSpeed)
        return TrackpadDelta(dx: min(max(x * gain, -10000), 10000),
                             dy: min(max(-y * gain, -10000), 10000))
    }
    /// Desktop points, independent of the captured raster / Retina factor.
    static func scroll(x: Double, y: Double, speed: Double, reversed: Bool) -> TrackpadDelta? {
        guard x.isFinite, y.isFinite else { return nil }
        let gain = bounded(speed, in: 0.15...2, fallback: defaultScrollSpeed) * (reversed ? -1 : 1)
        return TrackpadDelta(dx: min(max(x * gain, -10000), 10000),
                             dy: min(max(y * gain, -10000), 10000))
    }
}

/// UIKit reports cumulative translation in the receiving view's coordinates.
/// Preserve every direction change; gesture lifecycle, not a timer, resets the
/// baseline. Ending may reset UIKit's translation to zero, so it adds no delta.
struct TrackpadScrollGesture {
    private var previous: TrackpadDelta?

    mutating func update(phase: HardwareInput.PreciseScroll.Phase,
                         translation: TrackpadDelta, speed: Double,
                         reversed: Bool, modifiers: UInt) -> HardwareInput.PreciseScroll? {
        guard HardwareInput.validModifiers(modifiers),
              translation.dx.isFinite, translation.dy.isFinite else {
            return cancel(modifiers: 0)
        }
        switch phase {
        case .ended, .cancelled:
            guard previous != nil else { return nil }
            previous = nil
            return .init(dx: 0, dy: 0, mod: modifiers, phase: phase)
        case .began, .changed:
            if phase == .changed && previous == nil { return nil }
            let baseline = phase == .began ? TrackpadDelta(dx: 0, dy: 0) : previous!
            guard let delta = TrackpadTuning.scroll(
                x: translation.dx - baseline.dx, y: translation.dy - baseline.dy,
                speed: speed, reversed: reversed) else { return cancel(modifiers: modifiers) }
            previous = translation
            if phase == .changed && delta.dx == 0 && delta.dy == 0 { return nil }
            return .init(dx: delta.dx, dy: delta.dy, mod: modifiers, phase: phase)
        }
    }

    mutating func cancel(modifiers: UInt) -> HardwareInput.PreciseScroll? {
        guard previous != nil else { return nil }
        previous = nil
        return .init(dx: 0, dy: 0,
                     mod: HardwareInput.validModifiers(modifiers) ? modifiers : 0,
                     phase: .cancelled)
    }
}
