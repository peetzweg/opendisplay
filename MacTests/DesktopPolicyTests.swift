import XCTest

/// The worked examples of PLAN-display-sizing.md section 4.3.
final class DesktopPolicyTests: XCTestCase {
    private func facts(_ w: Int, _ h: Int, _ scale: Double,
                       points: (Int, Int)? = nil) -> PanelFacts {
        PanelFacts(pixelsWide: w, pixelsHigh: h, scale: scale,
                   pointsWide: points?.0, pointsHigh: points?.1)
    }

    private func size(_ w: Int, _ h: Int, _ scale: Int) -> VirtualCanvasSize {
        VirtualCanvasSize(pointsWide: w, pointsHigh: h, scale: scale)
    }

    private let macH264 = PixelSize(width: 4096, height: 2304)
    private let macCaps = [VideoCapability(codec: "h264", maxWidth: 4096, maxHeight: 2304, maxFrameRate: 60),
                           VideoCapability(codec: "hevc", maxWidth: 5120, maxHeight: 2880, maxFrameRate: 60)]
    private let macPortraitCaps = [VideoCapability(codec: "h264", maxWidth: 2304, maxHeight: 4096, maxFrameRate: 60),
                                   VideoCapability(codec: "hevc", maxWidth: 2880, maxHeight: 5120, maxFrameRate: 60)]

    private func macCanvas(_ plan: DesktopPlan, hevc: Bool, portrait: Bool = false,
                           swappedCaps: Bool = true) -> VirtualCanvasSize {
        let caps = portrait && swappedCaps ? macPortraitCaps : macCaps
        let ceiling = portrait && swappedCaps ? PixelSize(width: 2304, height: 4096) : macH264
        return DesktopPolicy.canvas(for: plan,
                                    codec: hevc ? VideoStreamConfiguration.hevcCodec
                                                : VideoStreamConfiguration.h264Codec,
                                    legacyCeiling: ceiling, videoCaps: caps,
                                    displayMaxFrameRate: 60)
    }

    // MARK: iOS

    func testIPhone15ProGetsHalfItsPixelsAt2xInEitherOrientation() {
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(1179, 2556, 3)).desktop, size(588, 1278, 2))
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(2556, 1179, 3)).desktop, size(1278, 588, 2))
        let plan = DesktopPolicy.plan(facts: facts(1179, 2556, 3))
        XCTAssertFalse(plan.explicit)
        XCTAssertEqual(DesktopPolicy.canvas(for: plan), plan.desktop)
    }

    func testIPhone8DefaultIsStillHalfItsPixels() {
        // Below macOS's 2x minimum; step 2 clamps it.
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(750, 1334, 2)).desktop, size(374, 666, 2))
    }

    func testIPadAir2Presets() {
        let panel = facts(2048, 1536, 2)
        XCTAssertEqual(DesktopPolicy.plan(facts: panel).desktop, size(1024, 768, 2))
        XCTAssertEqual(DesktopPolicy.plan(facts: panel, choice: .native).desktop, size(2048, 1536, 1))
        let more = DesktopPolicy.plan(facts: panel, choice: .moreSpace)
        XCTAssertEqual(more.desktop, size(1280, 960, 2))
        XCTAssertTrue(more.explicit)
        XCTAssertEqual(more.streamReference, PixelSize(width: 2048, height: 1536))
    }

    func testFractionalAndOneXReceivers() {
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(1080, 2400, 2.75)).desktop, size(540, 1200, 2))
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(1920, 1080, 1)).desktop, size(1920, 1080, 1))
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(1536, 864, 1.25)).desktop, size(1536, 864, 1))
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(3840, 2160, 1)).desktop, size(3840, 2160, 1))
    }

    // MARK: Mac receivers

    func testFiveKRetinaDefault() {
        let plan = DesktopPolicy.plan(facts: facts(5120, 2880, 2, points: (2560, 1440)))
        XCTAssertEqual(plan.desktop, size(2560, 1440, 2))
        XCTAssertFalse(plan.explicit)
        XCTAssertEqual(macCanvas(plan, hevc: true), size(2560, 1440, 2))
        XCTAssertEqual(macCanvas(plan, hevc: false), size(2048, 1152, 2))   // D3, 4096x2304 1:1
    }

    func testFiveKRetinaPresets() {
        let panel = facts(5120, 2880, 2, points: (2560, 1440))
        let larger = DesktopPolicy.plan(facts: panel, choice: .largerText)
        XCTAssertEqual(larger.desktop, size(2048, 1152, 2))
        XCTAssertEqual(macCanvas(larger, hevc: false), size(2048, 1152, 2))
        let more = DesktopPolicy.plan(facts: panel, choice: .moreSpace)
        XCTAssertEqual(more.desktop, size(3200, 1800, 2))
        XCTAssertEqual(macCanvas(more, hevc: false), size(3200, 1800, 2))   // explicit: no D3
        let native = DesktopPolicy.plan(facts: panel, choice: .native)
        XCTAssertEqual(native.desktop, size(5120, 2880, 1))
        XCTAssertEqual(macCanvas(native, hevc: false), size(5120, 2880, 1))
    }

    func testReceiverAtMoreSpaceIsExplicitAndNotShrunk() {
        let plan = DesktopPolicy.plan(facts: facts(5120, 2880, 2, points: (3200, 1800)))
        XCTAssertEqual(plan.desktop, size(3200, 1800, 2))
        XCTAssertTrue(plan.explicit)
        XCTAssertEqual(macCanvas(plan, hevc: false), size(3200, 1800, 2))
        XCTAssertEqual(plan.streamReference, PixelSize(width: 5120, height: 2880))
    }

    func testReceiverAtLargerTextKeepsItsOneToOneDesktop() {
        let plan = DesktopPolicy.plan(facts: facts(5120, 2880, 2, points: (1600, 900)))
        XCTAssertEqual(plan.desktop, size(1600, 900, 2))
        XCTAssertFalse(plan.explicit)
        XCTAssertEqual(macCanvas(plan, hevc: false), size(1600, 900, 2))
    }

    func testNonRetinaIMacGetsItsOwnPixelsAt1x() {
        // #344: a 2013 iMac at 2560x1440 @1x over H.264.
        let panel = facts(2560, 1440, 1, points: (2560, 1440))
        let plan = DesktopPolicy.plan(facts: panel)
        XCTAssertEqual(plan.desktop, size(2560, 1440, 1))
        XCTAssertEqual(macCanvas(plan, hevc: false), size(2560, 1440, 1))
        XCTAssertEqual(DesktopPolicy.plan(facts: panel, choice: .native).desktop, plan.desktop)
        XCTAssertEqual(DesktopPolicy.plan(facts: panel, choice: .largerText).desktop,
                       size(2048, 1152, 1))
    }

    func testNotchedMacBookProRoundsToEven() {
        let plan = DesktopPolicy.plan(facts: facts(3024, 1890, 2, points: (1512, 945)))
        XCTAssertEqual(plan.desktop, size(1512, 944, 2))
        XCTAssertFalse(plan.explicit)
    }

    func testPortraitFiveKWithSwappedLimits() {
        // #324
        let plan = DesktopPolicy.plan(facts: facts(2880, 5120, 2, points: (1440, 2560)))
        XCTAssertEqual(plan.desktop, size(1440, 2560, 2))
        XCTAssertEqual(macCanvas(plan, hevc: true, portrait: true), size(1440, 2560, 2))
        XCTAssertEqual(macCanvas(plan, hevc: false, portrait: true), size(1152, 2048, 2))
        // Landscape limits on a portrait panel are what shrank it in #324.
        XCTAssertEqual(macCanvas(plan, hevc: false, portrait: true, swappedCaps: false),
                       size(648, 1152, 2))
    }

    func testMoreSpaceOnAMoreSpaceReceiverFitsTheDescriptor() {
        let plan = DesktopPolicy.plan(facts: facts(5120, 2880, 2, points: (3200, 1800)),
                                      choice: .moreSpace)
        XCTAssertEqual(plan.desktop, size(4000, 2250, 2))
        let native8K = DesktopPolicy.plan(facts: facts(7680, 4320, 2, points: (5120, 2880)),
                                          choice: .moreSpace)
        XCTAssertLessThanOrEqual(native8K.desktop.pixelsWide, DesktopPolicy.maxPixelsPerAxis)
        XCTAssertEqual(native8K.desktop, size(4096, 2304, 2))
    }

    // MARK: Legacy equivalence

    func testLegacyFactsReproduceTodaysDesktop() throws {
        let hellos: [(Int, Int)] = [(2556, 1179), (1179, 2556), (1334, 750), (1792, 828),
                                    (2048, 1536), (1536, 2048), (2388, 1668), (5120, 2880)]
        for (w, h) in hellos {
            let info = try JSONDecoder().decode(
                PhoneInfo.self, from: Data(#"{"pixelsWide":\#(w),"pixelsHigh":\#(h),"scale":2}"#.utf8))
            let plan = DesktopPolicy.plan(facts: info.facts)
            XCTAssertEqual(plan.desktop, VirtualCanvasSizing.requested(pixelsWide: w, pixelsHigh: h),
                           "\(w)x\(h)")
            // ... and today's capped canvas.
            let canvas = VideoStreamConfiguration.canvasPixels(
                forReceiver: PixelSize(width: w, height: h), legacyCeiling: macH264)
            XCTAssertEqual(DesktopPolicy.canvas(for: plan, legacyCeiling: macH264),
                           VirtualCanvasSizing.requested(pixelsWide: canvas.width,
                                                         pixelsHigh: canvas.height),
                           "\(w)x\(h)")
        }
    }
}
