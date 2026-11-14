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

final class PhysicalDisplaySizeTests: XCTestCase {
    private func facts(_ w: Int, _ h: Int, scale: Double) -> PanelFacts {
        PanelFacts(pixelsWide: w, pixelsHigh: h, scale: scale, pointsWide: nil, pointsHigh: nil)
    }

    private func declared(reported: CGSize? = nil, _ facts: PanelFacts, device: String?,
                          creation: VirtualCanvasSize) -> (size: CGSize, source: PhysicalDisplaySize.Source) {
        PhysicalDisplaySize.declared(reported: reported, facts: facts, device: device, creation: creation)
    }

    private func assertWithinMacOSLimits(_ size: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        // 27.0.1 ignores a width under ~170 mm; 26.1 never brings an area
        // under ~160 cm² online with the 8,192-pixel reservation (#479).
        XCTAssertGreaterThanOrEqual(size.width, 180, file: file, line: line)
        XCTAssertGreaterThanOrEqual(size.width * size.height, 208 * 96, file: file, line: line)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 2_001, file: file, line: line)
    }

    func testIPhoneIsEstimatedAndScaledUpToTheAreaFloorInLandscape() {
        // iPhone 15 Pro, 2556x1179 @3: ~141x65 mm at 460 ppi, scaled up
        // (same shape) to the 208x96 area, rounded up.
        let result = declared(facts(2_556, 1_179, scale: 3), device: "iPhone",
                              creation: VirtualCanvasSize(pointsWide: 1_278, pointsHigh: 588))
        XCTAssertEqual(result.source, .estimated)
        XCTAssertEqual(result.size, CGSize(width: 209, height: 96))
        assertWithinMacOSLimits(result.size)
    }

    func testPortraitPhoneIsHeldAtTheMinimumWidth() {
        // 96x208 (the old portrait constant) is ignored by macOS 27.0.1:
        // the width floor, not the area, decides a portrait phone.
        let result = declared(facts(1_179, 2_556, scale: 3), device: "iPhone",
                              creation: VirtualCanvasSize(pointsWide: 588, pointsHigh: 1_278))
        XCTAssertEqual(result.size.width, 180)
        XCTAssertEqual(result.size.height, 391)
        assertWithinMacOSLimits(result.size)
    }

    func testIPadLandscapeIsDeclaredAtItsRealSize() {
        // iPad Air 11", 2360x1640 @2 at 264 ppi: 227x158 mm, inside every limit.
        let result = declared(facts(2_360, 1_640, scale: 2), device: "iPad",
                              creation: VirtualCanvasSize(pointsWide: 1_180, pointsHigh: 820))
        XCTAssertEqual(result.size, CGSize(width: 228, height: 158))
    }

    func testOrientationFollowsTheCreationCanvasNotTheReport() {
        // The size is fixed at creation, so it takes the creation canvas's
        // orientation even if the facts arrive in the other one.
        let result = declared(facts(2_360, 1_640, scale: 2), device: "iPad",
                              creation: VirtualCanvasSize(pointsWide: 820, pointsHigh: 1_180))
        XCTAssertLessThan(result.size.width, result.size.height)
        assertWithinMacOSLimits(result.size)
    }

    func testPlausibleReportedSizeWins() {
        // A 15.6" 1920x1080 Android panel (#479) on a 1x desktop: real size.
        let result = declared(reported: CGSize(width: 344.2, height: 193.6),
                              facts(1_920, 1_080, scale: 1.375), device: "Android tablet",
                              creation: VirtualCanvasSize(pointsWide: 1_920, pointsHigh: 1_080, scale: 1))
        XCTAssertEqual(result.source, .reported)
        XCTAssertEqual(result.size, CGSize(width: 345, height: 194))
    }

    func testImplausibleReportedSizesFallBackToTheEstimate() {
        let panel = facts(2_560, 1_440, scale: 1)
        let bogus = [
            CGSize(width: 0, height: 0),
            CGSize(width: -597, height: 336),
            CGSize(width: Double.nan, height: 336),
            CGSize(width: 10, height: 6),          // 6,500 ppi
            CGSize(width: 5_000, height: 2_800),   // 13 ppi
            CGSize(width: 336, height: 597),       // the other orientation
            CGSize(width: 597, height: 150),       // wrong shape
        ]
        for size in bogus {
            let result = declared(reported: size, panel, device: "Mac",
                                  creation: VirtualCanvasSize(pointsWide: 2_560, pointsHigh: 1_440, scale: 1))
            XCTAssertEqual(result.source, .estimated, "\(size)")
            // 2560x1440 at the 1x Mac estimate, 110 ppi.
            XCTAssertEqual(result.size, CGSize(width: 592, height: 333), "\(size)")
        }
    }

    func testHiDPIDesktopIsHeldAboveTheOneXDefaultDensity() {
        // A 27" 5K Mac (597x336 mm) starts from the 3200x1800-pixel bootstrap
        // mode: 136 ppi of width, where macOS picks the 1x mode by default.
        let result = declared(reported: CGSize(width: 597, height: 336),
                              facts(5_120, 2_880, scale: 2), device: "Mac",
                              creation: VirtualCanvasSize(pointsWide: 1_600, pointsHigh: 900))
        XCTAssertEqual(result.source, .reported)
        XCTAssertEqual(result.size.width, 508)
        XCTAssertGreaterThanOrEqual(3_200 / (result.size.width / 25.4), 159.9)
        XCTAssertEqual(result.size.width / result.size.height, 597.0 / 336.0, accuracy: 0.01)
    }

    func testOneXDesktopKeepsItsLowDensity() {
        // A 2013 iMac runs a 1x desktop: 109 ppi is its real density.
        let result = declared(reported: CGSize(width: 597, height: 336),
                              facts(2_560, 1_440, scale: 1), device: "Mac",
                              creation: VirtualCanvasSize(pointsWide: 2_560, pointsHigh: 1_440, scale: 1))
        XCTAssertEqual(result.size, CGSize(width: 597, height: 336))
    }

    func testFloorsWinOverTheDensityHold() {
        // A small 2x portrait canvas cannot be both 160 ppi and 180 mm wide:
        // coming online wins.
        let result = declared(facts(750, 1_334, scale: 2), device: "iPhone",
                              creation: VirtualCanvasSize(pointsWide: 375, pointsHigh: 667))
        assertWithinMacOSLimits(result.size)
        XCTAssertEqual(result.size.width, 180)
    }

    func testHugeSizesAreCapped() {
        // Capped on the long side, same shape.
        let size = PhysicalDisplaySize.fitted(CGSize(width: 4_000, height: 2_250),
                                              creation: VirtualCanvasSize(pointsWide: 1_920, pointsHigh: 1_080, scale: 1))
        XCTAssertEqual(size, CGSize(width: 2_000, height: 1_125))
    }

    func testAndroidEstimateUsesItsDensity() {
        // Pixel 8, 1080x2400 @2.625: 160 x 2.625 = 420 ppi, ~65x145 mm, then
        // held at the minimum width in portrait.
        let estimate = PhysicalDisplaySize.estimated(facts: facts(1_080, 2_400, scale: 2.625),
                                                     device: "Android phone")
        XCTAssertEqual(estimate.width, 65.3, accuracy: 0.1)
        XCTAssertEqual(estimate.height, 145.1, accuracy: 0.1)
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
