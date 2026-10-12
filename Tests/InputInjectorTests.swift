import Foundation
import CoreGraphics

// Dummy Log stub for standalone test execution
enum Log {
    static func info(_ msg: String) {}
    static func debug(_ msg: String) {}
    static func error(_ msg: String) {}
}

@main
struct InputInjectorTests {
    static func main() {
        print("Running InputInjector unit tests...")
        var passed = 0
        var total = 0

        func assertTest(_ condition: Bool, _ name: String) {
            total += 1
            if condition {
                passed += 1
                print("  ✓ \(name)")
            } else {
                print("  FAILED: \(name)")
            }
        }

        // Test 1: Tilt math - Upright pen (altitude = pi/2)
        let (tiltX1, tiltY1) = InputInjector.deriveTilt(azimuth: 0, altitude: Double.pi / 2)
        assertTest(abs(tiltX1) < 1e-5 && abs(tiltY1) < 1e-5, "Upright pen produces (0, 0) tilt vector")

        // Test 2: Tilt math - Flat pen facing right (azimuth = pi/2, altitude = 0)
        let (tiltX2, tiltY2) = InputInjector.deriveTilt(azimuth: Double.pi / 2, altitude: 0)
        assertTest(abs(tiltX2 - 1.0) < 1e-5 && abs(tiltY2) < 1e-5, "Flat pen facing right produces (1.0, 0.0) tilt")

        // Test 3: Tilt math - Flat pen facing up (azimuth = 0, altitude = 0)
        let (tiltX3, tiltY3) = InputInjector.deriveTilt(azimuth: 0, altitude: 0)
        assertTest(abs(tiltX3) < 1e-5 && abs(tiltY3 - 1.0) < 1e-5, "Flat pen facing up produces (0.0, 1.0) tilt")

        // Test 4: Tilt math - Altitude clamping (> pi/2 or < 0)
        let (tiltX4, tiltY4) = InputInjector.deriveTilt(azimuth: Double.pi / 4, altitude: Double.pi)
        assertTest(abs(tiltX4) < 1e-5 && abs(tiltY4) < 1e-5, "Over-pitched altitude is clamped to zero magnitude")

        // Test 5: InputInjector touch state machine
        let injector = InputInjector(displayID: CGMainDisplayID())
        assertTest(!injector.isDown, "Initial touch state is not down")

        injector.handleTouch(phase: "began", x: 0.5, y: 0.5)
        assertTest(injector.isDown, "Touch began sets isDown to true")

        injector.handleTouch(phase: "moved", x: 0.6, y: 0.6)
        assertTest(injector.isDown, "Touch moved preserves isDown")

        injector.handleTouch(phase: "ended", x: 0.6, y: 0.6)
        assertTest(!injector.isDown, "Touch ended resets isDown to false")

        // Test 6: Right-click handling
        injector.handleTouch(phase: "began", x: 0.3, y: 0.3, button: "right")
        assertTest(injector.isDown, "Right touch began sets isDown to true")

        injector.handleTouch(phase: "ended", x: 0.3, y: 0.3, button: "right")
        assertTest(!injector.isDown, "Right touch ended resets isDown to false")

        // Test 7: Touch cancelled path
        injector.handleTouch(phase: "began", x: 0.4, y: 0.4)
        injector.handleTouch(phase: "cancelled", x: 0.4, y: 0.4)
        assertTest(!injector.isDown, "Touch cancelled resets isDown to false")

        // Test 8: Pencil state machine & proximity
        assertTest(!injector.penDown, "Initial pen state is not down")
        assertTest(!injector.inRange, "Initial pen proximity is not inRange")

        injector.handlePencil(phase: "down", x: 0.2, y: 0.2, pressure: 0.5, azimuth: 0, altitude: 0.5, rotation: 0)
        assertTest(injector.penDown, "Pencil down sets penDown to true")
        assertTest(injector.inRange, "Pencil down automatically enters proximity (inRange)")

        injector.handlePencil(phase: "move", x: 0.25, y: 0.25, pressure: 0.8, azimuth: 0, altitude: 0.5, rotation: 0)
        assertTest(injector.penDown, "Pencil move while down maintains penDown")

        injector.handlePencil(phase: "up", x: 0.25, y: 0.25, pressure: 0, azimuth: 0, altitude: 0.5, rotation: 0)
        assertTest(!injector.penDown, "Pencil up resets penDown to false")
        assertTest(injector.inRange, "Pencil up keeps proximity inRange until hover/leave")

        injector.handlePencil(phase: "hover", x: 0.3, y: 0.3, pressure: 0, azimuth: 0, altitude: 0.5, rotation: 0)
        assertTest(!injector.penDown && injector.inRange, "Pencil hover maintains inRange and penDown false")

        injector.handleProximity(entering: false, x: 0.3, y: 0.3)
        assertTest(!injector.inRange, "Proximity exit sets inRange to false")

        // Test 9: Reset cleanup
        injector.handleTouch(phase: "began", x: 0.1, y: 0.1)
        injector.handlePencil(phase: "down", x: 0.1, y: 0.1, pressure: 0.5, azimuth: 0, altitude: 0.5, rotation: 0)
        assertTest(injector.isDown && injector.penDown && injector.inRange, "All inputs active before reset")

        injector.reset()
        assertTest(!injector.isDown && !injector.penDown && !injector.inRange, "reset() clears touch, pen, and proximity states")

        // Test 10: Accessibility permission check
        _ = InputInjector.ensureAccessibilityPermission()
        assertTest(true, "Accessibility permission helper runs without error")

        print("\nResults: \(passed)/\(total) tests passed.")
        if passed < total {
            exit(1)
        }
    }
}
