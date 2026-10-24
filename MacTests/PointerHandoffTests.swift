import CoreGraphics
import XCTest

final class PointerHandoffTests: XCTestCase {
    private var clock: TimeInterval = 100
    private var warps: [CGPoint] = []

    private func makeHandoff(enabled: Bool = true) -> PointerHandoff {
        PointerHandoff(enabled: enabled, now: { [unowned self] in clock },
                       warp: { [unowned self] in warps.append($0) })
    }

    private let home = CGPoint(x: 400, y: 300)       // where the user's mouse was
    private let tap = CGPoint(x: -900, y: 1_200)      // a point on the device

    private func tapOnce(_ h: PointerHandoff, at p: CGPoint) {
        h.touchMovesPointer(to: p, from: home, holding: true)    // began
        h.touchMovesPointer(to: p, from: p, holding: false)      // ended
    }

    func testTapHidesPointerAndMouseMovementReturnsItHomeWithTheMovement() {
        let h = makeHandoff()
        tapOnce(h, at: tap)
        XCTAssertTrue(h.touchOwnsPointer)

        clock += 1
        h.pointerSampled(at: tap)                     // pointer still where the tap left it
        XCTAssertEqual(warps, [])
        XCTAssertTrue(h.touchOwnsPointer)

        h.pointerSampled(at: CGPoint(x: tap.x + 5, y: tap.y - 2))   // user nudges the mouse
        XCTAssertEqual(warps, [CGPoint(x: home.x + 5, y: home.y - 2)])
        XCTAssertFalse(h.touchOwnsPointer)

        h.pointerSampled(at: CGPoint(x: 0, y: 0))     // once home, the mouse is the mouse
        XCTAssertEqual(warps.count, 1)
    }

    /// The poll can read the location before the touch's own event lands.
    func testLaggingSampleRightAfterATouchIsNotTheMouse() {
        let h = makeHandoff()
        tapOnce(h, at: tap)
        clock += PointerHandoff.settle / 2
        h.pointerSampled(at: home)
        XCTAssertEqual(warps, [])
        XCTAssertTrue(h.touchOwnsPointer)
    }

    func testNoReturnWhileAFingerIsDown() {
        let h = makeHandoff()
        h.touchMovesPointer(to: tap, from: home, holding: true)
        clock += 5
        h.pointerSampled(at: CGPoint(x: tap.x + 50, y: tap.y))
        XCTAssertEqual(warps, [])
    }

    /// Home is where the mouse was before the first touch, not between touches.
    func testHomeSurvivesConsecutiveTouches() {
        let h = makeHandoff()
        tapOnce(h, at: tap)
        let second = CGPoint(x: tap.x + 200, y: tap.y + 100)
        h.touchMovesPointer(to: second, from: tap, holding: true)
        h.touchMovesPointer(to: second, from: second, holding: false)
        clock += 1
        h.pointerSampled(at: CGPoint(x: second.x + 1, y: second.y))
        XCTAssertEqual(warps, [CGPoint(x: home.x + 1, y: home.y)])
    }

    func testSubPointJitterIsNotMovement() {
        let h = makeHandoff()
        tapOnce(h, at: tap)
        clock += 1
        h.pointerSampled(at: CGPoint(x: tap.x + 0.3, y: tap.y))
        XCTAssertEqual(warps, [])
    }

    func testDisabledDoesNothing() {
        let h = makeHandoff(enabled: false)
        tapOnce(h, at: tap)
        XCTAssertFalse(h.touchOwnsPointer)
        clock += 1
        h.pointerSampled(at: CGPoint(x: tap.x + 10, y: tap.y))
        h.returnPointer()
        XCTAssertEqual(warps, [])
    }

    func testDisablingForgetsHome() {
        let h = makeHandoff()
        tapOnce(h, at: tap)
        h.enabled = false
        h.enabled = true
        XCTAssertFalse(h.touchOwnsPointer)
        clock += 1
        h.pointerSampled(at: CGPoint(x: tap.x + 10, y: tap.y))
        XCTAssertEqual(warps, [])
    }

    func testReturnPointerWhenTheSessionEnds() {
        let h = makeHandoff()
        tapOnce(h, at: tap)
        h.returnPointer()
        XCTAssertEqual(warps, [home])
        XCTAssertFalse(h.touchOwnsPointer)
        h.returnPointer()
        XCTAssertEqual(warps, [home])
    }
}
