// usage: mode [WIDTHxHEIGHT] [1x]  lists the HiDPI (or with 1x, the 1x) modes of the
// main display, or switches to the one with that point size
import CoreGraphics
import Foundation
let d = CGMainDisplayID()
let opts = NSDictionary(dictionary: [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!]) as CFDictionary
let args = CommandLine.arguments.dropFirst()
let oneX = args.contains("1x")
let size = args.first(where: { $0 != "1x" })
let modes = ((CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []).filter {
    oneX ? $0.pixelWidth == $0.width : $0.pixelWidth > $0.width
}
let cur = CGDisplayCopyDisplayMode(d)!
print("current \(cur.width)x\(cur.height) px \(cur.pixelWidth)x\(cur.pixelHeight)")
if let size {
    let p = size.split(separator: "x").map { Int($0)! }
    guard let m = modes.first(where: { $0.width == p[0] && $0.height == p[1] }) else { print("no such mode"); exit(1) }
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    CGConfigureDisplayWithDisplayMode(cfg, d, m, nil)
    print("result", CGCompleteDisplayConfiguration(cfg, .permanently).rawValue)
} else {
    for m in modes { print("\(m.width)x\(m.height) px \(m.pixelWidth)x\(m.pixelHeight) \(m.refreshRate)Hz") }
}
