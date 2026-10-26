import CoreGraphics
import XCTest

final class ClickCounterTests: XCTestCase {
    private var counter = ClickCounter(interval: 0.5, distance: 24)
    private let p = CGPoint(x: 100, y: 100)

    private func click(at point: CGPoint, now: TimeInterval) -> (down: Int, up: Int) {
        let down = counter.down(at: point, now: now)
        let up = counter.up(at: point, now: now + 0.05)
        return (down, up)
    }

    func testTwoQuickTapsAreADoubleClick() {
        XCTAssertEqual(click(at: p, now: 0).down, 1)
        let second = click(at: CGPoint(x: 110, y: 95), now: 0.3)   // a fingertip lands nearby
        XCTAssertEqual(second.down, 2)
        XCTAssertEqual(second.up, 2)
        XCTAssertEqual(click(at: p, now: 0.6).down, 3)
    }

    func testSlowTapsStaySingle() {
        _ = click(at: p, now: 0)
        XCTAssertEqual(click(at: p, now: 1).down, 1)
    }

    func testDistantTapsStaySingle() {
        _ = click(at: p, now: 0)
        XCTAssertEqual(click(at: CGPoint(x: 200, y: 100), now: 0.2).down, 1)
    }

    /// A press that travelled before release was a drag: the next tap starts over.
    func testDragBreaksTheChain() {
        _ = counter.down(at: p, now: 0)
        XCTAssertEqual(counter.up(at: CGPoint(x: 300, y: 100), now: 0.1), 1)
        XCTAssertEqual(click(at: p, now: 0.2).down, 1)
    }

    /// A press withdrawn because a second finger joined is no click at all.
    func testCancelBreaksTheChain() {
        _ = click(at: p, now: 0)
        _ = counter.down(at: p, now: 0.2)
        counter.cancel()
        XCTAssertEqual(click(at: p, now: 0.3).down, 1)
    }

    func testUpWithoutDownIsASingleClick() {
        XCTAssertEqual(counter.up(at: p, now: 0), 1)
    }
}
