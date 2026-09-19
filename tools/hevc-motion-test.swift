// Draw moving bars on one OpenDisplay virtual screen at 60 Hz so video FPS
// measurements do not depend on whether the desktop happens to be idle.
// Run on the sender: swift tools/hevc-motion-test.swift [display-id]
import AppKit
import CoreGraphics

final class MotionView: NSView {
    var step = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let x = CGFloat(step % max(1, Int(bounds.width)))
        NSColor.white.setFill()
        NSRect(x: x, y: 0, width: 100, height: bounds.height).fill()
        NSColor.systemBlue.setFill()
        NSRect(x: bounds.width - x, y: 0, width: 100, height: bounds.height).fill()
    }
}

let requestedID: CGDirectDisplayID?
if CommandLine.arguments.count == 1 {
    requestedID = nil
} else if CommandLine.arguments.count == 2,
          let id = CGDirectDisplayID(CommandLine.arguments[1]) {
    requestedID = id
} else {
    fputs("Usage: swift tools/hevc-motion-test.swift [display-id]\n", stderr)
    exit(2)
}

var ids = [CGDirectDisplayID](repeating: 0, count: 32)
var count: UInt32 = 0
guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
    fputs("Could not list displays\n", stderr)
    exit(1)
}
let openDisplayIDs = ids.prefix(Int(count)).filter {
    CGDisplayVendorNumber($0) == 0x5043 && CGDisplayModelNumber($0) == 0x4F53
}
let chosenID: CGDirectDisplayID
if let requestedID, openDisplayIDs.contains(requestedID) {
    chosenID = requestedID
} else if requestedID == nil, openDisplayIDs.count == 1 {
    chosenID = openDisplayIDs[0]
} else {
    let found = openDisplayIDs.map(String.init).joined(separator: ", ")
    fputs("Expected one OpenDisplay screen; found IDs: \(found). Pass its ID.\n", stderr)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let screen = NSScreen.screens.first(where: {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
        == chosenID
}) else {
    fputs("OpenDisplay screen \(chosenID) has no NSScreen\n", stderr)
    exit(1)
}

let width = min(1200, max(200, screen.frame.width - 200))
let height = min(600, max(150, screen.frame.height - 200))
let window = NSWindow(
    contentRect: NSRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100,
                        width: width, height: height),
    styleMask: [.borderless], backing: .buffered, defer: false)
let view = MotionView(frame: NSRect(x: 0, y: 0, width: width, height: height))
window.contentView = view
window.level = .floating
window.orderFrontRegardless()
print("Animating OpenDisplay screen \(chosenID) at \(screen.frame). Press Control-C to stop.")
fflush(stdout)
let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
    view.step += 13
    view.needsDisplay = true
}
RunLoop.main.add(timer, forMode: .common)
app.run()
