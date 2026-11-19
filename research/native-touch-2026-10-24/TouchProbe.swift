// TouchProbe — research tool for native (direct) touch on macOS 27.
//
// Shows a window that logs every input path AppKit offers:
//   - direct/indirect NSTouch via a gesture recognizer (the only path Sidecar
//     touches take, per TN3212),
//   - AppKit's mouse emulation (mouseDown/rightMouseDown/scroll/magnify),
//   - a listen-only session event tap (needs Input Monitoring) that prints
//     every CGEvent type and whether it carries an IOHIDEvent.
//
// `--inject` additionally posts synthetic kCGSEventDirectTouch CGEvents with a
// digitizer IOHIDEvent attached, to test whether a third-party process can
// feed the direct-touch pipeline without a HID device.
//
// Build: ./build.sh   Run: open TouchProbe.app --args [--inject]
// Log:   ~/Library/Logs/TouchProbe.log (also stdout)

import AppKit
import CoreGraphics
import Darwin

// MARK: - Logging

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/TouchProbe.log")
let logHandle: FileHandle? = {
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    return try? FileHandle(forWritingTo: logURL)
}()
let t0 = Date()

func log(_ s: String) {
    let line = String(format: "[%8.3f] ", Date().timeIntervalSince(t0)) + s + "\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    logHandle?.write(line.data(using: .utf8)!)
}

// MARK: - Private symbols (resolved at runtime; absent ones are logged)

func sym<T>(_ name: String, _ lib: String) -> T? {
    guard let h = dlopen(lib, RTLD_LAZY), let p = dlsym(h, name) else {
        log("missing symbol \(name)")
        return nil
    }
    return unsafeBitCast(p, to: T.self)
}

let IOKitPath = "/System/Library/Frameworks/IOKit.framework/IOKit"
let CGPath = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
let SLPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

typealias IOHIDEventRef = OpaquePointer
typealias FnGetType = @convention(c) (IOHIDEventRef) -> UInt32
typealias FnGetInt = @convention(c) (IOHIDEventRef, UInt32) -> Int
typealias FnGetFloat = @convention(c) (IOHIDEventRef, UInt32) -> Double
typealias FnSetInt = @convention(c) (IOHIDEventRef, UInt32, Int) -> Void
typealias FnSenderID = @convention(c) (IOHIDEventRef) -> UInt64
typealias FnSetSenderID = @convention(c) (IOHIDEventRef, UInt64) -> Void
typealias FnAppend = @convention(c) (IOHIDEventRef, IOHIDEventRef, UInt32) -> Void
typealias FnChildren = @convention(c) (IOHIDEventRef) -> Unmanaged<CFArray>?
// IOHIDEventCreateDigitizerEvent(alloc, ts, transducerType, index, identity,
//   eventMask, buttonMask, x, y, z, tipPressure, barrelPressure, range, touch, options)
typealias FnCreateDigitizer = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
                                              Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> IOHIDEventRef?
// IOHIDEventCreateDigitizerFingerEvent(alloc, ts, index, identity, eventMask,
//   x, y, z, tipPressure, twist, range, touch, options)
typealias FnCreateFinger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32,
                                           Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> IOHIDEventRef?
typealias FnCopyHID = @convention(c) (CGEvent) -> IOHIDEventRef?
typealias FnSetHID = @convention(c) (CGEvent, IOHIDEventRef) -> Void
typealias FnSetType = @convention(c) (CGEvent, UInt32) -> Void

let hidGetType: FnGetType? = sym("IOHIDEventGetType", IOKitPath)
let hidGetInt: FnGetInt? = sym("IOHIDEventGetIntegerValue", IOKitPath)
let hidGetFloat: FnGetFloat? = sym("IOHIDEventGetFloatValue", IOKitPath)
let hidSetInt: FnSetInt? = sym("IOHIDEventSetIntegerValue", IOKitPath)
let hidSenderID: FnSenderID? = sym("IOHIDEventGetSenderID", IOKitPath)
let hidSetSenderID: FnSetSenderID? = sym("IOHIDEventSetSenderID", IOKitPath)
let hidAppend: FnAppend? = sym("IOHIDEventAppendEvent", IOKitPath)
let hidChildren: FnChildren? = sym("IOHIDEventGetChildren", IOKitPath)
let hidCreateDigitizer: FnCreateDigitizer? = sym("IOHIDEventCreateDigitizerEvent", IOKitPath)
let hidCreateFinger: FnCreateFinger? = sym("IOHIDEventCreateDigitizerFingerEvent", IOKitPath)
let cgCopyHID: FnCopyHID? = sym("CGEventCopyIOHIDEvent", CGPath)
let slSetHID: FnSetHID? = sym("SLEventSetIOHIDEvent", SLPath)
let cgSetType: FnSetType? = sym("CGEventSetType", CGPath)

// IOHIDEventTypes.h / IOHIDEventFieldDefs.h
let kHIDTypeDigitizer: UInt32 = 11
func digField(_ n: UInt32) -> UInt32 { (kHIDTypeDigitizer << 16) | n }
let fX = digField(0), fY = digField(1), fType = digField(4), fIndex = digField(5),
    fIdentity = digField(6), fEventMask = digField(7), fRange = digField(8), fTouch = digField(9),
    fDisplayIntegrated = digField(25)

func describeHID(_ e: IOHIDEventRef, depth: Int = 0) -> String {
    guard let getType = hidGetType else { return "?" }
    let type = getType(e)
    var s = String(repeating: "  ", count: depth) + "hid type=\(type) sender=0x\(String(hidSenderID?(e) ?? 0, radix: 16))"
    if type == kHIDTypeDigitizer, let gi = hidGetInt, let gf = hidGetFloat {
        s += String(format: " transducer=%d index=%d id=%d mask=0x%x range=%d touch=%d x=%.4f y=%.4f displayIntegrated=%d",
                    gi(e, fType), gi(e, fIndex), gi(e, fIdentity), gi(e, fEventMask), gi(e, fRange), gi(e, fTouch),
                    gf(e, fX), gf(e, fY), gi(e, fDisplayIntegrated))
    }
    if let kids = hidChildren?(e)?.takeUnretainedValue() as? [AnyObject] {
        for k in kids { s += "\n" + describeHID(OpaquePointer(Unmanaged.passUnretained(k).toOpaque()), depth: depth + 1) }
    }
    return s
}

// MARK: - Event tap (listen-only)

let kDirectTouch: UInt32 = 37   // NSEventTypeDirectTouch; CG value assumed equal, verified by the tap
var lastLoggedType: UInt32 = .max

func startEventTap() {
    let callback: CGEventTapCallBack = { _, type, event, _ in
        let raw = type.rawValue
        // Skip plain pointer-move noise unless it repeats something new.
        if raw == CGEventType.mouseMoved.rawValue && lastLoggedType == raw { return Unmanaged.passUnretained(event) }
        lastLoggedType = raw
        var line = "TAP type=\(raw) loc=\(event.location) pid=\(event.getIntegerValueField(.eventSourceUnixProcessID))"
        if raw == kGestureEvent || raw == 30 { line += " fields: " + dumpGestureFields(event) }
        if let hid = cgCopyHID?(event) { line += "\n" + describeHID(hid, depth: 1) }
        log(line)
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: CGEventMask.max, callback: callback, userInfo: nil) else {
        log("event tap: FAILED (grant Input Monitoring to TouchProbe and relaunch)")
        return
    }
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("event tap: listening")
}

// MARK: - Touch logging view

final class TouchLogRecognizer: NSGestureRecognizer {
    private var last: NSPoint = .zero
    override func location(in view: NSView?) -> NSPoint { view?.convert(last, from: nil) ?? last }
    private func dump(_ what: String, _ event: NSEvent) {
        let touches = event.touches(matching: .any, in: view)
        let desc = touches.map { t -> String in
            let p = t.type == .direct ? t.location(in: view) : t.normalizedPosition
            return "\(t.type == .direct ? "DIRECT" : "indirect") id=\(t.identity.hash) phase=\(t.phase.rawValue) at=\(p)"
        }.joined(separator: "; ")
        log("GR \(what) eventType=\(event.type.rawValue) n=\(touches.count) [\(desc)]")
        if let t = touches.first, t.type == .direct, let v = view { last = v.convert(t.location(in: v), to: nil) }
    }
    override func touchesBegan(with event: NSEvent) { dump("touchesBegan", event); state = .began }
    override func touchesMoved(with event: NSEvent) { dump("touchesMoved", event); state = .changed }
    override func touchesEnded(with event: NSEvent) { dump("touchesEnded", event); state = .ended }
    override func touchesCancelled(with event: NSEvent) { dump("touchesCancelled", event); state = .cancelled }
}

final class ProbeView: NSView, NSGestureRecognizerDelegate {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.15).cgColor
        let touch = TouchLogRecognizer(target: self, action: #selector(noop))
        // Setting allowedTouchTypes throws on macOS 27.0.1; the default is logged instead.
        log("touch recognizer allowedTouchTypes default=\(touch.allowedTouchTypes.rawValue)")
        touch.delegate = self
        addGestureRecognizer(touch)
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        click.delegate = self
        addGestureRecognizer(click)
        let mag = NSMagnificationGestureRecognizer(target: self, action: #selector(magnified(_:)))
        mag.delegate = self
        addGestureRecognizer(mag)
        let press = NSPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.delegate = self
        addGestureRecognizer(press)
    }
    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ g: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith o: NSGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        log("delegate shouldReceive touch type=\(touch.type == .direct ? "DIRECT" : "indirect") recognizer=\(type(of: g))")
        return true
    }

    @objc func noop() {}
    @objc func clicked(_ g: NSClickGestureRecognizer) { log("NSClickGestureRecognizer state=\(g.state.rawValue) at=\(g.location(in: self))") }
    @objc func magnified(_ g: NSMagnificationGestureRecognizer) { log("NSMagnificationGestureRecognizer state=\(g.state.rawValue) mag=\(g.magnification)") }
    @objc func pressed(_ g: NSPressGestureRecognizer) { log("NSPressGestureRecognizer state=\(g.state.rawValue)") }

    override func mouseDown(with e: NSEvent) { log("mouseDown subtype=\(e.subtype.rawValue) at=\(convert(e.locationInWindow, from: nil))") }
    override func mouseUp(with e: NSEvent) { log("mouseUp clickCount=\(e.clickCount)") }
    override func rightMouseDown(with e: NSEvent) { log("rightMouseDown") }
    override func scrollWheel(with e: NSEvent) { log("scrollWheel phase=\(e.phase.rawValue) momentum=\(e.momentumPhase.rawValue) dy=\(e.scrollingDeltaY)") }
    override func magnify(with e: NSEvent) { log("magnify(with:) \(e.magnification)") }
    override func rotate(with e: NSEvent) { log("rotate(with:) \(e.rotation)") }
}

// MARK: - Injection experiment

func makeDigitizer(x: Double, y: Double, touching: Bool) -> IOHIDEventRef? {
    guard let createHand = hidCreateDigitizer, let createFinger = hidCreateFinger, let append = hidAppend else { return nil }
    let ts = mach_absolute_time()
    let rangeBit: UInt32 = 1, touchBit: UInt32 = 2, positionBit: UInt32 = 4
    let mask = touchBit | rangeBit | positionBit
    // Transducer type 3 = hand (collection), as iOS digitizers report it.
    guard let hand = createHand(nil, ts, 3, 0, 0, mask, 0, x, y, 0, touching ? 1 : 0, 0, touching, touching, 0),
          let finger = createFinger(nil, ts, 1, 2, mask, x, y, 0, touching ? 1 : 0, 0, touching, touching, 0) else { return nil }
    hidSetInt?(hand, fDisplayIntegrated, 1)
    hidSetInt?(finger, fDisplayIntegrated, 1)
    append(hand, finger, 0)
    return hand
}

func inject(in window: NSWindow) {
    guard let setHID = slSetHID, let setType = cgSetType, let screen = window.screen else {
        log("inject: required symbols missing"); return
    }
    // AppKit global coords are y-up from the primary screen; CG global coords are y-down.
    let primaryHeight = NSScreen.screens[0].frame.height
    let center = CGPoint(x: window.frame.midX, y: primaryHeight - window.frame.midY)
    let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    let bounds = CGDisplayBounds(displayID)
    let nx = Double((center.x - bounds.minX) / bounds.width)
    let ny = Double((center.y - bounds.minY) / bounds.height)
    log("inject: CGPreflightPostEventAccess=\(CGPreflightPostEventAccess()) target=\(center) normalized=(\(nx), \(ny))")

    for (touching, label) in [(true, "down"), (false, "up")] {
        guard let hid = makeDigitizer(x: nx, y: ny, touching: touching), let ev = CGEvent(source: nil) else { continue }
        setType(ev, kDirectTouch)
        ev.location = center
        setHID(ev, hid)
        log("inject \(label): built CGEvent type=\(ev.type.rawValue)\n" + describeHID(hid, depth: 1))
        ev.postToPid(getpid())
        log("inject \(label): posted to own pid")
        ev.post(tap: .cghidEventTap)
        log("inject \(label): posted to HID tap")
        usleep(80_000)
    }
}

// MARK: - Magnify experiment (gesture CGEvent, fields as in Hammerspoon's TouchEvents.c)

let kGestureEvent: UInt32 = 29        // NSEventTypeGesture
let fGestureSubtype = CGEventField(rawValue: 110)!   // 0x6E: IOHID event type of the gesture
let fGesturePhase = CGEventField(rawValue: 132)!     // 0x84: IOHIDEventPhaseBits
let fGestureMagnification = CGEventField(rawValue: 113)!  // 0x71
let fGestureNextSubtype = CGEventField(rawValue: 117)!    // 0x75
let subtypeMagnify: Int64 = 8, subtypeBeginGesture: Int64 = 0x3D, subtypeEndGesture: Int64 = 0x3E

func postGesture(subtype: Int64, phase: Int64 = 0, magnification: Double? = nil, next: Int64? = nil,
                 at point: CGPoint, toPid: Bool) {
    guard let setType = cgSetType, let ev = CGEvent(source: nil) else { return }
    setType(ev, kGestureEvent)
    ev.location = point
    ev.flags = CGEventFlags(rawValue: 256)
    ev.setIntegerValueField(fGestureSubtype, value: subtype)
    ev.setIntegerValueField(fGesturePhase, value: phase)
    if let magnification { ev.setDoubleValueField(fGestureMagnification, value: magnification) }
    if let next { ev.setIntegerValueField(fGestureNextSubtype, value: next) }
    if toPid { ev.postToPid(getpid()) } else { ev.post(tap: .cghidEventTap) }
}

func magnifyExperiment(in window: NSWindow, toPid: Bool) {
    let primaryHeight = NSScreen.screens[0].frame.height
    let center = CGPoint(x: window.frame.midX, y: primaryHeight - window.frame.midY)
    log("magnify experiment: toPid=\(toPid) at=\(center) postAccess=\(CGPreflightPostEventAccess())")
    // Control: a plain scroll through the same path. If this does not arrive
    // either, the path (permissions) is the blocker, not the gesture format.
    if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0) {
        scroll.location = center
        if toPid { scroll.postToPid(getpid()) } else { scroll.post(tap: .cghidEventTap) }
    }
    postGesture(subtype: subtypeBeginGesture, next: subtypeMagnify, at: center, toPid: toPid)
    postGesture(subtype: subtypeMagnify, phase: 1, magnification: 0.05, at: center, toPid: toPid)
    for _ in 0..<5 { postGesture(subtype: subtypeMagnify, phase: 2, magnification: 0.05, at: center, toPid: toPid) }
    postGesture(subtype: subtypeMagnify, phase: 4, magnification: 0, at: center, toPid: toPid)
    postGesture(subtype: subtypeEndGesture, next: subtypeMagnify, at: center, toPid: toPid)
    log("magnify experiment: posted")
}

/// Dump the fields of a gesture event, to compare synthetic events with a real trackpad pinch.
func dumpGestureFields(_ event: CGEvent) -> String {
    var parts: [String] = []
    for raw in UInt32(100)...UInt32(180) {
        let f = CGEventField(rawValue: raw)!
        let i = event.getIntegerValueField(f), d = event.getDoubleValueField(f)
        if i != 0 || d != 0 { parts.append(d != Double(i) ? "\(raw)=\(i)/\(d)" : "\(raw)=\(i)") }
    }
    return parts.joined(separator: " ")
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        log("TouchProbe pid=\(getpid()) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) args=\(CommandLine.arguments.dropFirst())")
        for s in NSScreen.screens {
            let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
            var caps = "n/a"
            if #available(macOS 27.0, *) { caps = "\(s.touchCapabilities.rawValue)" }
            log("screen \(id) '\(s.localizedName)' frame=\(s.frame) touchCapabilities=\(caps)")
        }
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 480),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        if CommandLine.arguments.contains("--last-screen") {
            // Fill the last screen (e.g. an OpenDisplay device) so every touch
            // lands here, and follow it when that display comes and goes.
            let fill = { [weak self] in
                guard let self, let screen = NSScreen.screens.last else { return }
                self.window.setFrame(screen.visibleFrame.insetBy(dx: 8, dy: 8), display: true)
                log("window moved to '\(screen.localizedName)' \(screen.frame)")
            }
            fill()
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { _ in fill() }
        }
        window.title = "TouchProbe — touch here"
        window.contentView = ProbeView(frame: window.contentLayoutRect)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startEventTap()
        if CommandLine.arguments.contains("--inject") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { inject(in: self.window) }
        }
        if CommandLine.arguments.contains("--magnify") {
            let toPid = !CommandLine.arguments.contains("--hid")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { magnifyExperiment(in: self.window, toPid: toPid) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
