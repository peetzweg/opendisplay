import CoreGraphics
import XCTest

final class InputRoutingTests: XCTestCase {
    func testThreeFingerDirectionsRequireMeaningfulPredominantMovement() {
        XCTAssertNil(ReceiverGesture.swipe(translationX: 0, translationY: -79.9))
        XCTAssertEqual(ReceiverGesture.swipe(translationX: 0, translationY: -80), .missionControl)
        XCTAssertEqual(ReceiverGesture.swipe(translationX: 50, translationY: -80), .missionControl)
        XCTAssertNil(ReceiverGesture.swipe(translationX: 60, translationY: -80))
        XCTAssertEqual(ReceiverGesture.swipe(translationX: 0, translationY: 80), .appExpose)
        XCTAssertEqual(ReceiverGesture.swipe(translationX: -80, translationY: 0), .nextSpace)
        XCTAssertEqual(ReceiverGesture.swipe(translationX: 80, translationY: 0), .previousSpace)
        XCTAssertNil(ReceiverGesture.swipe(translationX: 75, translationY: 70))
    }

    func testFourFingerSpreadAndPinchRequireMeaningfulChange() {
        XCTAssertNil(ReceiverGesture.spreadGesture(start: 100, current: 119))
        XCTAssertNil(ReceiverGesture.spreadGesture(start: 100, current: 130))
        XCTAssertEqual(ReceiverGesture.spreadGesture(start: 100, current: 140), .showDesktop)
        XCTAssertEqual(ReceiverGesture.spreadGesture(start: 100, current: 60), .launchpad)
    }

    func testPinchSpreadGeometryAcceptsFourOrFiveActivePositionsOnly() {
        XCTAssertNotNil(ReceiverGestureGeometry.meanPairwiseDistance(
            [(0, 0), (10, 0), (0, 10), (10, 10)]))
        XCTAssertNotNil(ReceiverGestureGeometry.meanPairwiseDistance(
            [(0, 0), (10, 0), (0, 10), (10, 10), (5, 5)]))
        XCTAssertNil(ReceiverGestureGeometry.meanPairwiseDistance([(0, 0), (10, 0), (0, 10)]))
        XCTAssertNil(ReceiverGestureGeometry.meanPairwiseDistance(
            [(0, 0), (10, 0), (0, 10), (10, 10), (5, 5), (20, 20)]))
    }

    func testFourTouchPinchAndSpreadClassifySystemGestures() {
        XCTAssertEqual(classifySpread(touchCount: 4, from: 100, to: 140), .showDesktop)
        XCTAssertEqual(classifySpread(touchCount: 4, from: 100, to: 60), .launchpad)
    }

    func testFiveTouchPinchAndSpreadClassifySystemGestures() {
        XCTAssertEqual(classifySpread(touchCount: 5, from: 100, to: 140), .showDesktop)
        XCTAssertEqual(classifySpread(touchCount: 5, from: 100, to: 60), .launchpad)
    }

    func testThreeTouchPinchLikeMotionCannotStartPinchSpreadSession() {
        var session = ReceiverGestureSpreadSession()
        XCTAssertNil(session.update(touchCount: 3, spread: 100))
        XCTAssertNil(session.update(touchCount: 3, spread: 160))
        XCTAssertNil(session.activeTouchCount)
        XCTAssertFalse(session.hasEmitted)
    }

    func testPinchSpreadMovementBelowThresholdDoesNotEmit() {
        var session = ReceiverGestureSpreadSession()
        XCTAssertNil(session.update(touchCount: 4, spread: 100))
        XCTAssertNil(session.update(touchCount: 4, spread: 135))
        XCTAssertEqual(session.update(touchCount: 4, spread: 136), .showDesktop)
    }

    func testFourToFiveTouchTransitionAccumulatesMovementWithoutDuplicate() {
        var session = ReceiverGestureSpreadSession()
        XCTAssertNil(session.update(touchCount: 4, spread: 100))
        XCTAssertNil(session.update(touchCount: 4, spread: 125))
        XCTAssertNil(session.update(touchCount: 5, spread: 250))
        XCTAssertEqual(session.update(touchCount: 5, spread: 265), .showDesktop)
        XCTAssertNil(session.update(touchCount: 5, spread: 300))
        XCTAssertNil(session.update(touchCount: 4, spread: 180))
        XCTAssertTrue(session.hasEmitted)
    }

    func testFiveToFourTouchTransitionAccumulatesMovementWithoutDuplicate() {
        var session = ReceiverGestureSpreadSession()
        XCTAssertNil(session.update(touchCount: 5, spread: 100))
        XCTAssertNil(session.update(touchCount: 5, spread: 75))
        XCTAssertNil(session.update(touchCount: 4, spread: 250))
        XCTAssertEqual(session.update(touchCount: 4, spread: 235), .launchpad)
        XCTAssertNil(session.update(touchCount: 4, spread: 200))
        XCTAssertTrue(session.hasEmitted)
    }

    func testDroppingBelowFourTouchesCancelsTheSession() {
        var session = ReceiverGestureSpreadSession()
        XCTAssertNil(session.update(touchCount: 4, spread: 100))
        XCTAssertNil(session.update(touchCount: 4, spread: 120))
        XCTAssertNil(session.update(touchCount: 3, spread: 0))
        XCTAssertTrue(session.isCancelled)
        XCTAssertNil(session.activeTouchCount)
        XCTAssertNil(session.update(touchCount: 4, spread: 180))
        XCTAssertFalse(session.hasEmitted)
    }

    func testMoreThanFiveTouchesCancelsWithoutEmitting() {
        var session = ReceiverGestureSpreadSession()
        XCTAssertNil(session.update(touchCount: 5, spread: 100))
        XCTAssertNil(session.update(touchCount: 6, spread: 180))
        XCTAssertTrue(session.isCancelled)
        XCTAssertFalse(session.hasEmitted)
        XCTAssertNil(session.update(touchCount: 5, spread: 200))
    }

    func testPinchSpreadGeometryDoesNotDependOnWhichPointIsTheThumb() {
        let points = [(x: 0.0, y: 0.0), (x: 20.0, y: 0.0), (x: 0.0, y: 20.0),
                      (x: 20.0, y: 20.0), (x: 10.0, y: 10.0)]
        let original = ReceiverGestureGeometry.meanPairwiseDistance(points)
        let firstFour = ReceiverGestureGeometry.meanPairwiseDistance(Array(points.prefix(4)))
        let reordered = ReceiverGestureGeometry.meanPairwiseDistance(
            [points[4], points[2], points[0], points[3], points[1]])
        XCTAssertEqual(original, reordered)
        XCTAssertNotEqual(original, firstFour)
    }

    private func classifySpread(touchCount: Int, from start: Double, to end: Double) -> ReceiverGesture? {
        var session = ReceiverGestureSpreadSession()
        _ = session.update(touchCount: touchCount, spread: start)
        return session.update(touchCount: touchCount, spread: end)
    }

    func testGestureRoutingAllowsKnownNamesOnlyWhenInputIsEnabled() {
        for gesture in ReceiverGesture.allCases {
            XCTAssertTrue(ReceiverGesture.shouldRoute(name: gesture.rawValue, inputAllowed: true))
            XCTAssertFalse(ReceiverGesture.shouldRoute(name: gesture.rawValue, inputAllowed: false))
        }
        XCTAssertFalse(ReceiverGesture.shouldRoute(name: "unknownGesture", inputAllowed: true))
    }

    func testGestureEmissionGateAllowsOnlyOneMessagePerGesture() {
        var gate = GestureEmissionGate()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        gate.reset()
        XCTAssertTrue(gate.claim())
    }

    func testTakingGestureOwnershipReleasesPostedPressAndDiscardsPendingPress() {
        XCTAssertEqual(ReceiverTouchOwnership.cancellationActions(downWasSent: true),
                       [.sendCancellation, .discardPendingPress])
        XCTAssertEqual(ReceiverTouchOwnership.cancellationActions(downWasSent: false),
                       [.discardPendingPress])
    }

    func testSystemGesturesMapToVerifiedMacShortcuts() {
        let missionControl = SystemGestureShortcutMapping.shortcut(for: .missionControl)
        XCTAssertEqual(missionControl.keyCode, 126)
        XCTAssertEqual(missionControl.flags, [.maskControl, .maskSecondaryFn])

        let appExpose = SystemGestureShortcutMapping.shortcut(for: .appExpose)
        XCTAssertEqual(appExpose.keyCode, 125)
        XCTAssertEqual(appExpose.flags, [.maskControl, .maskSecondaryFn])
        let nextSpace = SystemGestureShortcutMapping.shortcut(for: .nextSpace)
        XCTAssertEqual(nextSpace.keyCode, 124)
        XCTAssertEqual(nextSpace.flags, [.maskControl, .maskSecondaryFn])
        let previousSpace = SystemGestureShortcutMapping.shortcut(for: .previousSpace)
        XCTAssertEqual(previousSpace.keyCode, 123)
        XCTAssertEqual(previousSpace.flags, [.maskControl, .maskSecondaryFn])
        let showDesktop = SystemGestureShortcutMapping.shortcut(for: .showDesktop)
        XCTAssertEqual(showDesktop.keyCode, 103)
        XCTAssertEqual(showDesktop.flags, .maskSecondaryFn)

        let legacyLaunchpad = SystemGestureShortcutMapping.shortcut(for: .launchpad, macOSMajorVersion: 15)
        XCTAssertEqual(legacyLaunchpad.keyCode, 118)
        XCTAssertEqual(legacyLaunchpad.flags, [])
        XCTAssertEqual(SystemGestureShortcutMapping.shortcut(for: .launchpad, macOSMajorVersion: 26).keyCode, 0)
    }

    func testNormalizedCoordinatesMapIntoBoundsWithNegativeOrigin() {
        let bounds = CGRect(x: -1_920, y: -240, width: 1_920, height: 1_080)

        XCTAssertEqual(InputCoordinateMapper.point(x: 0, y: 0, in: bounds),
                       CGPoint(x: -1_920, y: -240))
        XCTAssertEqual(InputCoordinateMapper.point(x: 0.5, y: 0.5, in: bounds),
                       CGPoint(x: -960, y: 300))
        XCTAssertEqual(InputCoordinateMapper.point(x: 1, y: 1, in: bounds),
                       CGPoint(x: 0, y: 840))
    }

    func testMirrorTargetsCapturedPhysicalDisplay() {
        XCTAssertEqual(InputTargetResolver.displayID(mode: .mirror,
                                                      mirrorDisplayID: 42,
                                                      virtualDisplayID: 99), 42)
    }

    func testExtendTargetsVirtualDisplay() {
        XCTAssertEqual(InputTargetResolver.displayID(mode: .extend,
                                                      mirrorDisplayID: 42,
                                                      virtualDisplayID: 99), 99)
    }

    func testExtendWithoutVirtualDisplayHasNoTarget() {
        XCTAssertNil(InputTargetResolver.displayID(mode: .extend,
                                                   mirrorDisplayID: 42,
                                                   virtualDisplayID: nil))
    }

    func testAllowInputDefaultsOnAndCanBeDisabledOrEnabled() {
        let suite = "InputRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(InputPolicy.allowsInput(defaults: defaults))
        defaults.set(false, forKey: InputPolicy.defaultsKey)
        XCTAssertFalse(InputPolicy.allowsInput(defaults: defaults))
        defaults.set(true, forKey: InputPolicy.defaultsKey)
        XCTAssertTrue(InputPolicy.allowsInput(defaults: defaults))
    }

    func testDisabledInputPolicySkipsReceiverInputHandling() {
        let suite = "InputRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: InputPolicy.defaultsKey)
        var injectionCount = 0

        if InputPolicy.allowsInput(defaults: defaults) { injectionCount += 1 }

        XCTAssertEqual(injectionCount, 0)
    }
}
