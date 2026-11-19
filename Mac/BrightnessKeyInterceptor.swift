import AppKit
import CoreGraphics
import Foundation

/// Global brightness key (F1/F2) interceptor for multi-display OpenDisplay setups.
/// Determines the target virtual display based on cursor position (highest priority)
/// or the location of the active (frontmost) window.
///
/// Handles:
///   • NX_SYSDEFINED events (CGEventType raw value 14) with subtype 7 or 8 —
///     built-in MacBook keyboards and Magic Keyboards (NX_KEYTYPE_BRIGHTNESS_UP = 2,
///     NX_KEYTYPE_BRIGHTNESS_DOWN = 3).
///   • Standard keyDown/keyUp events for kVK_F1 (122) / kVK_F2 (120) and
///     external keyboard codes kVK_F14 (107) / kVK_F15 (113).
///   • Fine-grained 1/64 steps when holding Option + Shift (matching native macOS OSD).
final class BrightnessKeyInterceptor {
    static let shared = BrightnessKeyInterceptor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()

    /// Registered virtual displays and their brightness change handlers.
    private var displayHandlers: [CGDirectDisplayID: (Double) -> Bool] = [:]

    private init() {}

    func register(displayID: CGDirectDisplayID, handler: @escaping (Double) -> Bool) {
        guard displayID != kCGNullDirectDisplay else { return }
        lock.lock()
        displayHandlers[displayID] = handler
        let shouldStart = !displayHandlers.isEmpty
        lock.unlock()

        if shouldStart {
            DispatchQueue.main.async { self.start() }
        }
    }

    func unregister(displayID: CGDirectDisplayID) {
        lock.lock()
        displayHandlers.removeValue(forKey: displayID)
        let shouldStop = displayHandlers.isEmpty
        lock.unlock()

        if shouldStop {
            DispatchQueue.main.async { self.stop() }
        }
    }

    private func start() {
        guard eventTap == nil else { return }

        // NX_SYSDEFINED = 14, keyDown = 10, keyUp = 11
        let sysDefinedMask = CGEventMask(1 << 14)
        let keyEventsMask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        let eventMask = sysDefinedMask | keyEventsMask
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<BrightnessKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handleEvent(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // ── NX_SYSDEFINED path (built-in keyboards, Magic Keyboard) ─────────
        if type.rawValue == 14 {
            guard let nsEvent = NSEvent(cgEvent: event),
                  nsEvent.type == .systemDefined,
                  nsEvent.subtype.rawValue == 7 || nsEvent.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }

            let data1 = nsEvent.data1
            let keyCode = (data1 & 0xFFFF0000) >> 16
            let keyFlags = data1 & 0x0000FFFF
            let keyState = (keyFlags & 0xFF00) >> 8
            let isRepeat = (keyFlags & 0x0001) != 0

            // For NX_SYSDEFINED events, modifier keys are encoded in keyFlags
            // (data1 lower 16 bits), not in event.flags.
            let hasOption = (keyFlags & 0x0020) != 0   // option key bit
            let hasShift = (keyFlags & 0x0002) != 0    // shift key bit
            let hasFineModifiers = hasOption && hasShift

            let baseStep: Double = isRepeat ? (1.0 / 32.0) : (1.0 / 16.0)
            let step: Double = hasFineModifiers ? (1.0 / 64.0) : baseStep

            let delta: Double
            switch keyCode {
            case 2: delta = -step   // NX_KEYTYPE_BRIGHTNESS_UP — F1 dims on Mac
            case 3: delta = step    // NX_KEYTYPE_BRIGHTNESS_DOWN — F2 brightens on Mac
            default:
                return Unmanaged.passUnretained(event)
            }

            guard let (_, handler) = resolveTargetDisplay() else {
                return Unmanaged.passUnretained(event)
            }

            // Only act on keyDown (0xA); swallow keyUp (0xB) for the target display
            guard keyState == 0xA else {
                return nil
            }

            return handler(delta) ? nil : Unmanaged.passUnretained(event)
        }

        // ── keyDown / keyUp path (external keyboards + standard F1/F2) ─────
        if type == .keyDown || type == .keyUp {
            guard let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = Int(nsEvent.keyCode)
            let isKeyDown = (type == .keyDown)
            let isRepeat = nsEvent.isARepeat

            // Option + Shift enables quarter-step (1/64) fine brightness adjustment.
            let hasFineModifiers = nsEvent.modifierFlags.contains([.option, .shift])
            let baseStep: Double = isRepeat ? (1.0 / 32.0) : (1.0 / 16.0)
            let step: Double = hasFineModifiers ? (1.0 / 64.0) : baseStep

            let delta: Double
            switch keyCode {
            case 122, 107: delta = -step   // kVK_F1 (122) / kVK_F14 (107) — brightness down
            case 120, 113: delta = step    // kVK_F2 (120) / kVK_F15 (113) — brightness up
            default:
                return Unmanaged.passUnretained(event)
            }

            guard let (_, handler) = resolveTargetDisplay() else {
                return Unmanaged.passUnretained(event)
            }

            // Only act on keyDown; swallow keyUp when targeting a virtual display
            guard isKeyDown else {
                return nil
            }

            return handler(delta) ? nil : Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func resolveTargetDisplay() -> (CGDirectDisplayID, (Double) -> Bool)? {
        lock.lock()
        let currentDisplays = displayHandlers
        lock.unlock()

        guard !currentDisplays.isEmpty else { return nil }

        var boundsMap: [(id: CGDirectDisplayID, bounds: CGRect, handler: (Double) -> Bool)] = []
        for (id, handler) in currentDisplays {
            let rect = CGDisplayBounds(id)
            if !rect.isEmpty {
                boundsMap.append((id, rect, handler))
            }
        }
        guard !boundsMap.isEmpty else { return nil }

        // Priority 1: Cursor location
        if let mouseLocation = CGEvent(source: nil)?.location,
           let hit = boundsMap.first(where: { $0.bounds.contains(mouseLocation) }) {
            return (hit.id, hit.handler)
        }

        // Priority 2: Active (frontmost) application window
        guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontPID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let windowBounds = CGRect(dictionaryRepresentation: boundsDict),
                  windowBounds.width > 50, windowBounds.height > 50 else {
                continue
            }

            // Find the display with the largest intersection area with the active window
            // (more reliable than just the window center if the window partially overlaps onto an adjacent display)
            var bestMatch: (id: CGDirectDisplayID, handler: (Double) -> Bool, area: CGFloat)?
            for item in boundsMap {
                let intersection = item.bounds.intersection(windowBounds)
                if !intersection.isNull {
                    let area = intersection.width * intersection.height
                    if area > (bestMatch?.area ?? 0) {
                        bestMatch = (item.id, item.handler, area)
                    }
                }
            }

            let totalWindowArea = windowBounds.width * windowBounds.height
            if let match = bestMatch, match.area >= totalWindowArea * 0.5 {
                return (match.id, match.handler)
            }

            break
        }

        return nil
    }
}
