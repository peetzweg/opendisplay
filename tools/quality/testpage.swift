// Static sharpness/colour page on the OpenDisplay virtual screen.
// Writes ground-truth renders of the same view at 2x and 2.5x plus the window's
// position in virtual-display pixels, then stays up until killed.
// usage: testpage <outdir> [static|change|scroll] [frames]  (see tools/quality/README.md)
import AppKit

let W: CGFloat = 1600, H: CGFloat = 900

func dev(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(deviceRed: r, green: g, blue: b, alpha: 1) }

final class Page: NSView {
    override var isFlipped: Bool { true }
    var offset: CGFloat = 0      // scroll mode: content moves up, wrapping every H
    var blank = false            // change mode: white until the page appears
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ fg: NSColor, _ bg: NSColor? = nil) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: fg])
        if let bg { bg.setFill(); NSRect(x: x - 4, y: y - 2, width: a.size().width + 8, height: a.size().height + 4).fill() }
        a.draw(at: NSPoint(x: x, y: y))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(deviceWhite: 1, alpha: 1).setFill(); bounds.fill()
        if blank { return }
        for copy in [0, 1] as [CGFloat] {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform(); t.translateX(by: 0, yBy: copy * H - offset); t.concat()
            content()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    func content() {
        let black = NSColor(deviceWhite: 0, alpha: 1)
        let pangram = "The quick brown fox jumps over the lazy dog 0123456789 {}[]()<>=+-*/"
        var y: CGFloat = 16
        for size in [9, 10, 11, 12, 13, 15] as [CGFloat] {
            text("\(Int(size))pt  " + pangram, 16, y, .systemFont(ofSize: size), black); y += size + 8
        }
        for size in [10, 11, 12] as [CGFloat] {
            text("mono \(Int(size))  func render(_ frame: CVPixelBuffer) -> Bool { return true } // il1| O0", 16, y,
                 .monospacedSystemFont(ofSize: size, weight: .regular), black); y += size + 8
        }
        text("grey 11pt  " + pangram, 16, y, .systemFont(ofSize: 11), NSColor(deviceWhite: 0.45, alpha: 1)); y += 22
        text("light on dark 11pt  " + pangram, 16, y, .systemFont(ofSize: 11), NSColor(deviceWhite: 0.9, alpha: 1), dev(0.12, 0.12, 0.14)); y += 26
        // Coloured text: the chroma-subsampling stress case.
        let pairs: [(String, NSColor, NSColor?)] = [
            ("red on white", dev(0.85, 0.1, 0.1), nil), ("blue on white", dev(0.1, 0.2, 0.9), nil),
            ("red on blue", dev(1, 0.25, 0.25), dev(0.1, 0.15, 0.6)), ("green on magenta", dev(0.2, 0.9, 0.3), dev(0.7, 0.1, 0.6)),
            ("yellow on grey", dev(1, 0.9, 0.1), dev(0.35, 0.35, 0.35)), ("cyan on red", dev(0.3, 0.95, 1), dev(0.75, 0.1, 0.1)),
        ]
        var x: CGFloat = 16
        for (label, fg, bg) in pairs {
            text(label + " Ag 11pt", x, y, .systemFont(ofSize: 11), fg, bg); x += 260
        }
        y += 30
        // Solid patches (colour accuracy away from edges).
        let patches: [NSColor] = [
            dev(1,0,0), dev(0,1,0), dev(0,0,1), dev(0,1,1), dev(1,0,1), dev(1,1,0),
            dev(0.45,0.32,0.27), dev(0.76,0.59,0.51), dev(0.38,0.48,0.61), dev(0.35,0.42,0.26), dev(0.51,0.5,0.69), dev(0.4,0.74,0.67),
            dev(0.84,0.49,0.18), dev(0.31,0.36,0.65), dev(0.76,0.33,0.38), dev(0.37,0.24,0.42), dev(0.62,0.74,0.25), dev(0.88,0.64,0.18),
            dev(0.95,0.95,0.95), dev(0.78,0.78,0.78), dev(0.63,0.63,0.63), dev(0.48,0.48,0.48), dev(0.33,0.33,0.33), dev(0.2,0.2,0.2),
        ]
        for (i, c) in patches.enumerated() {
            c.setFill(); NSRect(x: 16 + CGFloat(i % 12) * 64, y: y + CGFloat(i / 12) * 64, width: 60, height: 60).fill()
        }
        // Gradients (banding) to the right of the patches.
        let gx: CGFloat = 800, gw: CGFloat = 780
        for (row, f) in [{ (t: CGFloat) in dev(t, t, t) }, { t in dev(t, 0, 0) }, { t in dev(0, t, 0) }, { t in dev(0, 0, t) },
                         { t in dev(t, 1 - t, 0.5) }].enumerated() {
            for i in 0..<Int(gw) {
                f(CGFloat(i) / (gw - 1)).setFill()
                NSRect(x: gx + CGFloat(i), y: y + CGFloat(row) * 25, width: 1, height: 24).fill()
            }
        }
        y += 140
        // Fine detail: half-point (one device pixel at 2x) lines and checkerboards.
        black.setFill()
        for i in 0..<120 { NSRect(x: 16 + CGFloat(i), y: y, width: 0.5, height: 60).fill() }            // 1px on/off
        for i in 0..<60 { NSRect(x: 160 + CGFloat(i) * 2, y: y, width: 1, height: 60).fill() }         // 2px on/off
        for r in 0..<120 { for c in 0..<120 where (r + c) % 2 == 0 {
            NSRect(x: 300 + CGFloat(c) * 0.5, y: y + CGFloat(r) * 0.5, width: 0.5, height: 0.5).fill() } }
        dev(0.9, 0.1, 0.1).setFill()
        for i in 0..<60 { NSRect(x: 380 + CGFloat(i) * 2, y: y, width: 1, height: 60).fill() }         // red 2px lines
        text("Small print 8pt: " + pangram + " " + pangram, 520, y + 4, .systemFont(ofSize: 8), black)
        text("Small print 8pt blue: " + pangram, 520, y + 20, .systemFont(ofSize: 8), dev(0.1, 0.2, 0.9))
        text("Small print 8pt red: " + pangram, 520, y + 36, .systemFont(ofSize: 8), dev(0.85, 0.1, 0.1))
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
var ids = [CGDirectDisplayID](repeating: 0, count: 32); var count: UInt32 = 0
CGGetOnlineDisplayList(32, &ids, &count)
guard let vd = ids.prefix(Int(count)).first(where: { CGDisplayVendorNumber($0) == 0x5043 && CGDisplayModelNumber($0) == 0x4F53 }),
      let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == vd })
else { fputs("no OpenDisplay screen\n", stderr); exit(1) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let frame = NSRect(x: screen.frame.minX + 40, y: screen.frame.maxY - 40 - H, width: W, height: H)
let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
let page = Page(frame: NSRect(x: 0, y: 0, width: W, height: H))
window.contentView = page
window.level = .screenSaver
window.orderFrontRegardless()

for scale in [2.0, 2.5] as [CGFloat] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    page.cacheDisplay(in: page.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("ref-\(scale)x.png"))
}
let s = screen.backingScaleFactor
let info = ["x": (frame.minX - screen.frame.minX) * s, "y": (screen.frame.maxY - frame.maxY) * s,
            "w": W * s, "h": H * s, "backing": s, "screenW": screen.frame.width, "screenH": screen.frame.height]
try! JSONSerialization.data(withJSONObject: info).write(to: out.appendingPathComponent("rect.json"))
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "static"
if mode == "change" {
    page.blank = true; page.needsDisplay = true
    let n = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "40"
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-n", "-o", "BatchMode=yes", ProcessInfo.processInfo.environment["OD_RECEIVER_HOST"] ?? "imac",
                        "echo \(n) > /tmp/od-dump-request"]; try? p.run(); p.waitUntilExit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            page.blank = false; page.needsDisplay = true; print("page shown"); fflush(stdout) }
    }
} else if mode == "scroll" {
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
        page.offset = (page.offset + 4).truncatingRemainder(dividingBy: H); page.needsDisplay = true }
    RunLoop.main.add(timer, forMode: .common)
}
print("page up on display \(vd): \(info)"); fflush(stdout)
app.run()
