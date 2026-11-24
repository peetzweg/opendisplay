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

    func testFitsNeedsContactWithoutOverlap() {
        let size = CGSize(width: 698, height: 1_016)

        XCTAssertTrue(DisplayArrangement.fits(CGRect(origin: CGPoint(x: -698, y: 0), size: size), among: [main]))
        XCTAssertTrue(DisplayArrangement.fits(CGRect(origin: CGPoint(x: -698, y: -1_016), size: size), among: [main]),
                      "a shared corner is a valid arrangement")
        XCTAssertFalse(DisplayArrangement.fits(CGRect(origin: CGPoint(x: -697, y: 0), size: size), among: [main]),
                       "overlap")
        XCTAssertFalse(DisplayArrangement.fits(CGRect(origin: CGPoint(x: -699, y: 0), size: size), among: [main]),
                       "gap")
        XCTAssertTrue(DisplayArrangement.fits(CGRect(origin: .zero, size: size), among: []))
    }

    /// iPhone Duo bench: the record came from a layout with a monitor that is
    /// gone, so every fold asked for a detached spot that WindowServer
    /// snapped back to (1512, y), a second reconfiguration per fold.
    func testLiveResizeKeepsTheDisplayWhereItIsWhenTheRecordIsFromAnotherLayout() {
        let stale = CGRect(x: 3_560, y: 0, width: 2_852, height: 2_006)
        let current = CGRect(x: 1_512, y: 290, width: 1_002, height: 1_426)
        let folded = CGSize(width: 698, height: 1_016)

        let creation = DisplayArrangement.origin(for: folded, saved: stale, side: nil, main: main,
                                                 others: [main], current: nil)
        let live = DisplayArrangement.origin(for: folded, saved: stale, side: nil, main: main,
                                             others: [main], current: current)

        XCTAssertEqual(creation, CGPoint(x: 4_637, y: 495), "creation still asks for the saved spot")
        XCTAssertEqual(live, CGPoint(x: 1_512, y: 290))
    }

    func testLiveResizeNeverAsksForAnOriginOverlappingTheMainDisplay() {
        // A record saved while the display sat at the main display's origin.
        let overlapping = CGRect(x: 0, y: 0, width: 1_426, height: 1_002)
        let unfolded = CGRect(x: -1_426, y: 0, width: 1_426, height: 1_002)
        let folded = CGSize(width: 698, height: 1_016)

        let fold = DisplayArrangement.origin(for: folded, saved: overlapping, side: nil, main: main,
                                             others: [main], current: unfolded)
        let unfold = DisplayArrangement.origin(for: unfolded.size, saved: overlapping, side: nil, main: main,
                                               others: [main],
                                               current: CGRect(origin: fold, size: folded))

        XCTAssertEqual(fold, CGPoint(x: -698, y: 0))
        XCTAssertEqual(unfold, unfolded.origin)
    }

    func testLiveResizeKeepsAValidSavedPlacement() {
        let saved = CGRect(x: -1_002, y: 0, width: 1_002, height: 1_426)
        // macOS restored its own record for the identity somewhere else.
        let current = CGRect(x: 1_512, y: 0, width: 1_002, height: 1_426)

        let target = DisplayArrangement.origin(for: CGSize(width: 698, height: 1_016), saved: saved,
                                               side: .left, main: main, others: [main], current: current)

        XCTAssertEqual(target, CGPoint(x: -698, y: 0))
    }

    func testLiveResizeStaysBesideASiblingThatNowHoldsTheSavedSide() {
        let saved = CGRect(x: -1_426, y: 0, width: 1_426, height: 1_002)
        let sibling = CGRect(x: -588, y: 0, width: 588, height: 1_278)
        let current = CGRect(x: -2_014, y: 0, width: 1_426, height: 1_002)
        let folded = CGSize(width: 698, height: 1_016)

        let target = DisplayArrangement.origin(for: folded, saved: saved, side: .left, main: main,
                                               others: [main, sibling], current: current)

        XCTAssertEqual(target, CGPoint(x: -1_286, y: 0))
        XCTAssertTrue(DisplayArrangement.fits(CGRect(origin: target, size: folded), among: [main, sibling]))
    }

    func testRotationFallsBackToCenterWhenTheSavedNeighbourIsGone() {
        let saved = CGRect(x: -588, y: 0, width: 588, height: 1_278)

        let target = DisplayArrangement.remappedOrigin(from: saved,
                                                        to: CGSize(width: 1_278, height: 588),
                                                        against: [])

        XCTAssertEqual(target, CGPoint(x: -933, y: 345))
    }
}
