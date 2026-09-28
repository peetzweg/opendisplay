import AppKit
import CoreGraphics

/// HID Keyboard/Keypad usages -> macOS physical virtual keys. Deliberately do
/// not inject iPad Unicode: the Mac's keyboard layout and IME remain in charge.
enum HardwareKeyMap {
    static func keyCode(_ usage: Int) -> CGKeyCode? {
        let letters: [CGKeyCode] = [
            0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
            45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6
        ]
        if (4...29).contains(usage) { return letters[usage - 4] }
        let digits: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        if (30...39).contains(usage) { return digits[usage - 30] }
        let other: [Int: CGKeyCode] = [
            40: 36, 41: 53, 42: 51, 43: 48, 44: 49, 45: 27, 46: 24,
            47: 33, 48: 30, 49: 42, 50: 42, 51: 41, 52: 39, 53: 50,
            54: 43, 55: 47, 56: 44, 57: 57,
            58: 122, 59: 120, 60: 99, 61: 118, 62: 96, 63: 97,
            64: 98, 65: 100, 66: 101, 67: 109, 68: 103, 69: 111,
            73: 114, 74: 115, 75: 116, 76: 117, 77: 119, 78: 121,
            79: 124, 80: 123, 81: 125, 82: 126, 83: 71,
            84: 75, 85: 67, 86: 78, 87: 69, 88: 76,
            89: 83, 90: 84, 91: 85, 92: 86, 93: 87, 94: 88,
            95: 89, 96: 91, 97: 92, 98: 82, 99: 65, 100: 10, 103: 81,
            104: 105, 105: 107, 106: 113, 107: 106, 108: 64,
            109: 79, 110: 80, 111: 90,
            135: 94, 137: 93, 144: 104, 145: 102,
            224: 59, 225: 56, 226: 58, 227: 55,
            228: 62, 229: 60, 230: 61, 231: 54
        ]
        return other[usage]
    }

    static func modifier(_ usage: Int) -> CGEventFlags? {
        switch usage {
        case 224, 228: return .maskControl
        case 225, 229: return .maskShift
        case 226, 230: return .maskAlternate
        case 227, 231: return .maskCommand
        default: return nil
        }
    }
}

/// Per-session state, synchronized because stop/rotation and socket callbacks
/// run on different queues. Tests replace the sink so no real input is posted.
final class HardwareInputInjector {
    private var displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .privateState)
    // Pointer motion uses the same HID system state as the established touch
    // injector. Keyboard ownership remains in its independent private state.
    private let pointerSource = CGEventSource(stateID: .hidSystemState)
    private let lock = NSRecursiveLock()
    private let sink: (CGEvent) -> Void
    private let isTrusted: () -> Bool
    private let repeats: Bool
    private let repeatTiming: () -> (TimeInterval, TimeInterval)
    private var keys: [Int] = []
    private var buttons: [Int: Int] = [:]
    private var lastPoint = CGPoint.zero
    private var modifiers: CGEventFlags = []
    private var preciseScrollActive = false
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0
    private var repeatTimer: DispatchSourceTimer?
    private var repeatUsage: Int?
    private let cursorPosition: () -> CGPoint
    private let desktopBounds: () -> [CGRect]
    private let repeatQueue = DispatchQueue(label: "opendisplay.hardware-repeat")

    init(displayID: CGDirectDisplayID, repeats: Bool = true,
         repeatTiming: @escaping () -> (TimeInterval, TimeInterval) = {
             (NSEvent.keyRepeatDelay, NSEvent.keyRepeatInterval)
         },
         cursorPosition: @escaping () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero },
         desktopBounds: @escaping () -> [CGRect] = {
             var count: UInt32 = 0
             guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
             var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
             guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
             return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
         },
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         sink: @escaping (CGEvent) -> Void = { $0.post(tap: HardwareInputInjector.eventTap(for: $0.type)) }) {
        self.displayID = displayID
        self.cursorPosition = cursorPosition
        self.desktopBounds = desktopBounds
        self.repeats = repeats
        self.repeatTiming = repeatTiming
        self.isTrusted = isTrusted
        self.sink = sink
    }

    deinit { releaseAll() }

    func setDisplayID(_ displayID: CGDirectDisplayID) {
        lock.lock(); defer { lock.unlock() }
        releaseLocked()
        self.displayID = displayID
    }

    func key(_ input: HardwareInput.Key) {
        lock.lock(); defer { lock.unlock() }
        guard displayID != 0, input.isValid, HardwareKeyMap.keyCode(input.code) != nil else { return }
        guard isTrusted() else { releaseLocked(); return }
        if input.down {
            // UIKit or a keyboard may report repeated downs. One Mac-side
            // repeat timer owns repetition, so these cannot double the rate.
            guard !keys.contains(input.code), keys.count < 64 else { return }
            keys.append(input.code)
            modifiers = effectiveModifiers(input.mod)
            if let flag = HardwareKeyMap.modifier(input.code) { modifiers.insert(flag) }
        } else {
            guard let index = keys.firstIndex(of: input.code) else { return }
            keys.remove(at: index)
            modifiers = effectiveModifiers(input.mod)
            if let flag = HardwareKeyMap.modifier(input.code) {
                if keys.contains(where: { HardwareKeyMap.modifier($0) == flag }) {
                    modifiers.insert(flag)
                } else {
                    modifiers.remove(flag)
                }
            }
        }
        postKey(input.code, down: input.down, repeatKey: false)
        armRepeatLocked()
    }

    func pointer(_ input: HardwareInput.Pointer) {
        lock.lock(); defer { lock.unlock() }
        guard displayID != 0, input.isValid else { return }
        guard isTrusted() else { releaseLocked(); return }
        modifiers = effectiveModifiers(input.mod)
        let bounds = CGDisplayBounds(displayID)
        let origin = cursorPosition()
        lastPoint = CGPoint(x: bounds.minX + input.x * bounds.width,
                            y: bounds.minY + input.y * bounds.height)
        let button: Int
        let type: CGEventType
        var clicks = input.clicks
        switch input.phase {
        case .began:
            guard buttons[input.button] == nil else { return }
            buttons[input.button] = clicks
            button = input.button
            type = mouseType(button, down: true)
        case .ended, .cancelled:
            guard let count = buttons.removeValue(forKey: input.button) else { return }
            clicks = input.phase == .cancelled ? 0 : count
            button = input.button
            type = mouseType(button, down: false)
        case .moved:
            button = buttons.keys.sorted().first ?? input.button
            type = buttons.isEmpty ? .mouseMoved
                : button == 1 ? .leftMouseDragged
                : button == 2 ? .rightMouseDragged : .otherMouseDragged
        }
        postMouse(type, button: button, clicks: clicks,
                  delta: CGPoint(x: lastPoint.x - origin.x, y: lastPoint.y - origin.y))
    }

    func relativePointer(_ input: HardwareInput.RelativePointer) {
        lock.lock(); defer { lock.unlock() }
        guard displayID != 0, input.isValid else { return }
        if input.phase == .moved && input.dx == 0 && input.dy == 0 { return }
        guard isTrusted() else { releaseLocked(); return }
        modifiers = effectiveModifiers(input.mod)
        let origin = cursorPosition()
        lastPoint = Self.desktopPoint(CGPoint(x: origin.x + input.dx, y: origin.y + input.dy),
                                      screens: desktopBounds())
        let button: Int
        let type: CGEventType
        var clicks = input.clicks
        switch input.phase {
        case .began:
            guard buttons[input.button] == nil else { return }
            buttons[input.button] = clicks
            button = input.button
            type = mouseType(button, down: true)
        case .ended, .cancelled:
            guard let count = buttons.removeValue(forKey: input.button) else { return }
            clicks = input.phase == .cancelled ? 0 : count
            button = input.button
            type = mouseType(button, down: false)
        case .moved:
            button = buttons.keys.sorted().first ?? input.button
            type = buttons.isEmpty ? .mouseMoved
                : button == 1 ? .leftMouseDragged
                : button == 2 ? .rightMouseDragged : .otherMouseDragged
        }
        postMouse(type, button: button, clicks: clicks,
                  delta: CGPoint(x: input.dx, y: input.dy))
    }

    static func eventTap(for type: CGEventType) -> CGEventTapLocation {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            return .cgSessionEventTap
        default: return .cghidEventTap
        }
    }

    /// Keep a relative pointer on the nearest active monitor, including
    /// negative-origin arrangements and gaps between differently sized panels.
    static func desktopPoint(_ point: CGPoint, screens: [CGRect]) -> CGPoint {
        let valid = screens.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        guard !valid.isEmpty else { return point }
        if valid.contains(where: { $0.contains(point) }) { return point }
        return valid.map { rect in
            CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1),
                    y: min(max(point.y, rect.minY), rect.maxY - 1))
        }.min { a, b in
            hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
        } ?? point
    }

    func scroll(_ input: HardwareInput.Scroll) {
        lock.lock(); defer { lock.unlock() }
        guard displayID != 0, input.isValid else { return }
        guard isTrusted() else { releaseLocked(); return }
        modifiers = effectiveModifiers(input.mod)
        let bounds = CGDisplayBounds(displayID)
        let scale = bounds.width > 0 ? Double(CGDisplayPixelsWide(displayID)) / bounds.width : 2
        guard scale.isFinite, scale > 0,
              let event = CGEvent(scrollWheelEvent2Source: pointerSource, units: .pixel,
                                  wheelCount: 2, wheel1: Int32((input.dy / scale).rounded()),
                                  wheel2: Int32((input.dx / scale).rounded()), wheel3: 0) else { return }
        event.flags = modifiers
        sink(event)
    }

    func preciseScroll(_ input: HardwareInput.PreciseScroll) {
        lock.lock(); defer { lock.unlock() }
        guard displayID != 0, input.isValid else { return }
        guard isTrusted() else { releaseLocked(); return }
        modifiers = effectiveModifiers(input.mod)
        if input.phase == .ended || input.phase == .cancelled {
            guard preciseScrollActive else { return }
            preciseScrollActive = false
            scrollRemainderX = 0; scrollRemainderY = 0
            return
        }
        if input.phase == .began {
            scrollRemainderX = 0; scrollRemainderY = 0
        }
        preciseScrollActive = true
        scrollRemainderX += input.dx; scrollRemainderY += input.dy
        let dx = Int32(scrollRemainderX.rounded(.towardZero))
        let dy = Int32(scrollRemainderY.rounded(.towardZero))
        scrollRemainderX -= Double(dx); scrollRemainderY -= Double(dy)
        if dx != 0 || dy != 0 { postPreciseScroll(dx: dx, dy: dy) }
    }

    private func postPreciseScroll(dx: Int32, dy: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: pointerSource, units: .pixel,
                                  wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        // Use standard pixel wheel events at the current desktop pointer.
        // Wire phases delimit our accumulation; synthetic native gesture
        // phases are not imposed on the target application's scroll handling.
        event.location = cursorPosition()
        event.flags = modifiers
        sink(event)
    }

    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        releaseLocked()
    }

    private func releaseLocked() {
        preciseScrollActive = false
        scrollRemainderX = 0; scrollRemainderY = 0
        repeatTimer?.cancel()
        repeatTimer = nil
        repeatUsage = nil
        let held = keys
        let heldButtons = buttons
        keys.removeAll()
        buttons.removeAll()
        // Release ordinary keys while their modifier combination is intact,
        // then each modifier, then pointer buttons with no modifiers pressed.
        if isTrusted() {
            for usage in held where HardwareKeyMap.modifier(usage) == nil {
                postKey(usage, down: false, repeatKey: false)
            }
            for usage in held where HardwareKeyMap.modifier(usage) != nil {
                if let flag = HardwareKeyMap.modifier(usage) { modifiers.remove(flag) }
                postKey(usage, down: false, repeatKey: false)
            }
            modifiers = []
            for button in heldButtons.keys.sorted() {
                postMouse(mouseType(button, down: false), button: button, clicks: 0)
            }
        }
        modifiers = []
    }

    private func postKey(_ usage: Int, down: Bool, repeatKey: Bool) {
        guard let code = HardwareKeyMap.keyCode(usage),
              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if HardwareKeyMap.modifier(usage) != nil || usage == 57 { event.type = .flagsChanged }
        event.flags = modifiers
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        sink(event)
    }

    private func effectiveModifiers(_ raw: UInt) -> CGEventFlags {
        var result = CGEventFlags(rawValue: UInt64(raw))
        // Some indirect events omit modifier snapshots. A modifier we own
        // remains held until its matching up/reset, including Command-click.
        for usage in keys {
            if let flag = HardwareKeyMap.modifier(usage) { result.insert(flag) }
        }
        return result
    }

    private func armRepeatLocked() {
        let target = keys.last(where: { HardwareKeyMap.modifier($0) == nil && $0 != 57 })
        guard target != repeatUsage else { return }
        repeatTimer?.cancel()
        repeatTimer = nil
        repeatUsage = nil
        let (delay, interval) = repeatTiming()
        guard repeats, let usage = target, delay.isFinite, interval.isFinite,
              delay >= 0, interval >= 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: repeatQueue)
        // A system KeyRepeat value of zero can produce a zero-second interval.
        // Zero is a valid fastest setting, not a request to disable forwarding.
        // Bound it to 50 Hz instead of silently turning remote repeat off.
        let boundedInterval = interval == 0 ? 0.02 : max(interval, 0.01)
        timer.schedule(deadline: .now() + max(delay, 0.1),
                       repeating: boundedInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.repeatUsage == usage else { return }
            guard self.keys.contains(usage), self.isTrusted() else {
                self.releaseLocked()
                return
            }
            self.postKey(usage, down: true, repeatKey: true)
        }
        repeatUsage = usage
        repeatTimer = timer
        timer.resume()
    }

    private func mouseType(_ button: Int, down: Bool) -> CGEventType {
        switch button {
        case 1: return down ? .leftMouseDown : .leftMouseUp
        case 2: return down ? .rightMouseDown : .rightMouseUp
        default: return down ? .otherMouseDown : .otherMouseUp
        }
    }

    private func postMouse(_ type: CGEventType, button: Int, clicks: Int, delta: CGPoint = .zero) {
        let cgButton: CGMouseButton = button == 1 ? .left : button == 2 ? .right : .center
        guard let event = CGEvent(mouseEventSource: pointerSource, mouseType: type,
                                  mouseCursorPosition: lastPoint, mouseButton: cgButton) else { return }
        event.flags = modifiers
        event.setIntegerValueField(.mouseEventClickState, value: type == .mouseMoved ? 0 : Int64(clicks))
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        sink(event)
    }
}
