import AppKit
import CoreGraphics

/// The event tap lives on the main run loop; receiver input arrives on network
/// queues. The lock protects the shared handoff state across both paths.
final class CursorRestore {
    static let shared = CursorRestore()
    static let preferenceKey = "restoreMouseAfterTouch"
    static let injectedEventTag: Int64 = 0x4F444953544F5543

    private let lock = NSLock()
    private var state = CursorRestoreState()
    private var monitoring = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Main thread only. Also called when Accessibility permission changes.
    func refresh() {
        precondition(Thread.isMainThread)
        let enabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        guard enabled, AXIsProcessTrusted() else {
            stop()
            return
        }
        guard tap == nil else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged,
                                   .rightMouseDragged, .otherMouseDragged,
                                   .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let restore = Unmanaged<CursorRestore>.fromOpaque(context).takeUnretainedValue()
                return restore.handle(type: type, event: event)
                    ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            Log.info("cursor restore: could not create event tap; check Accessibility permission")
            return
        }
        tap = newTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        lock.lock()
        monitoring = true
        lock.unlock()
        Log.info("cursor restore: event tap active")
    }

    func touch(from owner: UUID, phase: String) {
        lock.lock()
        defer { lock.unlock() }
        guard monitoring, let cursor = CGEvent(source: nil)?.location else { return }
        state.touch(from: owner, phase: phase, cursor: cursor)
    }

    func disconnect(_ owner: UUID) {
        lock.lock()
        state.disconnect(owner)
        lock.unlock()
    }

    private func stop() {
        lock.lock()
        monitoring = false
        state.reset()
        lock.unlock()
        if let tap { CFMachPortInvalidate(tap) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.info("cursor restore: event tap disabled (\(type.rawValue)); re-enabling")
            lock.lock()
            state.reset()
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        // Hardware events come from WindowServer (PID 0). Ignore our injected
        // finger/Pencil events and synthetic events from other applications.
        // A mouse reports subtype 0 (default); a built-in or Magic Trackpad
        // reports 3 (touch). Tablet subtypes (1, 2) are not mouse/trackpad.
        let subtype = event.getIntegerValueField(.mouseEventSubtype)
        guard event.getIntegerValueField(.eventSourceUserData) != Self.injectedEventTag,
              event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
              subtype == 0 || subtype == 3 else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard monitoring, state.savedPosition != nil else { return false }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        let isMovement = type == .mouseMoved || type == .leftMouseDragged
            || type == .rightMouseDragged || type == .otherMouseDragged
        let delta = isMovement
            ? CGPoint(x: CGFloat(event.getIntegerValueField(.mouseEventDeltaX)),
                      y: CGFloat(event.getIntegerValueField(.mouseEventDeltaY)))
            : .zero
        if isMovement && delta == .zero { return false }
        guard let point = state.resumeMouse(
            displays: ids.prefix(Int(count)).map(CGDisplayBounds)) else { return false }
        guard let resumeEvent = Self.makeResumeEvent(from: event, at: point) else { return false }
        // Consume the trigger and inject an absolute move instead of warping:
        // CGWarpMouseCursorPosition pins subsequent hardware event coordinates.
        resumeEvent.post(tap: .cghidEventTap)
        return true
    }

    static func makeResumeEvent(from event: CGEvent, at point: CGPoint) -> CGEvent? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        let button = CGMouseButton(rawValue: UInt32(event.getIntegerValueField(.mouseEventButtonNumber))) ?? .left
        guard let resume = CGEvent(mouseEventSource: source, mouseType: event.type,
                                   mouseCursorPosition: point, mouseButton: button) else { return nil }
        resume.flags = event.flags
        resume.setIntegerValueField(.mouseEventClickState,
                                    value: event.getIntegerValueField(.mouseEventClickState))
        resume.setIntegerValueField(.mouseEventDeltaX, value: 0)
        resume.setIntegerValueField(.mouseEventDeltaY, value: 0)
        resume.setIntegerValueField(.eventSourceUserData, value: injectedEventTag)
        return resume
    }
}
