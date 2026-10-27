import CoreGraphics
import XCTest

final class CaptureSourceCheckTests: XCTestCase {
    private let iMac = CGRect(x: -198, y: -1_152, width: 2_048, height: 1_152)
    private let pixel = CGRect(x: -1_080, y: 0, width: 1_080, height: 2_424)
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testOwnDisplayNeverTrips() {
        var check = CaptureSourceCheck()
        for second in 0..<10 {
            XCTAssertFalse(check.frame(screenRect: iMac, expected: iMac, now: t0 + Double(second)))
        }
    }

    /// #391: after sleep the iMac's stream kept delivering the Pixel's display.
    func testSustainedOtherDisplayTripsOnce() {
        var check = CaptureSourceCheck()

        XCTAssertFalse(check.frame(screenRect: pixel, expected: iMac, now: t0))
        XCTAssertFalse(check.frame(screenRect: pixel, expected: iMac, now: t0 + 1))
        XCTAssertTrue(check.frame(screenRect: pixel, expected: iMac, now: t0 + 2))
        // Re-armed: the next trip needs another sustained stretch.
        XCTAssertFalse(check.frame(screenRect: pixel, expected: iMac, now: t0 + 2.1))
    }

    func testResizeTransientDoesNotTrip() {
        var check = CaptureSourceCheck()
        let resized = CGRect(x: -198, y: -900, width: 1_600, height: 900)

        // Frames still carry the old size for a moment after a mode change.
        XCTAssertFalse(check.frame(screenRect: iMac, expected: resized, now: t0))
        XCTAssertFalse(check.frame(screenRect: iMac, expected: resized, now: t0 + 0.5))
        XCTAssertFalse(check.frame(screenRect: resized, expected: resized, now: t0 + 0.6))
        XCTAssertFalse(check.frame(screenRect: iMac, expected: resized, now: t0 + 2))
    }

    func testEmptyRectsAreIgnored() {
        var check = CaptureSourceCheck()

        XCTAssertFalse(check.frame(screenRect: .zero, expected: iMac, now: t0))
        XCTAssertFalse(check.frame(screenRect: .zero, expected: iMac, now: t0 + 5))
    }
}
