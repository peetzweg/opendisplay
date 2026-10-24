import CoreGraphics
import XCTest

final class ScrollSmootherTests: XCTestCase {
    private let tick = 1.0 / 120
    private let began = CGScrollPhase.began.rawValue
    private let ended = CGScrollPhase.ended.rawValue
    private let mBegin = CGMomentumScrollPhase.begin.rawValue
    private let mEnd = CGMomentumScrollPhase.end.rawValue

    private func totalY(_ events: [ScrollPhaser.Event]) -> Int {
        events.reduce(0) { $0 + Int($1.dy) }
    }

    private func run(_ s: inout ScrollSmoother, ticks: Int) -> [ScrollPhaser.Event] {
        (0..<ticks).flatMap { _ in s.tick(dt: tick) }
    }

    /// A WiFi burst (three messages at once after a gap) comes out as a ramp
    /// over several ticks, not as one jump, and none of the distance is lost.
    func testBurstIsSpreadAcrossTicksWithoutLosingDistance() {
        var s = ScrollSmoother(timeConstant: 0.025)
        var out = s.receive(phase: "began", dx: 0, dy: 10)
        out += s.receive(phase: "changed", dx: 0, dy: 10)
        out += s.receive(phase: "changed", dx: 0, dy: 10)
        XCTAssertEqual(out.first?.scrollPhase, began)

        let first = s.tick(dt: tick)
        XCTAssertLessThan(totalY(first), 15, "a burst must not be posted at once")
        out += first
        out += run(&s, ticks: 60)
        out += s.receive(phase: "ended", dx: 0, dy: 0)
        out += run(&s, ticks: 60)

        XCTAssertEqual(totalY(out), 30)
        XCTAssertEqual(out.last?.scrollPhase, ended)
        XCTAssertTrue(s.isIdle)
    }

    /// The end waits for the reservoir, so the last movement is not cut off.
    func testEndWaitsUntilDrained() {
        var s = ScrollSmoother(timeConstant: 0.025)
        _ = s.receive(phase: "began", dx: 0, dy: 40)
        _ = s.receive(phase: "ended", dx: 0, dy: 0)
        let next = s.tick(dt: tick)
        XCTAssertFalse(next.contains { $0.scrollPhase == ended })
        XCTAssertFalse(s.isIdle)
    }

    /// A flick's leftover flows into momentum instead of landing as a jump.
    func testLeftoverCarriesIntoMomentum() {
        var s = ScrollSmoother(timeConstant: 0.025)
        var out = s.receive(phase: "began", dx: 0, dy: 40)
        out += s.receive(phase: "ended", dx: 0, dy: 0)
        let handoff = s.receive(phase: "momentumBegan", dx: 0, dy: 5)
        XCTAssertEqual(handoff.map(\.scrollPhase), [ended, 0])
        XCTAssertEqual(handoff.last?.momentumPhase, mBegin)
        XCTAssertEqual(totalY(handoff), 0)
        out += handoff
        out += run(&s, ticks: 30)
        out += s.receive(phase: "momentumEnded", dx: 0, dy: 0)
        out += run(&s, ticks: 60)
        XCTAssertEqual(totalY(out), 45)
        XCTAssertEqual(out.last?.momentumPhase, mEnd)
    }

    /// A finger landing during the coast stops it: the rest is dropped.
    func testNewTouchCatchesMomentum() {
        var s = ScrollSmoother(timeConstant: 0.025)
        _ = s.receive(phase: "momentumBegan", dx: 0, dy: 100)
        _ = s.receive(phase: "momentumEnded", dx: 0, dy: 0)
        let caught = s.receive(phase: "began", dx: 0, dy: 0)
        XCTAssertEqual(totalY(caught), 0)
        XCTAssertEqual(caught.first?.momentumPhase, mEnd)
        XCTAssertEqual(caught.last?.scrollPhase, began)
    }

    func testFinishFlushesAndCloses() {
        var s = ScrollSmoother(timeConstant: 0.025)
        _ = s.receive(phase: "began", dx: 0, dy: 20)
        let out = s.finish()
        XCTAssertEqual(totalY(out), 20)
        XCTAssertEqual(out.last?.scrollPhase, ended)
        XCTAssertTrue(s.isIdle)
    }

    func testZeroTimeConstantPassesThrough() {
        var s = ScrollSmoother(timeConstant: 0)
        XCTAssertEqual(totalY(s.receive(phase: "began", dx: 0, dy: 7)), 7)
        XCTAssertEqual(s.tick(dt: tick), [])
    }
}
