import CoreGraphics
import XCTest

final class InputRoutingTests: XCTestCase {
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
