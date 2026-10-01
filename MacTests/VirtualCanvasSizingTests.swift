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
