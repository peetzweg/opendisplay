import CoreGraphics
import XCTest

final class ScrollPhaserTests: XCTestCase {
    private typealias E = ScrollPhaser.Event
    private let began = CGScrollPhase.began.rawValue
    private let changed = CGScrollPhase.changed.rawValue
    private let ended = CGScrollPhase.ended.rawValue
    private let mBegin = CGMomentumScrollPhase.begin.rawValue
    private let mContinue = CGMomentumScrollPhase.continuous.rawValue
    private let mEnd = CGMomentumScrollPhase.end.rawValue

    func testFlickProducesTrackpadPhasesThenMomentum() {
        var s = ScrollPhaser()
        XCTAssertEqual(s.events(phase: "began", dx: 0, dy: 10), [E(dx: 0, dy: 10, scrollPhase: began)])
        XCTAssertEqual(s.events(phase: "changed", dx: 0, dy: 12), [E(dx: 0, dy: 12, scrollPhase: changed)])
        XCTAssertEqual(s.events(phase: "ended", dx: 0, dy: 0), [E(dx: 0, dy: 0, scrollPhase: ended)])
        XCTAssertFalse(s.touching)
        XCTAssertEqual(s.events(phase: "momentumBegan", dx: 0, dy: 9), [E(dx: 0, dy: 9, momentumPhase: mBegin)])
        XCTAssertEqual(s.events(phase: "momentumChanged", dx: 0, dy: 8), [E(dx: 0, dy: 8, momentumPhase: mContinue)])
        XCTAssertEqual(s.events(phase: "momentumEnded", dx: 0, dy: 0), [E(dx: 0, dy: 0, momentumPhase: mEnd)])
        XCTAssertFalse(s.coasting)
    }

    /// Sub-point drags must add up instead of rounding away.
    func testFractionsCarryOver() {
        var s = ScrollPhaser()
        let deltas = [s.events(phase: "began", dx: 0.4, dy: -0.6)]
            + (0..<4).map { _ in s.events(phase: "changed", dx: 0.4, dy: -0.6) }
        let total = deltas.flatMap { $0 }.reduce((0, 0)) { ($0.0 + Int($1.dx), $0.1 + Int($1.dy)) }
        XCTAssertEqual(total.0, 2)    // 5 × 0.4
        XCTAssertEqual(total.1, -3)   // 5 × -0.6
    }

    func testMissingBeganOpensTheGesture() {
        var s = ScrollPhaser()
        XCTAssertEqual(s.events(phase: "changed", dx: 1, dy: 2), [E(dx: 1, dy: 2, scrollPhase: began)])
        XCTAssertEqual(s.events(phase: "momentumChanged", dx: 0, dy: 3),
                       [E(dx: 0, dy: 0, scrollPhase: ended), E(dx: 0, dy: 3, momentumPhase: mBegin)])
    }

    /// A new touch during coasting stops the momentum before the new scroll.
    func testNewScrollEndsMomentumFirst() {
        var s = ScrollPhaser()
        _ = s.events(phase: "momentumBegan", dx: 0, dy: 5)
        XCTAssertEqual(s.events(phase: "began", dx: 0, dy: 1),
                       [E(dx: 0, dy: 0, momentumPhase: mEnd), E(dx: 0, dy: 1, scrollPhase: began)])
    }

    func testCloseEndsWhateverIsOpen() {
        var s = ScrollPhaser()
        XCTAssertEqual(s.close(), [])
        _ = s.events(phase: "began", dx: 0, dy: 5)
        XCTAssertEqual(s.close(), [E(dx: 0, dy: 0, scrollPhase: ended)])
        XCTAssertEqual(s.close(), [])
    }

    func testStrayEndsAndUnknownPhasesAreIgnored() {
        var s = ScrollPhaser()
        XCTAssertEqual(s.events(phase: "ended", dx: 0, dy: 0), [])
        XCTAssertEqual(s.events(phase: "momentumEnded", dx: 0, dy: 0), [])
        XCTAssertEqual(s.events(phase: "wobble", dx: 1, dy: 1), [])
    }

    func testEndedWithADeltaPostsItBeforeEnding() {
        var s = ScrollPhaser()
        _ = s.events(phase: "began", dx: 0, dy: 1)
        XCTAssertEqual(s.events(phase: "ended", dx: 0, dy: 4),
                       [E(dx: 0, dy: 4, scrollPhase: changed), E(dx: 0, dy: 0, scrollPhase: ended)])
    }
}
