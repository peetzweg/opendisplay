import CoreGraphics
import AppKit

/// Turns normalized touch coordinates from the phone into mouse events on a
/// target display. Touch semantics: finger down = left button down, finger
/// move = drag, finger up = button up — i.e. the phone acts as a touchscreen.
final class InputInjector {

    private let displayID: CGDirectDisplayID
    private var isDown = false
    private var penDown = false
    /// True when the current pen contact is a zero-pressure tap (mouse, not tablet).
    private var pencilTapMode = false
    // A real event source (vs nil) plus clickState=1 below: menu tracking
    // treats sourceless/zero-click synthetic clicks as malformed — menus
    // open but their tracking session breaks, leaving zombie menu windows
    // composited on the display (visible in the stream, unclickable).
    private let source = CGEventSource(stateID: .hidSystemState)
    // Synthetic OpenDisplay tablet — conspicuous in logs; not Wacom (0x056A) or
    // typical small driver IDs (1, 2, …).
    private let tabletVendorID: Int64 = 0x0D15       // "ODIS"
    private let tabletProductID: Int64 = 0x0101
    private let deviceID: Int64 = 424242
    private let pointerID: Int64 = 0x0D02              // pen tip
    private let vendorPointerType: Int64 = 0x0802    // Grip Pen (what apps expect)
    private let capabilityMask: Int64 = 0x05C7       // pressure + tilt + rotation + buttons
    private var inRange = false

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    static func ensureAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            Log.info("Accessibility permission missing — prompt requested")
        }
        return trusted
    }

    /// x/y are normalized [0,1] in video space (origin top-left).
    func handleTouch(phase: String, x: Double, y: Double) {
        let bounds = CGDisplayBounds(displayID)   // global CG coords, y-down
        let point = CGPoint(
            x: bounds.origin.x + x * bounds.width,
            y: bounds.origin.y + y * bounds.height
        )

        let type: CGEventType
        switch phase {
        case "began":
            type = .leftMouseDown
            isDown = true
        case "moved":
            type = isDown ? .leftMouseDragged : .mouseMoved
        case "ended", "cancelled":
            guard isDown else { return }   // spurious up without a down
            type = .leftMouseUp
            isDown = false
        default:
            return
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    /// dx/dy in display pixels, natural-scrolling sign from the phone.
    /// Scroll events take points, so convert via the display's pixel scale.
    func handleScroll(dx: Double, dy: Double) {
        let bounds = CGDisplayBounds(displayID)
        let scale = bounds.width > 0 ? Double(CGDisplayPixelsWide(displayID)) / bounds.width : 2
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32((dy / scale).rounded()),
                                  wheel2: Int32((dx / scale).rounded()),
                                  wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    func handleProximity(entering: Bool, x: Double, y: Double) {
        setProximity(entering: entering, at: screenPoint(nx: x, ny: y))
    }

    func handlePencil(phase: String, x: Double, y: Double,
                      pressure: Double, azimuth: Double, altitude: Double,
                      rotation: Double) {
        // TODO: Wire Apple Pencil Pro barrel roll (UIKit rollAngle) once hardware
        // is available for testing. rotation on the wire is always 0 for now.
        _ = rotation
        let p = screenPoint(nx: x, ny: y)
        if phase == "down", !inRange {
            setProximity(entering: true, at: p)
        }
        let (tiltX, tiltY) = deriveTilt(azimuth: azimuth, altitude: altitude)

        switch phase {
        case "down":
            if pressure < 0.01 {
                pencilTapMode = true
                postMouse(type: .leftMouseDown, at: screenPoint(nx: x, ny: y))
            } else {
                pencilTapMode = false
                postTabletPoint(phase: .down, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            }
            penDown = true
        case "move":
            if penDown {
                postTabletPoint(phase: .drag, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            } else {
                postMouse(type: .mouseMoved, at: screenPoint(nx: x, ny: y))
            }
        case "up":
            if pencilTapMode {
                postMouse(type: .leftMouseUp, at: screenPoint(nx: x, ny: y))
                pencilTapMode = false
            } else {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            }
            penDown = false
        case "hover":
            if penDown {
                if pencilTapMode {
                    postMouse(type: .leftMouseUp, at: p)
                    pencilTapMode = false
                } else {
                    postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                    tiltX: tiltX, tiltY: tiltY, rotation: 0)
                }
                penDown = false
            }
            postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                            tiltX: tiltX, tiltY: tiltY, rotation: 0)
        default:
            return
        }
    }

    private func setProximity(entering: Bool, at p: CGPoint) {
        guard entering != inRange else { return }
        inRange = entering
        postProximityEvent(entering: entering, at: p)
    }

    private func postProximityEvent(entering: Bool, at p: CGPoint) {
        guard let ev = CGEvent(source: source) else { return }
        ev.type = .tabletProximity
        ev.location = p
        ev.setIntegerValueField(.tabletProximityEventVendorID, value: tabletVendorID)
        ev.setIntegerValueField(.tabletProximityEventTabletID, value: tabletProductID)
        ev.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
        ev.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        ev.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        ev.setIntegerValueField(.tabletProximityEventPointerType, value: entering ? 1 : 0)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPointerType)
        ev.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
        ev.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        ev.flags = .maskNonCoalesced
        ev.post(tap: .cghidEventTap)
    }

    private enum PointPhase { case down, drag, up, hover }

    private func postTabletPoint(phase: PointPhase, x: Double?, y: Double?,
                                 pressure: Double, tiltX: Double, tiltY: Double,
                                 rotation: Double) {
        let p: CGPoint
        if let nx = x, let ny = y { p = screenPoint(nx: nx, ny: ny) }
        else { p = currentCursor() }

        let type: CGEventType
        switch phase {
        case .down:  type = .leftMouseDown
        case .drag:  type = .leftMouseDragged
        case .up:    type = .leftMouseUp
        case .hover: type = .mouseMoved
        }

        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: p, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventDeltaX, value: 0)
        ev.setIntegerValueField(.mouseEventDeltaY, value: 0)
        ev.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        ev.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        ev.setDoubleValueField(.mouseEventPressure, value: pressure)
        ev.setIntegerValueField(.tabletEventPointPressure, value: Int64((pressure * 65535.0).rounded()))
        ev.setDoubleValueField(.tabletEventTiltX, value: tiltX)
        ev.setDoubleValueField(.tabletEventTiltY, value: tiltY)
        ev.setDoubleValueField(.tabletEventRotation, value: rotation)
        if phase == .down || phase == .up {
            ev.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        ev.flags = .maskNonCoalesced
        ev.post(tap: .cghidEventTap)
    }

    private func postMouse(type: CGEventType, at p: CGPoint) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: p, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: 1)
        ev.flags = .maskNonCoalesced
        ev.post(tap: .cghidEventTap)
    }

    private func deriveTilt(azimuth: Double, altitude: Double) -> (Double, Double) {
        let mag = max(0, Double.pi / 2 - altitude)
        return (sin(azimuth) * mag, cos(azimuth) * mag)
    }

    private func screenPoint(nx: Double, ny: Double) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(x: bounds.minX + nx * bounds.width,
                       y: bounds.minY + ny * bounds.height)
    }

    private func currentCursor() -> CGPoint {
        CGEvent(source: source)?.location ?? .zero
    }
}
