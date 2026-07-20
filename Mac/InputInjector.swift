import CoreGraphics
import AppKit

/// Turns normalized input from the phone into mouse / tablet events on the
/// target display. Pencil events use tablet point mouse subtypes; fingers use
/// the legacy left-button mouse path.
final class InputInjector {

    private let displayID: CGDirectDisplayID
    private let source: CGEventSource
    private var inRange = false
    private var penDown = false
    private var fingerDown = false
    private var eraser = false
    /// True when the current pen contact is a zero-pressure tap (mouse, not tablet).
    private var pencilTapMode = false

    private let deviceID: Int64 = 1

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        if let s = CGEventSource(stateID: .hidSystemState) {
            source = s
        } else if let s = CGEventSource(stateID: .combinedSessionState) {
            source = s
        } else {
            fatalError("Could not create CGEventSource")
        }
    }

    static func ensureAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            Log.info("Accessibility permission missing — prompt requested")
        }
        return trusted
    }

    // MARK: - Legacy finger wire (`touch` / `scroll`)

    /// x/y are normalized [0,1] in video space (origin top-left).
    func handleTouch(phase: String, x: Double, y: Double) {
        let point = screenPoint(nx: x, ny: y)

        let type: CGEventType
        switch phase {
        case "began":
            type = .leftMouseDown
            fingerDown = true
        case "moved":
            type = fingerDown ? .leftMouseDragged : .mouseMoved
        case "ended", "cancelled":
            guard fingerDown else { return }
            type = .leftMouseUp
            fingerDown = false
        default:
            return
        }

        postMouse(type: type, at: point, button: .left)
    }

    /// dx/dy in display pixels, natural-scrolling sign from the phone.
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

    // MARK: - Pencil wire

    func handlePencil(phase: PencilPhase, x: Double, y: Double,
                      pressure: Double, azimuth: Double, altitude: Double,
                      rotation: Double) {
        let (tiltX, tiltY) = deriveTilt(azimuth: azimuth, altitude: altitude)

        switch phase {
        case .down:
            if pressure < 0.01 {
                pencilTapMode = true
                postMouse(type: .leftMouseDown, at: screenPoint(nx: x, ny: y), button: .left)
            } else {
                pencilTapMode = false
                postTabletPoint(phase: .down, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: rotation)
            }
            penDown = true
        case .move:
            pencilTapMode = false
            if penDown {
                postTabletPoint(phase: .drag, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: rotation)
            } else {
                postMouse(type: .mouseMoved, at: screenPoint(nx: x, ny: y), button: .left)
            }
        case .up:
            if pencilTapMode {
                postMouse(type: .leftMouseUp, at: screenPoint(nx: x, ny: y), button: .left)
                pencilTapMode = false
            } else {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: rotation)
            }
            penDown = false
        case .hover:
            postMouse(type: .mouseMoved, at: screenPoint(nx: x, ny: y), button: .left)
        }
    }

    func handleProximity(entering: Bool, eraser: Bool) {
        // Track pen-in-range internally. Posting tabletProximity CGEvents causes
        // macOS to interpret rapid enter/exit as system gestures (Show Desktop).
        if entering {
            if !inRange || eraser != self.eraser {
                self.eraser = eraser
                inRange = true
            }
        } else if inRange {
            inRange = false
        }
    }

    func handleBarrelButton(down: Bool, x: Double?, y: Double?) {
        postRightClick(down: down, x: x, y: y)
    }

    // MARK: - CGEvent posting

    private enum PointPhase { case down, drag, up }

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
        }

        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: p, mouseButton: .left) else { return }
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

    private func postMouse(type: CGEventType, at p: CGPoint, button: CGMouseButton) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: p, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: 1)
        ev.flags = .maskNonCoalesced
        ev.post(tap: .cghidEventTap)
    }

    private func postRightClick(down: Bool, x: Double?, y: Double?) {
        let p: CGPoint
        if let nx = x, let ny = y { p = screenPoint(nx: nx, ny: ny) }
        else { p = currentCursor() }
        let type: CGEventType = down ? .rightMouseDown : .rightMouseUp
        postMouse(type: type, at: p, button: .right)
    }

    private func deriveTilt(azimuth: Double, altitude: Double) -> (Double, Double) {
        let mag = max(0, Double.pi / 2 - altitude)
        return (sin(azimuth) * mag, cos(azimuth) * mag)
    }

    /// Map video-normalized coords (origin top-left on the iPad) to global
    /// screen points on the virtual display.
    private func screenPoint(nx: Double, ny: Double) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(x: bounds.minX + nx * bounds.width,
                       y: bounds.minY + ny * bounds.height)
    }

    private func currentCursor() -> CGPoint {
        CGEvent(source: source)?.location ?? .zero
    }
}
