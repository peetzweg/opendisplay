import XCTest
import CoreGraphics

final class TrackpadTuningTests: XCTestCase {
    func testPointerAndScrollSpeedsAreIndependent() {
        XCTAssertEqual(TrackpadTuning.pointer(x: 3, y: 2, speed: 2), TrackpadDelta(dx: 6, dy: -4))
        XCTAssertEqual(TrackpadTuning.scroll(x: 1, y: 3, speed: 0.5, reversed: false), TrackpadDelta(dx: 0.5, dy: 1.5))
        XCTAssertEqual(TrackpadTuning.scroll(x: 1, y: 3, speed: 0.5, reversed: true), TrackpadDelta(dx: -0.5, dy: -1.5))
        XCTAssertNil(TrackpadTuning.pointer(x: .nan, y: 0, speed: 2))
        XCTAssertEqual(TrackpadTuning.pointer(x: 2, y: 0, speed: .infinity)?.dx, 2.5)
    }
    func testVerticalGestureKeepsAxisAndReversesImmediatelyWithoutEndJump() {
        var gesture = TrackpadScrollGesture()
        let phases: [HardwareInput.PreciseScroll.Phase] = [.began, .changed, .changed, .changed, .ended]
        let positions = [0.0, 10, 18, 15, 0]
        let events = zip(phases, positions).compactMap {
            gesture.update(phase: $0, translation: .init(dx: 0, dy: $1), speed: 1, reversed: false, modifiers: 0)
        }
        XCTAssertEqual(events.map(\.dy), [0, 10, 8, -3, 0])
        XCTAssertTrue(events.allSatisfy { $0.dx == 0 })
        XCTAssertEqual(events.last?.phase, .ended)
    }
    func testHorizontalAndDiagonalTranslationPreserveBothAxes() {
        var gesture = TrackpadScrollGesture()
        _ = gesture.update(phase: .began, translation: .init(dx: 0, dy: 0), speed: 0.5, reversed: true, modifiers: 0)
        let first = gesture.update(phase: .changed, translation: .init(dx: -10, dy: 4), speed: 0.5, reversed: true, modifiers: 0)!
        XCTAssertEqual(first.dx, 5); XCTAssertEqual(first.dy, -2)
        let reversed = gesture.update(phase: .changed, translation: .init(dx: -9, dy: 3), speed: 0.5, reversed: true, modifiers: 0)!
        XCTAssertEqual(reversed.dx, -0.5); XCTAssertEqual(reversed.dy, 0.5)
    }
    func testGestureLifecycleDoesNotInventTimeoutsOrCatchupMotion() {
        var gesture = TrackpadScrollGesture()
        XCTAssertNil(gesture.update(phase: .changed, translation: .init(dx: 0, dy: 10), speed: 1, reversed: false, modifiers: 0))
        _ = gesture.update(phase: .began, translation: .init(dx: 0, dy: 3), speed: 1, reversed: false, modifiers: 0)
        XCTAssertNil(gesture.update(phase: .changed, translation: .init(dx: 0, dy: 3), speed: 1, reversed: false, modifiers: 0))
        XCTAssertEqual(gesture.cancel(modifiers: 0)?.phase, .cancelled)
        XCTAssertNil(gesture.cancel(modifiers: 0))
        let next = gesture.update(phase: .began, translation: .init(dx: 0, dy: -1), speed: 1, reversed: false, modifiers: 0)
        XCTAssertEqual(next?.dy, -1)
        XCTAssertEqual(gesture.update(phase: .changed, translation: .init(dx: 0, dy: .nan), speed: 1, reversed: false, modifiers: 0)?.phase, .cancelled)
    }
    func testNewGestureClearsRemainderEvenIfEndWasLost() {
        var events: [CGEvent] = []
        let driver = HardwareInputInjector(displayID: 1, repeats: false, isTrusted: { true }, sink: { events.append($0) })
        driver.preciseScroll(.init(dx: 0, dy: 0.75, mod: 0, phase: .began))
        driver.preciseScroll(.init(dx: 0, dy: -1, mod: 0, phase: .began))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -1)
    }
    func testScrollUsesDesktopPointsAndAccumulatesFractions() {
        var events: [CGEvent] = []
        let driver = HardwareInputInjector(displayID: 1, repeats: false, cursorPosition: { CGPoint(x: 25, y: 30) }, isTrusted: { true }, sink: { events.append($0) })
        for index in 0..<4 {
            driver.preciseScroll(.init(dx: 0, dy: 0.25, mod: 0, phase: index == 0 ? .began : .changed))
        }
        XCTAssertEqual(events.last?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 1)
        XCTAssertEqual(events.last?.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
        XCTAssertEqual(events.first?.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
        XCTAssertEqual(events.first?.location, CGPoint(x: 25, y: 30))
        let count = events.count
        driver.preciseScroll(.init(dx: 0, dy: 0, mod: 0, phase: .ended))
        XCTAssertEqual(events.count, count)
    }
    func testScrollResetEndsGestureAndClearsOldFraction() {
        var events: [CGEvent] = []
        let driver = HardwareInputInjector(displayID: 1, repeats: false, cursorPosition: { CGPoint(x: 25, y: 30) }, isTrusted: { true }, sink: { events.append($0) })
        driver.preciseScroll(.init(dx: 0, dy: 0.75, mod: 0, phase: .began))
        driver.releaseAll()
        XCTAssertTrue(events.isEmpty)
        driver.preciseScroll(.init(dx: 0, dy: -1, mod: 0, phase: .began))
        XCTAssertEqual(events.last?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -1)
        let count = events.count
        driver.preciseScroll(.init(dx: 0, dy: 1, mod: 0, phase: .ended))
        driver.preciseScroll(.init(dx: .infinity, dy: 0, mod: 0, phase: .changed))
        XCTAssertEqual(events.count, count)
    }
}
