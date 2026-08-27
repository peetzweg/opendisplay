import XCTest
import CoreGraphics

final class InputInjectorTests: XCTestCase {

    func testTiltMathVector() {
        let upright = InputInjector.tiltVector(altitude: .pi / 2, azimuth: 0)
        XCTAssertEqual(upright.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(upright.y, 0.0, accuracy: 1e-6)

        let flatUp = InputInjector.tiltVector(altitude: 0, azimuth: 0)
        XCTAssertEqual(flatUp.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(flatUp.y, 1.0, accuracy: 1e-6)

        let flatRight = InputInjector.tiltVector(altitude: 0, azimuth: .pi / 2)
        XCTAssertEqual(flatRight.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(flatRight.y, 0.0, accuracy: 1e-6)

        let overPitched = InputInjector.tiltVector(altitude: 2.0, azimuth: 0)
        XCTAssertEqual(overPitched.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(overPitched.y, 0.0, accuracy: 1e-6)
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

        injector.handleTouch(phase: "began", x: 0.3, y: 0.3)
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "cancelled", x: 0.4, y: 0.4)
        XCTAssertFalse(injector.isDown)
    }

    func testScrollHandling() {
        let injector = InputInjector(displayID: CGMainDisplayID())
        injector.handleScroll(dx: 10, dy: -20)
    }

    func testMirrorTargetDisplayInputInjection() {
        let mainID = CGMainDisplayID()
        let injector = InputInjector(displayID: mainID)
        XCTAssertFalse(injector.isDown)

        injector.handleTouch(phase: "began", x: 0.2, y: 0.2)
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "ended", x: 0.2, y: 0.2)
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

    func testAccessibilityPermissionCheck() {
        _ = InputInjector.ensureAccessibilityPermission()
    }
}
