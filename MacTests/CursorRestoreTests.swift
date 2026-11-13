import CoreGraphics
import XCTest

final class CursorRestoreTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()
    private let original = CGPoint(x: 200, y: 300)
    private let remote = CGPoint(x: 1600, y: 500)
    private let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                            CGRect(x: 1440, y: 0, width: 1024, height: 768)]

    func testResumeEventDiscardsSyntheticJumpAndMarksItsSource() throws {
        let trigger = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: remote, mouseButton: .left))
        trigger.setIntegerValueField(.mouseEventDeltaX, value: 2522)
        trigger.setIntegerValueField(.mouseEventDeltaY, value: -874)
        let resume = try XCTUnwrap(CursorRestore.makeResumeEvent(from: trigger, at: original))
        XCTAssertEqual(resume.location, original)
        XCTAssertEqual(resume.getIntegerValueField(.mouseEventDeltaX), 0)
        XCTAssertEqual(resume.getIntegerValueField(.mouseEventDeltaY), 0)
        XCTAssertEqual(resume.getIntegerValueField(.eventSourceUserData), CursorRestore.injectedEventTag)
    }

    func testResumeClickPreservesButtonModifiersAndClickCount() throws {
        let trigger = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
            mouseCursorPosition: remote, mouseButton: .right))
        trigger.flags = [.maskShift, .maskAlternate]
        trigger.setIntegerValueField(.mouseEventClickState, value: 2)
        let resume = try XCTUnwrap(CursorRestore.makeResumeEvent(from: trigger, at: original))
        XCTAssertEqual(resume.type, .rightMouseDown)
        XCTAssertEqual(resume.flags, trigger.flags)
        XCTAssertEqual(resume.getIntegerValueField(.mouseEventClickState), 2)
        XCTAssertEqual(resume.location, original)
    }

    func testDisabledOrNoTouchHasNothingToRestore() {
        var state = CursorRestoreState()
        XCTAssertNil(state.resumeMouse(displays: displays))
    }

    func testRepeatedTapsRestoreExactOriginalPosition() {
        var state = CursorRestoreState()
        state.touch(from: first, phase: "began", cursor: original)
        state.touch(from: first, phase: "ended", cursor: remote)
        state.touch(from: first, phase: "began", cursor: remote)
        state.touch(from: first, phase: "ended", cursor: remote)
        XCTAssertEqual(state.resumeMouse(displays: displays), original)
        XCTAssertNil(state.resumeMouse(displays: displays))
    }

    func testMovementBeforeDownAndScrollTargetingSavePosition() {
        var state = CursorRestoreState()
        state.touch(from: first, phase: "moved", cursor: original)
        state.touch(from: first, phase: "began", cursor: remote)
        state.touch(from: first, phase: "ended", cursor: remote)
        XCTAssertEqual(state.resumeMouse(displays: displays), original)
        // Two-finger targeting sends a standalone move with no matching down/up.
        state.touch(from: first, phase: "moved", cursor: original)
        XCTAssertEqual(state.resumeMouse(displays: displays), original)
    }

    func testDoesNotRestoreDuringDragAndCancellationReleasesIt() {
        var state = CursorRestoreState()
        state.touch(from: first, phase: "began", cursor: original)
        XCTAssertNil(state.resumeMouse(displays: displays))
        state.touch(from: first, phase: "moved", cursor: remote)
        XCTAssertNil(state.resumeMouse(displays: displays))
        state.touch(from: first, phase: "cancelled", cursor: remote)
        XCTAssertEqual(state.resumeMouse(displays: displays), original)
    }

    func testMultipleReceiversShareOneOriginAndWaitForAllDrags() {
        var state = CursorRestoreState()
        state.touch(from: first, phase: "began", cursor: original)
        state.touch(from: second, phase: "began", cursor: remote)
        state.touch(from: first, phase: "ended", cursor: remote)
        XCTAssertNil(state.resumeMouse(displays: displays))
        state.touch(from: second, phase: "ended", cursor: remote)
        XCTAssertEqual(state.resumeMouse(displays: displays), original)
    }

    func testDisconnectClearsHeldTouchAndLastDisconnectDiscardsRestore() {
        var state = CursorRestoreState()
        state.touch(from: first, phase: "began", cursor: original)
        state.touch(from: second, phase: "moved", cursor: remote)
        state.disconnect(first)
        XCTAssertEqual(state.resumeMouse(displays: displays), original)
        state.touch(from: first, phase: "began", cursor: original)
        state.disconnect(first)
        XCTAssertNil(state.resumeMouse(displays: displays))
    }

    func testDisablingClearsPendingRestore() {
        var state = CursorRestoreState()
        state.touch(from: first, phase: "began", cursor: original)
        state.reset()
        XCTAssertNil(state.resumeMouse(displays: displays))
    }

    func testRemovedDisplayClampsToRemainingDisplay() {
        var state = CursorRestoreState()
        state.touch(from: first, phase: "moved", cursor: CGPoint(x: -500, y: -200))
        XCTAssertEqual(state.resumeMouse(displays: [displays[0]]), .zero)
    }

    func testNegativeDisplayCoordinatesArePreserved() {
        var state = CursorRestoreState()
        let point = CGPoint(x: -300, y: -400)
        state.touch(from: first, phase: "moved", cursor: point)
        XCTAssertEqual(state.resumeMouse(
            displays: [CGRect(x: -1440, y: -900, width: 1440, height: 900)]), point)
    }
}
