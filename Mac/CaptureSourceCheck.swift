import CoreGraphics
import Foundation

/// Watches that a running capture still delivers its own display (#391).
///
/// After a sleep with two receivers, a stream started on one virtual display
/// kept running but delivered the other display's picture, aspect-fit into
/// its own output size. Nothing on our side errors when that happens, so the
/// only witness is SCK's per-frame `screenRect`: the global desktop rect the
/// frame was captured from. Corresponding edges within one point match,
/// allowing for fractional-scale rounding (#413). Larger differences are
/// normal while a display is resized or dragged (the frame and
/// `CGDisplayBounds` update a moment apart). Only a mismatch that lasts
/// at least `tolerance` counts.
struct CaptureSourceCheck {
    static let tolerance: TimeInterval = 1.5
    private static let boundsTolerance: CGFloat = 1

    private var mismatchSince: Date?

    /// Feed one complete frame. Returns true once, when the stream has been
    /// delivering some other rect for longer than `tolerance`; the caller
    /// then re-attaches capture and should start a fresh check.
    mutating func frame(screenRect: CGRect, expected: CGRect, now: Date = Date()) -> Bool {
        let boundsTolerance = Self.boundsTolerance
        let boundsMatch = abs(screenRect.minX - expected.minX) <= boundsTolerance
            && abs(screenRect.minY - expected.minY) <= boundsTolerance
            && abs(screenRect.maxX - expected.maxX) <= boundsTolerance
            && abs(screenRect.maxY - expected.maxY) <= boundsTolerance
        guard !screenRect.isEmpty, !expected.isEmpty, !boundsMatch else {
            mismatchSince = nil
            return false
        }
        guard let since = mismatchSince else {
            mismatchSince = now
            return false
        }
        guard now.timeIntervalSince(since) >= Self.tolerance else { return false }
        mismatchSince = nil
        return true
    }
}
