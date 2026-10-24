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
/// target display. Touch semantics: finger down = button down, finger move =
/// drag, finger up = button up — i.e. the phone acts as a touchscreen. The
/// button is left unless the receiver asks for right (long press, two-finger tap).
final class InputInjector {

    private let displayID: CGDirectDisplayID
    /// The button a finger is holding down, nil while no finger is down.
    private var downButton: CGMouseButton?
    private var isDown: Bool { downButton != nil }
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

    // Synthetic events don't get click state from the Window Server, so we
    // mirror macOS double-click prefs here. Pencil uses the system distance; a
    // fingertip lands less precisely, so finger taps get a touch-sized radius.
    private var penClicks = ClickCounter(interval: SystemClickMetrics.interval,
                                         distance: SystemClickMetrics.distance)
    private var fingerClicks = ClickCounter(interval: SystemClickMetrics.interval,
                                            distance: max(SystemClickMetrics.distance, 24))

    private let pointerHandoff: PointerHandoff

    init(displayID: CGDirectDisplayID, pointerHandoff: PointerHandoff = .shared) {
        self.displayID = displayID
        self.pointerHandoff = pointerHandoff
    }

    deinit {
        scrollTick?.cancel()
    }

    static func ensureAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            Log.info("Accessibility permission missing — prompt requested")
        }
        return trusted
    }

    /// x/y are normalized [0,1] in video space (origin top-left). `button` is
    /// the wire's optional `touch.button`; only `"right"` changes anything, and
    /// only on `began` (the rest of the press follows the button it started with).
    func handleTouch(phase: String, x: Double, y: Double, button: String? = nil) {
        let bounds = CGDisplayBounds(displayID)   // global CG coords, y-down
        let point = CGPoint(
            x: bounds.origin.x + x * bounds.width,
            y: bounds.origin.y + y * bounds.height
        )
        let now = ProcessInfo.processInfo.systemUptime

        let type: CGEventType
        let mouseButton: CGMouseButton
        // A cancel means "a second finger joined, this was a scroll, not a tap"
        // — but there is no CGEvent for undoing a press, and a plain up over the
        // press point is indistinguishable from a click, so every two-finger
        // scroll opened whatever was under finger one. Releasing with clickCount
        // 0 keeps the button state honest while telling AppKit and WebKit not to
        // synthesize a click. Only the cancel path gets 0: a zero-click *down* is
        // what breaks menu tracking (see above).
        var clickState = 1
        switch phase {
        case "began":
            if let held = downButton {
                // A down without its up: release it first so the button state
                // never sticks.
                postMouse(held == .right ? .rightMouseUp : .leftMouseUp, at: point, button: held, clickState: 0)
            }
            mouseButton = button == "right" ? .right : .left
            if mouseButton == .right {
                type = .rightMouseDown
            } else {
                type = .leftMouseDown
                clickState = fingerClicks.down(at: point, now: now)
            }
            downButton = mouseButton
        case "moved":
            mouseButton = downButton ?? .left
            switch downButton {
            case .left?: type = .leftMouseDragged
            case .right?: type = .rightMouseDragged
            default: type = .mouseMoved
            }
        case "ended", "cancelled":
            guard let held = downButton else { return }   // spurious up without a down
            mouseButton = held
            type = held == .right ? .rightMouseUp : .leftMouseUp
            if phase == "cancelled" {
                clickState = 0
                if held == .left { fingerClicks.cancel() }
            } else if held == .left {
                clickState = fingerClicks.up(at: point, now: now)
            }
            downButton = nil
        default:
            return
        }

        pointerHandoff.touchMovesPointer(to: point, from: currentCursor(), holding: isDown)
        postMouse(type, at: point, button: mouseButton, clickState: clickState)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }

    /// dx/dy in display pixels, natural-scrolling sign from the phone.
    /// Scroll events take points, so convert via the display's pixel scale.
    /// `phase` is the wire's optional `scroll.phase`; with it the events carry
    /// trackpad scroll and momentum phases (see ScrollPhaser).
    func handleScroll(dx: Double, dy: Double, phase: String? = nil) {
        let bounds = CGDisplayBounds(displayID)
        let scale = bounds.width > 0 ? Double(CGDisplayPixelsWide(displayID)) / bounds.width : 2
        guard let phase else {
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                      wheelCount: 2,
                                      wheel1: Int32((dy / scale).rounded()),
                                      wheel2: Int32((dx / scale).rounded()),
                                      wheel3: 0) else { return }
            event.post(tap: .cghidEventTap)
            return
        }
        scrollQueue.async { [self] in
            for e in scrollSmoother.receive(phase: phase, dx: dx / scale, dy: dy / scale) { postScroll(e) }
            if !scrollSmoother.isIdle { startScrollTick() }
        }
    }

    /// Close a scroll, momentum or magnify phase the receiver left open, e.g.
    /// because it disconnected mid-gesture.
    func endScrollGestures() {
        scrollQueue.async { [self] in
            for e in scrollSmoother.finish() { postScroll(e) }
            stopScrollTick()
        }
        if magnifying { handleMagnify(phase: "ended", magnification: 0) }
    }

    // Phased scrolling is paced by ScrollSmoother on its own queue at 120 Hz;
    // the tick runs only while a scroll is in flight.
    private let scrollQueue = DispatchQueue(label: "input.scroll", qos: .userInteractive)
    private var scrollSmoother = ScrollSmoother(timeConstant: InputInjector.scrollSmoothing)
    private var scrollTick: DispatchSourceTimer?
    private var lastScrollTick: TimeInterval = 0

    /// `defaults write … scrollSmoothingMs -int N` (0 = post deltas as they arrive).
    private static var scrollSmoothing: TimeInterval {
        let ms = UserDefaults.standard.object(forKey: "scrollSmoothingMs") as? Double ?? 25
        return max(ms, 0) / 1000
    }

    private func startScrollTick() {
        guard scrollTick == nil else { return }
        lastScrollTick = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: scrollQueue)
        timer.schedule(deadline: .now() + .milliseconds(8), repeating: .microseconds(8_333), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for e in self.scrollSmoother.tick(dt: now - self.lastScrollTick) { self.postScroll(e) }
            self.lastScrollTick = now
            if self.scrollSmoother.isIdle { self.stopScrollTick() }
        }
        timer.resume()
        scrollTick = timer
    }

    private func stopScrollTick() {
        scrollTick?.cancel()
        scrollTick = nil
    }

    // MARK: System actions

    /// The wire's `gesture.action` (see SystemAction). Unknown names are
    /// logged and ignored, so newer receivers never break older senders.
    func handleSystemAction(_ name: String) {
        guard let action = SystemAction(rawValue: name) else {
            Log.info("system action: unknown \(name)")
            return
        }
        if action.needsPointerOnDisplay {
            // Spaces switch on the display under the pointer: bring it to this
            // device's display (borrowed, like a touch) unless it is already there.
            let bounds = CGDisplayBounds(displayID)
            let current = currentCursor()
            if !bounds.contains(current) {
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                pointerHandoff.touchMovesPointer(to: center, from: current, holding: false)
                postMouse(.mouseMoved, at: center, button: .left, clickState: 0)
            }
        }
        action.perform()
    }

    // MARK: Magnify
    //
    // A pinch becomes the trackpad's magnify gesture. There is no public API
    // to create one: these are NSEventTypeGesture (29) events with the
    // undocumented fields Mac Mouse Fix and Hammerspoon post — 110 the gesture
    // kind (8 = kIOHIDEventTypeZoom), 132 its IOHIDEventPhaseBits, 113 the
    // magnification. The gesture lands on the window under the pointer, which
    // the receiver first moves to the pinch.

    private static let gestureEventType: Int64 = 29
    private static let fieldEventType = CGEventField(rawValue: 55)!
    private static let fieldGestureKind = CGEventField(rawValue: 110)!
    private static let fieldGestureMagnification = CGEventField(rawValue: 113)!
    private static let fieldGesturePhase = CGEventField(rawValue: 132)!
    private static let gestureKindZoom: Int64 = 8
    private var magnifying = false

    /// `magnification` is the relative change since the previous message
    /// (NSEvent.magnification semantics); `phase` is began, changed, ended or
    /// cancelled.
    func handleMagnify(phase: String, magnification: Double) {
        let bits: Int64
        switch phase {
        case "began":
            if magnifying { handleMagnify(phase: "ended", magnification: 0) }
            bits = 1
            magnifying = true
        case "changed":
            guard magnifying else { return handleMagnify(phase: "began", magnification: magnification) }
            bits = 2
        case "ended", "cancelled":
            guard magnifying else { return }
            bits = phase == "ended" ? 4 : 8
            magnifying = false
        default:
            return
        }
        guard let event = CGEvent(source: source) else { return }
        event.setIntegerValueField(Self.fieldEventType, value: Self.gestureEventType)
        event.setIntegerValueField(Self.fieldGestureKind, value: Self.gestureKindZoom)
        event.setIntegerValueField(Self.fieldGesturePhase, value: bits)
        event.setDoubleValueField(Self.fieldGestureMagnification, value: magnification)
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(_ e: ScrollPhaser.Event) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: e.dy, wheel2: e.dx, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(e.scrollPhase))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(e.momentumPhase))
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
        let now = ProcessInfo.processInfo.systemUptime
        switch phase {
        case .down:
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(penClicks.down(at: p, now: now)))
        case .up:
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(penClicks.up(at: p, now: now)))
        case .drag, .hover:
            break
        }
        ev.flags = .maskNonCoalesced
        ev.post(tap: .cghidEventTap)
    }

    /// UIKit altitude is radians from the surface (pi/2 = upright); CGEvent tilt
    /// is a unit vector in -1...1, so normalize rather than pass radians through
    /// (unnormalized, a flat pen reads 1.57 and apps that scale tilt by 90 report
    /// impossible angles).
    private func deriveTilt(azimuth: Double, altitude: Double) -> (Double, Double) {
        let mag = min(max(0, Double.pi / 2 - altitude) / (Double.pi / 2), 1)
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
