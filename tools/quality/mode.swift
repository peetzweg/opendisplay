// usage: mode [WIDTHxHEIGHT]  lists HiDPI modes of the main display, or switches to the one with that point size
import CoreGraphics
import Foundation
let d = CGMainDisplayID()
let opts = NSDictionary(dictionary: [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!]) as CFDictionary
let modes = ((CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []).filter { $0.pixelWidth > $0.width }
let cur = CGDisplayCopyDisplayMode(d)!
print("current \(cur.width)x\(cur.height) px \(cur.pixelWidth)x\(cur.pixelHeight)")
if CommandLine.arguments.count < 2 {
    for m in modes { print("\(m.width)x\(m.height) px \(m.pixelWidth)x\(m.pixelHeight) \(m.refreshRate)Hz") }
} else {
    let p = CommandLine.arguments[1].split(separator: "x").map { Int($0)! }
    guard let m = modes.first(where: { $0.width == p[0] && $0.height == p[1] }) else { print("no such mode"); exit(1) }
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    CGConfigureDisplayWithDisplayMode(cfg, d, m, nil)
    print("result", CGCompleteDisplayConfiguration(cfg, .permanently).rawValue)
}
