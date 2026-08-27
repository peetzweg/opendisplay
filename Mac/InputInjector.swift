import CoreGraphics
import AppKit
import Darwin

/// System double-click thresholds. Interval is public API; distance is read from
/// AppKit's `NSDoubleClickDistance()` (same value the Window Server uses).
private enum SystemClickMetrics {
    static var interval: TimeInterval { NSEvent.doubleClickInterval }

    static var distance: CGFloat {
        doubleClickDistanceFn?() ?? 4
    }

    private typealias DoubleClickDistanceFn = @convention(c) () -> CGFloat
    private static let doubleClickDistanceFn: DoubleClickDistanceFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY),
              let sym = dlsym(handle, "NSDoubleClickDistance") else { return nil }
        return unsafeBitCast(sym, to: DoubleClickDistanceFn.self)
    }()
}

/// Turns normalized touch coordinates from the phone into mouse events on a
/// target display. Touch semantics: finger down = left button down, finger
/// move = drag, finger up = button up — i.e. the phone acts as a touchscreen.
final class InputInjector {

    private let displayID: CGDirectDisplayID
    private var isDown = false
    private var penDown = false
    // A real event source (vs nil) plus non-zero clickState on down/up: menu
    // tracking treats sourceless/zero-click synthetic clicks as malformed — menus
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
    private var stickyModifiers: CGEventFlags = []

    // Pencil-only synthetic click counting — tablet events don't get click
    // state from the Window Server, so we mirror macOS double-click prefs here.
    private struct PenClickSession {
        let downLocation: CGPoint
        let clickState: Int
    }

    private struct PenCompletedClick {
        let upTime: CFAbsoluteTime
        let downLocation: CGPoint
        let clickState: Int
    }

    private var penClickSession: PenClickSession?
    private var penLastClick: PenCompletedClick?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    /// Sets sticky modifier flags sent from on-screen modifier sidebar (issue #7).
    func setStickyModifiers(_ rawFlags: UInt) {
        stickyModifiers = Self.eventFlags(for: rawFlags)
    }

    /// Injects keyboard key down/up events from connected hardware keyboards (issue #6).
    func handleKey(hidUsage: UInt16, down: Bool, rawModifiers: UInt = 0, characters: String? = nil) {
        guard let vk = Self.macKeyCode(for: hidUsage) else { return }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return }
        var flags = Self.eventFlags(for: rawModifiers, sticky: stickyModifiers)
        if down {
            switch vk {
            case 0x38, 0x3C: flags.insert(.maskShift)
            case 0x3B, 0x3E: flags.insert(.maskControl)
            case 0x3A, 0x3D: flags.insert(.maskAlternate)
            case 0x37, 0x36: flags.insert(.maskCommand)
            default: break
            }
        }
        event.flags = flags
        if let chars = characters, !chars.isEmpty, down {
            let utf16 = Array(chars.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        }
        event.post(tap: .cghidEventTap)
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
        // Click count on the release. A cancel means "a second finger joined,
        // this was a scroll, not a tap" — but there is no CGEvent for undoing a
        // press, and a plain up over the press point is indistinguishable from a
        // click, so every two-finger scroll opened whatever was under finger one.
        // Releasing with clickCount 0 keeps the button state honest while telling
        // AppKit and WebKit not to synthesize a click. Only the cancel path gets
        // 0: a zero-click *down* is what breaks menu tracking (see above).
        var clickState = 1
        switch phase {
        case "began":
            type = .leftMouseDown
            isDown = true
        case "moved":
            type = isDown ? .leftMouseDragged : .mouseMoved
        case "ended":
            guard isDown else { return }   // spurious up without a down
            type = .leftMouseUp
            isDown = false
        case "cancelled":
            guard isDown else { return }
            type = .leftMouseUp
            isDown = false
            clickState = 0
        default:
            return
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        if !stickyModifiers.isEmpty {
            event.flags.insert(stickyModifiers)
        }
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
        let (tiltX, tiltY) = Self.tiltVector(altitude: altitude, azimuth: azimuth)

        switch phase {
        case "down":
            postTabletPoint(phase: .down, x: x, y: y, pressure: pressure,
                            tiltX: tiltX, tiltY: tiltY, rotation: 0)
            penDown = true
        case "move":
            if penDown {
                postTabletPoint(phase: .drag, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            } else {
                postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            }
        case "up":
            if penDown {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
                penDown = false
            }
        case "hover":
            if penDown {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
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
        switch phase {
        case .down:
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(beginPenClickSession(at: p)))
        case .up:
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(finishPenClickSession(at: p)))
        case .drag, .hover:
            break
        }
        ev.flags = .maskNonCoalesced
        ev.post(tap: .cghidEventTap)
    }

    private func penClickStateForMouseDown(at point: CGPoint) -> Int {
        let now = CFAbsoluteTimeGetCurrent()
        guard let last = penLastClick,
              now - last.upTime <= SystemClickMetrics.interval else {
            return 1
        }
        let dx = point.x - last.downLocation.x
        let dy = point.y - last.downLocation.y
        guard hypot(dx, dy) <= SystemClickMetrics.distance else { return 1 }
        return last.clickState + 1
    }

    private func beginPenClickSession(at point: CGPoint) -> Int {
        let state = penClickStateForMouseDown(at: point)
        penClickSession = PenClickSession(downLocation: point, clickState: state)
        return state
    }

    /// Returns click state for the matching pen mouse-up. Extends the multi-click
    /// chain only when down→up displacement is within the system threshold.
    private func finishPenClickSession(at upLocation: CGPoint) -> Int {
        guard let session = penClickSession else { return 1 }
        penClickSession = nil

        let dx = upLocation.x - session.downLocation.x
        let dy = upLocation.y - session.downLocation.y
        if hypot(dx, dy) <= SystemClickMetrics.distance {
            penLastClick = PenCompletedClick(
                upTime: CFAbsoluteTimeGetCurrent(),
                downLocation: session.downLocation,
                clickState: session.clickState
            )
        } else {
            penLastClick = nil
        }
        return session.clickState
    }

    /// UIKit altitude is radians from the surface (pi/2 = upright); CGEvent tilt
    /// is a unit vector in -1...1, so normalize rather than pass radians through
    /// (unnormalized, a flat pen reads 1.57 and apps that scale tilt by 90 report
    /// impossible angles).
    static func tiltVector(altitude: Double, azimuth: Double) -> (x: Double, y: Double) {
        let mag = min(max(0, Double.pi / 2 - altitude) / (Double.pi / 2), 1)
        return (sin(azimuth) * mag, cos(azimuth) * mag)
    }

    /// Converts UIKeyModifierFlags bitmask to macOS CGEventFlags.
    static func eventFlags(for rawModifiers: UInt, sticky: CGEventFlags = []) -> CGEventFlags {
        var flags: CGEventFlags = sticky
        if rawModifiers & (1 << 17) != 0 { flags.insert(.maskShift) }
        if rawModifiers & (1 << 18) != 0 { flags.insert(.maskControl) }
        if rawModifiers & (1 << 19) != 0 { flags.insert(.maskAlternate) }
        if rawModifiers & (1 << 20) != 0 { flags.insert(.maskCommand) }
        if rawModifiers & (1 << 16) != 0 { flags.insert(.maskAlphaShift) }
        return flags
    }

    /// Maps standard USB HID Keyboard Usage page (0x07) codes to macOS virtual keycodes (CGKeyCode).
    static func macKeyCode(for hidUsage: UInt16) -> CGKeyCode? {
        switch hidUsage {
        // Letters (A-Z)
        case 0x04: return 0x00 // A
        case 0x05: return 0x0B // B
        case 0x06: return 0x08 // C
        case 0x07: return 0x02 // D
        case 0x08: return 0x0E // E
        case 0x09: return 0x03 // F
        case 0x0A: return 0x05 // G
        case 0x0B: return 0x04 // H
        case 0x0C: return 0x22 // I
        case 0x0D: return 0x26 // J
        case 0x0E: return 0x28 // K
        case 0x0F: return 0x25 // L
        case 0x10: return 0x2E // M
        case 0x11: return 0x2D // N
        case 0x12: return 0x1F // O
        case 0x13: return 0x23 // P
        case 0x14: return 0x0C // Q
        case 0x15: return 0x0F // R
        case 0x16: return 0x01 // S
        case 0x17: return 0x11 // T
        case 0x18: return 0x20 // U
        case 0x19: return 0x09 // V
        case 0x1A: return 0x0D // W
        case 0x1B: return 0x07 // X
        case 0x1C: return 0x10 // Y
        case 0x1D: return 0x06 // Z

        // Digits (1-0)
        case 0x1E: return 0x12 // 1
        case 0x1F: return 0x13 // 2
        case 0x20: return 0x14 // 3
        case 0x21: return 0x15 // 4
        case 0x22: return 0x17 // 5
        case 0x23: return 0x16 // 6
        case 0x24: return 0x1A // 7
        case 0x25: return 0x1C // 8
        case 0x26: return 0x19 // 9
        case 0x27: return 0x1D // 0

        // Functional & punctuation
        case 0x28: return 0x24 // Return
        case 0x29: return 0x35 // Escape
        case 0x2A: return 0x33 // Delete (Backspace)
        case 0x2B: return 0x30 // Tab
        case 0x2C: return 0x31 // Space
        case 0x2D: return 0x1B // Hyphen / Minus
        case 0x2E: return 0x18 // Equal
        case 0x2F: return 0x21 // Left Bracket
        case 0x30: return 0x1E // Right Bracket
        case 0x31: return 0x2A // Backslash
        case 0x33: return 0x29 // Semicolon
        case 0x34: return 0x27 // Quote
        case 0x35: return 0x32 // Grave / Tilde
        case 0x36: return 0x2B // Comma
        case 0x37: return 0x2F // Period
        case 0x38: return 0x2C // Slash
        case 0x39: return 0x39 // Caps Lock

        // Arrow navigation
        case 0x4F: return 0x7C // Right Arrow
        case 0x50: return 0x7B // Left Arrow
        case 0x51: return 0x7D // Down Arrow
        case 0x52: return 0x7E // Up Arrow

        // Modifiers
        case 0xE0: return 0x3B // Left Control
        case 0xE1: return 0x38 // Left Shift
        case 0xE2: return 0x3A // Left Option
        case 0xE3: return 0x37 // Left Command
        case 0xE4: return 0x3E // Right Control
        case 0xE5: return 0x3C // Right Shift
        case 0xE6: return 0x3D // Right Option
        case 0xE7: return 0x36 // Right Command

        default: return nil
        }
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
