// Renders the DMG window background (background.png and background@2x.png)
// from laptop.png and layout.json. Finder draws the real app icon and the
// real Applications alias on top, at the positions in layout.json, so this
// image holds only the artwork around them: the laptop whose screen frames
// the Applications alias, the arrow, and the sparkle marks.
//
// build.sh runs this on every build, so the art always matches layout.json.
// To look at the art alone:
//   swift tools/dmg/render-background.swift <output directory>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Layout: Decodable {
    struct Size: Decodable { let width, height: CGFloat }
    struct Point: Decodable { let x, y: CGFloat }
    let window: Size
    let iconSize: CGFloat
    let textSize: CGFloat
    let app: Point
    let applications: Point
}

// laptop.png geometry, in its own pixels.
let artScreenCenter = CGPoint(x: 626.5, y: 525.5)  // middle of the display area
let artScreenHeight: CGFloat = 459
let artLidLeft: CGFloat = 195                      // the arrow points at this edge
let artLidTopRight = CGPoint(x: 1058, y: 221)      // the sparkles sit off this corner

let ink = CGColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1)
let stroke: CGFloat = 3.5

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-background.swift <output directory>\n".utf8))
    exit(64)
}
let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let layout = try JSONDecoder().decode(
    Layout.self, from: Data(contentsOf: dir.appendingPathComponent("layout.json")))
guard let source = CGImageSourceCreateWithURL(dir.appendingPathComponent("laptop.png") as CFURL, nil),
      let laptop = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fatalError("cannot read laptop.png") }

// Points per laptop.png pixel. A display area 1.31 icons tall frames the
// folder and its label with room to spare, so the laptop grows with the icon.
let laptopScale = 1.31 * layout.iconSize / artScreenHeight
// Finder's Applications folder art leaves about 13% of the icon empty above
// the folder, and the label sits about 3 pt below the icon, one line
// (~1.23 × textSize) tall. Drop the screen centre below the icon centre so the
// folder and label sit in the middle of the screen together.
let labelDrop = (0.13 * layout.iconSize + 3 + 1.23 * layout.textSize) / 2

let screenCenter = CGPoint(x: layout.applications.x, y: layout.applications.y + labelDrop)
func laptopPoint(_ p: CGPoint) -> CGPoint {
    CGPoint(x: screenCenter.x + (p.x - artScreenCenter.x) * laptopScale,
            y: screenCenter.y + (p.y - artScreenCenter.y) * laptopScale)
}
let laptopRect = CGRect(origin: laptopPoint(.zero),
                        size: CGSize(width: CGFloat(laptop.width) * laptopScale,
                                     height: CGFloat(laptop.height) * laptopScale))
let lidLeft = laptopPoint(CGPoint(x: artLidLeft, y: 0)).x
let lidCorner = laptopPoint(artLidTopRight)

func render(scale: CGFloat, to url: URL) throws {
    let width = Int(layout.window.width * scale), height = Int(layout.window.height * scale)
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("cannot create context") }
    // Work in points with a top-left origin, like Finder's icon coordinates.
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.interpolationQuality = .high

    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: layout.window.width, height: layout.window.height))

    ctx.saveGState()
    ctx.translateBy(x: laptopRect.minX, y: laptopRect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(laptop, in: CGRect(origin: .zero, size: laptopRect.size))
    ctx.restoreGState()

    ctx.setStrokeColor(ink)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // A loose hand-drawn arc from the app icon to the laptop.
    let start = CGPoint(x: layout.app.x + layout.iconSize / 2 + 22, y: layout.app.y + 14)
    let end = CGPoint(x: lidLeft - 20, y: layout.applications.y + 2)
    let span = end.x - start.x
    let c1 = CGPoint(x: start.x + span * 0.28, y: start.y - 30)
    let c2 = CGPoint(x: start.x + span * 0.70, y: end.y - 9)
    ctx.move(to: start)
    ctx.addCurve(to: end, control1: c1, control2: c2)
    ctx.strokePath()

    let heading = atan2(end.y - c2.y, end.x - c2.x)
    for side in [-1.0, 1.0] {
        let angle = heading + .pi - side * 0.62
        ctx.move(to: end)
        ctx.addLine(to: CGPoint(x: end.x + cos(angle) * 15, y: end.y + sin(angle) * 15))
    }
    ctx.strokePath()

    // Sparkle marks off the lid's top-right corner.
    for (from, to) in [((-21.0, -31.0), (-13.0, -56.0)),
                       ((-3.0, -17.0), (19.0, -43.0)),
                       ((8.0, 0.0), (32.0, -8.0))] {
        ctx.move(to: CGPoint(x: lidCorner.x + from.0, y: lidCorner.y + from.1))
        ctx.addLine(to: CGPoint(x: lidCorner.x + to.0, y: lidCorner.y + to.1))
    }
    ctx.strokePath()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot encode \(url.lastPathComponent)") }
    let dpi = 72 * scale
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi,
                                             kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
    print("wrote \(url.lastPathComponent) (\(width)x\(height))")
}

try render(scale: 1, to: outputDir.appendingPathComponent("background.png"))
try render(scale: 2, to: outputDir.appendingPathComponent("background@2x.png"))
