import XCTest

final class VirtualCanvasSizingTests: XCTestCase {
    func testSmallCanvasStartsAtRequestedSize() {
        let requested = VirtualCanvasSizing.requested(pixelsWide: 2_388, pixelsHigh: 1_668)!
        XCTAssertEqual(VirtualCanvasSizing.bootstrap(for: requested), requested)
    }

    func testLargeLandscapeCanvasBootstrapsAtSameAspect() {
        let requested = VirtualCanvasSizing.requested(pixelsWide: 4_096, pixelsHigh: 2_304)!
        XCTAssertEqual(VirtualCanvasSizing.bootstrap(for: requested),
                       VirtualCanvasSize(pointsWide: 1_600, pointsHigh: 900))
    }

    func testLargePortraitCanvasBootstrapsWithRotatedEnvelope() {
        let requested = VirtualCanvasSizing.requested(pixelsWide: 2_304, pixelsHigh: 4_096)!
        XCTAssertEqual(VirtualCanvasSizing.bootstrap(for: requested),
                       VirtualCanvasSize(pointsWide: 900, pointsHigh: 1_600))
    }

    func testInvalidCanvasIsRejected() {
        XCTAssertNil(VirtualCanvasSizing.requested(pixelsWide: 1, pixelsHigh: 1_080))
    }

    func testPlanReservesRequestedCapacityBeyondDefaultHeadroom() {
        let plan = VirtualCanvasSizing.plan(pixelsWide: 10_240, pixelsHigh: 4_320)!

        XCTAssertEqual(plan.bootstrap,
                       VirtualCanvasSize(pointsWide: 1_600, pointsHigh: 674))
        XCTAssertEqual(plan.descriptorMaxPixelsPerAxis, 10_240)
    }

    func testPhysicalSizeFollowsCanvasOrientation() {
        let landscape = VirtualCanvasSize(pointsWide: 1_920, pointsHigh: 1_080, scale: 1)
        let portrait = VirtualCanvasSize(pointsWide: 393, pointsHigh: 852)

        XCTAssertEqual(VirtualCanvasSizing.physicalSizeInMillimeters(for: landscape),
                       CGSize(width: 208, height: 96))
        XCTAssertEqual(VirtualCanvasSizing.physicalSizeInMillimeters(for: portrait),
                       CGSize(width: 96, height: 208))
    }

    func testPhysicalSizeStaysAboveTheAreaMacOSRejects() {
        // macOS 26.1 never brings the display online below roughly 160 cm²
        // with the 8,192-pixel reservation; 147 x 68 mm (100 cm²) failed.
        for canvas in [VirtualCanvasSize(pointsWide: 1_920, pointsHigh: 1_080),
                       VirtualCanvasSize(pointsWide: 834, pointsHigh: 1_194)] {
            let size = VirtualCanvasSizing.physicalSizeInMillimeters(for: canvas)
            XCTAssertGreaterThanOrEqual(size.width * size.height, 19_000)
        }
    }
}

final class VirtualCanvasOneXTests: XCTestCase {
    func testOneXCanvasUsesPixelsAsPoints() {
        let requested = VirtualCanvasSizing.requested(pixelsWide: 2_560, pixelsHigh: 1_440, scale: 1)!
        XCTAssertEqual(requested, VirtualCanvasSize(pointsWide: 2_560, pointsHigh: 1_440, scale: 1))
        XCTAssertEqual(requested.pixelsWide, 2_560)
    }

    func testBootstrapEnvelopeIsInPixelsForEitherScale() {
        // 3200x1800 pixels: 1600x900 points at 2x, 3200x1800 points at 1x.
        let oneX = VirtualCanvasSizing.requested(pixelsWide: 3_840, pixelsHigh: 2_160, scale: 1)!
        XCTAssertEqual(VirtualCanvasSizing.bootstrap(for: oneX),
                       VirtualCanvasSize(pointsWide: 3_200, pointsHigh: 1_800, scale: 1))
    }
}
