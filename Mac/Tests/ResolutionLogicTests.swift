// Standalone logic check — run with: swift resolution_tests_standalone.swift
// Mirrors the pure functions in Mac/VirtualDisplay.swift so the algorithm is
// verifiable WITHOUT Xcode / a real display / CoreGraphics private types.
// The real XCTest target (ResolutionTests.swift) tests the actual functions.

import Foundation

let resolutionSteps: [CGFloat] = [1.0, 0.85, 0.75, 0.67]

struct Mode { let width: UInt; let pixelWidth: UInt }
func buildModes(w: Int, h: Int) -> [Mode] {
    resolutionSteps.map { s in
        Mode(width: UInt((CGFloat(w) * s).rounded(.toNearestOrEven)),
             pixelWidth: UInt((CGFloat(w * 2) * s).rounded(.toNearestOrEven)))
    }
}
func shouldReassert(currentWidth: Int, currentPixelWidth: Int,
                    published: [Mode], settled: Bool, missingTicks: Int) -> Bool {
    let inPublished = published.contains { $0.width == UInt(currentWidth) && $0.pixelWidth == UInt(currentPixelWidth) }
    if inPublished { return false }
    if !settled { return true }
    return missingTicks >= 3
}

var pass = 0, fail = 0
func check(_ name: String, _ cond: Bool) {
    if cond { pass += 1; print("PASS  \(name)") }
    else    { fail += 1; print("FAIL  \(name)") }
}

let modes = buildModes(w: 1179, h: 2556)
// 1. multiple modes published (native first)
check("publishes >1 mode", modes.count > 1)
check("native mode first = 1179x2358", modes[0].width == 1179 && modes[0].pixelWidth == 2358)
check("scaled steps present", modes.count == resolutionSteps.count)

// 2. user-picked scaled mode must NOT be reverted (the bug fix)
let scaled = modes[2]
check("scaled choice stands when settled",
      !shouldReassert(currentWidth: Int(scaled.width), currentPixelWidth: Int(scaled.pixelWidth),
                      published: modes, settled: true, missingTicks: 0))

// 3. native @2x when settled -> no reassert
check("native stands when settled",
      !shouldReassert(currentWidth: 1179, currentPixelWidth: 2358, published: modes, settled: true, missingTicks: 0))

// 4. 1x relapse (not published) while NOT settled -> reassert (startup race)
check("1x relapse before settle -> reassert",
      shouldReassert(currentWidth: 1179, currentPixelWidth: 1179, published: modes, settled: false, missingTicks: 0))

// 5. 1x relapse when settled but <3 ticks -> do NOT fire (debounce, #29)
check("1x relapse settled <3 ticks -> hold",
      !shouldReassert(currentWidth: 1179, currentPixelWidth: 1179, published: modes, settled: true, missingTicks: 2))

// 6. 1x relapse when settled >=3 ticks -> reassert (recover, #29)
check("1x relapse settled >=3 ticks -> reassert",
      shouldReassert(currentWidth: 1179, currentPixelWidth: 1179, published: modes, settled: true, missingTicks: 3))

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
