import CoreGraphics
import XCTest

final class InputInjectorTests: XCTestCase {

    func testDeriveTiltMath() {
        // Upright pen (altitude = pi/2)
        let (tiltX1, tiltY1) = InputInjector.deriveTilt(azimuth: 0, altitude: Double.pi / 2)
        XCTAssertEqual(tiltX1, 0, accuracy: 1e-5)
        XCTAssertEqual(tiltY1, 0, accuracy: 1e-5)

        // Flat pen facing right (azimuth = pi/2, altitude = 0)
        let (tiltX2, tiltY2) = InputInjector.deriveTilt(azimuth: Double.pi / 2, altitude: 0)
        XCTAssertEqual(tiltX2, 1.0, accuracy: 1e-5)
        XCTAssertEqual(tiltY2, 0, accuracy: 1e-5)

        // Flat pen facing up (azimuth = 0, altitude = 0)
        let (tiltX3, tiltY3) = InputInjector.deriveTilt(azimuth: 0, altitude: 0)
        XCTAssertEqual(tiltX3, 0, accuracy: 1e-5)
        XCTAssertEqual(tiltY3, 1.0, accuracy: 1e-5)

        // Altitude clamping (> pi/2 or < 0)
        let (tiltX4, tiltY4) = InputInjector.deriveTilt(azimuth: Double.pi / 4, altitude: Double.pi)
        XCTAssertEqual(tiltX4, 0, accuracy: 1e-5)
        XCTAssertEqual(tiltY4, 0, accuracy: 1e-5)
    }

    func testTouchStateMachine() {
        let injector = InputInjector(displayID: CGMainDisplayID())
        XCTAssertFalse(injector.isDown)

        injector.handleTouch(phase: "began", x: 0.5, y: 0.5)
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "moved", x: 0.6, y: 0.6)
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "ended", x: 0.6, y: 0.6)
        XCTAssertFalse(injector.isDown)
    }

    func testRightClickHandling() {
        let injector = InputInjector(displayID: CGMainDisplayID())
        XCTAssertFalse(injector.isDown)

        injector.handleTouch(phase: "began", x: 0.3, y: 0.3, button: "right")
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "moved", x: 0.35, y: 0.35, button: "right")
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "ended", x: 0.35, y: 0.35, button: "right")
        XCTAssertFalse(injector.isDown)
    }

    func testTouchCancelled() {
        let injector = InputInjector(displayID: CGMainDisplayID())
        injector.handleTouch(phase: "began", x: 0.4, y: 0.4)
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "cancelled", x: 0.4, y: 0.4)
        XCTAssertFalse(injector.isDown)
    }

    func testPencilStateMachineAndProximity() {
        let injector = InputInjector(displayID: CGMainDisplayID())
        XCTAssertFalse(injector.penDown)
        XCTAssertFalse(injector.inRange)

        injector.handlePencil(phase: "down", x: 0.2, y: 0.2, pressure: 0.5, azimuth: 0, altitude: 0.5, rotation: 0)
        XCTAssertTrue(injector.penDown)
        XCTAssertTrue(injector.inRange)

        injector.handlePencil(phase: "move", x: 0.25, y: 0.25, pressure: 0.8, azimuth: 0, altitude: 0.5, rotation: 0)
        XCTAssertTrue(injector.penDown)

        injector.handlePencil(phase: "up", x: 0.25, y: 0.25, pressure: 0, azimuth: 0, altitude: 0.5, rotation: 0)
        XCTAssertFalse(injector.penDown)
        XCTAssertTrue(injector.inRange)

        injector.handlePencil(phase: "hover", x: 0.3, y: 0.3, pressure: 0, azimuth: 0, altitude: 0.5, rotation: 0)
        XCTAssertFalse(injector.penDown)
        XCTAssertTrue(injector.inRange)

        injector.handleProximity(entering: false, x: 0.3, y: 0.3)
        XCTAssertFalse(injector.inRange)
    }

    func testResetCleansUpAllState() {
        let injector = InputInjector(displayID: CGMainDisplayID())
        injector.handleTouch(phase: "began", x: 0.1, y: 0.1)
        injector.handlePencil(phase: "down", x: 0.1, y: 0.1, pressure: 0.5, azimuth: 0, altitude: 0.5, rotation: 0)
        XCTAssertTrue(injector.isDown)
        XCTAssertTrue(injector.penDown)
        XCTAssertTrue(injector.inRange)

        injector.reset()
        XCTAssertFalse(injector.isDown)
        XCTAssertFalse(injector.penDown)
        XCTAssertFalse(injector.inRange)
    }

    func testAccessibilityPermissionCheck() {
        _ = InputInjector.ensureAccessibilityPermission()
    }
}
