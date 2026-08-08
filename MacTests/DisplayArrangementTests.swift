import CoreGraphics
import XCTest

final class DisplayArrangementTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1_512, height: 982)

    func testRotationKeepsDisplayFlushLeftOfItsNeighbour() {
        let saved = CGRect(x: -588, y: 0, width: 588, height: 1_278)

        let target = DisplayArrangement.remappedOrigin(from: saved,
                                                        to: CGSize(width: 1_278, height: 588),
                                                        against: [main])

        XCTAssertEqual(target, CGPoint(x: -1_278, y: 0))
    }

    func testRotationKeepsDisplayFlushRightOfItsNeighbour() {
        // The saved portrait hangs above the main display, overlapping it by
        // only its bottom 345pt. Carrying y over verbatim would put the
        // shorter landscape entirely above the main display — a disconnected
        // arrangement WindowServer would snap. Slide it down just far enough
        // to keep the 345pt of shared edge it had.
        let saved = CGRect(x: 1_512, y: -933, width: 588, height: 1_278)

        let target = DisplayArrangement.remappedOrigin(from: saved,
                                                        to: CGSize(width: 1_278, height: 588),
                                                        against: [main])

        XCTAssertEqual(target, CGPoint(x: 1_512, y: -243))
        XCTAssertEqual(CGRect(origin: target, size: CGSize(width: 1_278, height: 588)).maxY - main.minY, 345)
    }

    func testRotationKeepsDisplayFlushAboveAndBelowItsNeighbour() {
        let above = CGRect(x: 200, y: -1_278, width: 588, height: 1_278)
        let below = CGRect(x: 200, y: 982, width: 588, height: 1_278)
        let landscape = CGSize(width: 1_278, height: 588)

        XCTAssertEqual(DisplayArrangement.remappedOrigin(from: above, to: landscape, against: [main]),
                       CGPoint(x: 200, y: -588))
        XCTAssertEqual(DisplayArrangement.remappedOrigin(from: below, to: landscape, against: [main]),
                       CGPoint(x: 200, y: 982))
    }

    func testRepeatedRotationDoesNotDriftTheSavedPlacement() {
        let portraitSize = CGSize(width: 588, height: 1_278)
        let landscapeSize = CGSize(width: 1_278, height: 588)
        let portrait = CGRect(origin: CGPoint(x: -588, y: 0), size: portraitSize)

        let landscapeOrigin = DisplayArrangement.remappedOrigin(from: portrait,
                                                                 to: landscapeSize,
                                                                 against: [main])
        let landscape = CGRect(origin: landscapeOrigin, size: landscapeSize)
        let restoredPortrait = DisplayArrangement.remappedOrigin(from: landscape,
                                                                  to: portraitSize,
                                                                  against: [main])

        XCTAssertEqual(landscapeOrigin, CGPoint(x: -1_278, y: 0))
        XCTAssertEqual(restoredPortrait, portrait.origin)
    }

    func testRotationKeepsTheSideWhenTheSavedDisplayTouchesAtOnlyACorner() {
        // WindowServer allows this top-right corner attachment. It has no
        // shared vertical edge, so a remap must not fall back to the old
        // center calculation and request an illegal gap.
        let saved = CGRect(x: 1_512, y: -588, width: 1_278, height: 588)

        let target = DisplayArrangement.remappedOrigin(from: saved,
                                                        to: CGSize(width: 588, height: 1_278),
                                                        against: [main])

        XCTAssertEqual(target, CGPoint(x: 1_512, y: -588))
    }

    func testSavedMainDisplaySideWinsOverOtherVirtualDisplayGeometry() {
        let saved = CGRect(x: -588, y: 120, width: 588, height: 1_278)

        let target = DisplayArrangement.origin(for: CGSize(width: 1_278, height: 588),
                                               from: saved, side: .left, relativeTo: main)

        XCTAssertEqual(target, CGPoint(x: -1_278, y: 120))
    }

    func testSavedSideStillYieldsAConnectedArrangementWhenTheDisplayShrinks() {
        // Same shape as the remap case above, on the path that actually runs
        // once a record carries its side: the rotated display must still share
        // an edge with the main display rather than float off its top.
        let saved = CGRect(x: 1_512, y: -933, width: 588, height: 1_278)
        let size = CGSize(width: 1_278, height: 588)

        let target = DisplayArrangement.origin(for: size, from: saved, side: .right, relativeTo: main)

        XCTAssertEqual(target, CGPoint(x: 1_512, y: -243))
        XCTAssertTrue(CGRect(origin: target, size: size).intersects(main.insetBy(dx: -1, dy: 0)))
    }

    func testSavedSideRoundTripsWithoutDrift() {
        let portrait = CGSize(width: 588, height: 1_278)
        let landscape = CGSize(width: 1_278, height: 588)
        let saved = CGRect(origin: CGPoint(x: -588, y: 120), size: portrait)

        let rotated = DisplayArrangement.origin(for: landscape, from: saved, side: .left, relativeTo: main)
        let back = DisplayArrangement.origin(for: portrait,
                                             from: CGRect(origin: rotated, size: landscape),
                                             side: .left, relativeTo: main)

        XCTAssertEqual(rotated, CGPoint(x: -1_278, y: 120))
        XCTAssertEqual(back, saved.origin)
    }

    func testSavedSideKeepsACornerAttachmentACorner() {
        let saved = CGRect(x: 1_512, y: -588, width: 1_278, height: 588)

        let target = DisplayArrangement.origin(for: CGSize(width: 588, height: 1_278),
                                               from: saved, side: .right, relativeTo: main)

        XCTAssertEqual(target, CGPoint(x: 1_512, y: -588))
    }

    func testLegacyRecordTouchingMainDisplayCanAlsoKeepItsSide() {
        let legacy = CGRect(x: 392, y: 982, width: 1_180, height: 820)

        XCTAssertEqual(DisplayArrangement.inferredMainDisplaySide(of: legacy, relativeTo: main), .below)
    }

    func testRotationFallsBackToCenterWhenTheSavedNeighbourIsGone() {
        let saved = CGRect(x: -588, y: 0, width: 588, height: 1_278)

        let target = DisplayArrangement.remappedOrigin(from: saved,
                                                        to: CGSize(width: 1_278, height: 588),
                                                        against: [])

        XCTAssertEqual(target, CGPoint(x: -933, y: 345))
    }
}
