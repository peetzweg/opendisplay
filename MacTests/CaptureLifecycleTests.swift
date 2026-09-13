import XCTest

final class CaptureLifecycleTests: XCTestCase {
    func testInputIsAllowedWhileRunningAndRecoveryButBlockedDuringPause() {
        var state = CaptureLifecycleState()
        XCTAssertTrue(state.allowsInput) // Initial capture/recovery window.
        XCTAssertTrue(state.captureStarted())
        XCTAssertTrue(state.allowsInput)
        XCTAssertTrue(state.requestPause())
        XCTAssertFalse(state.allowsInput)
        XCTAssertTrue(state.pauseCompleted())
        XCTAssertFalse(state.allowsInput)
        XCTAssertTrue(state.requestResume())
        XCTAssertFalse(state.allowsInput)
        XCTAssertTrue(state.ownsCaptureStop)
        XCTAssertTrue(state.captureStarted())
        XCTAssertTrue(state.allowsInput)
        XCTAssertFalse(state.ownsCaptureStop)
    }

    func testUnexpectedStopRecoversButIntentionalPauseDoesNotRetry() {
        var running = CaptureLifecycleState()
        XCTAssertTrue(running.captureStarted())
        XCTAssertTrue(running.unexpectedStop())
        XCTAssertEqual(running.phase, .recovering)
        XCTAssertTrue(running.shouldRetryCapture)

        var paused = CaptureLifecycleState()
        XCTAssertTrue(paused.requestPause())
        XCTAssertTrue(paused.pauseCompleted())
        XCTAssertFalse(paused.unexpectedStop())
        XCTAssertFalse(paused.shouldRetryCapture)

        var stopped = CaptureLifecycleState()
        stopped.stop()
        XCTAssertTrue(stopped.ownsCaptureStop)
        XCTAssertFalse(stopped.unexpectedStop())
        XCTAssertFalse(stopped.shouldRetryCapture)
    }

    func testRecoveryBudgetIsBoundedAndResettable() {
        var budget = CaptureRecoveryBudget(maximumAttempts: 2)
        XCTAssertTrue(budget.recordFailure())
        XCTAssertFalse(budget.recordFailure())
        budget.reset()
        XCTAssertEqual(budget.failedAttempts, 0)
        XCTAssertTrue(budget.recordFailure())
    }

    func testRecoveryReattachesWhenTargetDisplayStillExists() {
        XCTAssertEqual(CaptureRecoveryPath.resolve(mode: .mirror, targetDisplayAvailable: true),
                       .reattachMirrorCapture)
        XCTAssertEqual(CaptureRecoveryPath.resolve(mode: .mirror, targetDisplayAvailable: false),
                       .rebuildMirrorPipeline)
        XCTAssertEqual(CaptureRecoveryPath.resolve(mode: .extend, targetDisplayAvailable: true),
                       .reattachExtendCapture)
        XCTAssertEqual(CaptureRecoveryPath.resolve(mode: .extend, targetDisplayAvailable: false),
                       .rebuildExtendPipeline)
    }

    func testSuccessfulModeReplacementSynchronizesStalePausedReceiverToRunning() {
        var oldSession = CaptureLifecycleState()
        XCTAssertTrue(oldSession.captureStarted())
        XCTAssertTrue(oldSession.requestPause())
        XCTAssertEqual(oldSession.receiverDisplayState, .paused)

        // A mode switch creates a replacement sender while the receiver keeps
        // the old session's last semantic display state until told otherwise.
        var replacementSession = CaptureLifecycleState()
        XCTAssertTrue(replacementSession.captureStarted())
        XCTAssertEqual(replacementSession.receiverDisplayState, .running)
    }
}

final class DisplayStateTests: XCTestCase {
    func testDisplayStateDecodesKnownAdditiveMessagesAndIgnoresUnknownValues() {
        XCTAssertEqual(DisplayState.decode(messageType: "displayState", value: "paused"), .paused)
        XCTAssertEqual(DisplayState.decode(messageType: "displayState", value: "running"), .running)
        XCTAssertNil(DisplayState.decode(messageType: "gesture", value: "paused"))
        XCTAssertNil(DisplayState.decode(messageType: "displayState", value: "stalled"))
        XCTAssertNil(DisplayState.decode(messageType: "displayState", value: nil))
    }
}
