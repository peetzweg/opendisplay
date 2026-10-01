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

    func testSmallPhonesAreRaisedToTheTwoXMinimum() {
        // #292: macOS refuses 2x modes under 526 points on the short axis.
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(750, 1334, 2)).desktop, size(526, 936, 2))
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(1334, 750, 2)).desktop, size(936, 526, 2))
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(828, 1792, 2)).desktop, size(526, 1138, 2))
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(640, 1136, 2)).desktop, size(526, 934, 2))
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(1080, 1920, 2.608)).desktop, size(540, 960, 2))
        // Nothing at 1x is clamped.
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(750, 1334, 2), choice: .native).desktop,
                       size(750, 1334, 1))
        XCTAssertEqual(DesktopPolicy.plan(facts: facts(640, 480, 1)).desktop, size(640, 480, 1))
    }

    func testRaisedPhoneDesktopIsStreamedAtThePanel() throws {
        // Larger than the panel, so it is explicit: the stream cap must not
        // shrink it back below the 2x minimum.
        let plan = DesktopPolicy.plan(facts: facts(750, 1334, 2))
        XCTAssertTrue(plan.explicit)
        XCTAssertEqual(DesktopPolicy.canvas(for: plan), plan.desktop)
        let stream = try VideoStreamConfiguration.makeForCanvas(
            plan.desktopPixels, panel: plan.streamReference, quality: .best,
            presentable: plan.presentable)
        XCTAssertEqual(stream.encodedSize, PixelSize(width: 748, height: 1334))
    }

    func testLargerTextOnIPhone15ProIsRaisedToTheMinimum() {
        let plan = DesktopPolicy.plan(facts: facts(2556, 1179, 3), choice: .largerText)
        XCTAssertEqual(plan.desktop, size(1144, 526, 2))   // 1022x470 before D1
    }

    func testRefusedTwoXModeFallsBackToTheNativeDesktop() {
        let fallback = DesktopPolicy.oneXFallback(facts: facts(750, 1334, 2))
        XCTAssertEqual(fallback.desktop, size(750, 1334, 1))
        XCTAssertTrue(fallback.explicit)
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
        // Phones under the 2x minimum (750x1334, 828x1792) differ on purpose,
        // see testSmallPhonesAreRaisedToTheTwoXMinimum.
        let hellos: [(Int, Int)] = [(2556, 1179), (1179, 2556), (2048, 1536), (1536, 2048),
                                    (2388, 1668), (2732, 2048), (5120, 2880)]
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

final class DisplaySizeTests: XCTestCase {
    private let fiveK = PanelFacts(pixelsWide: 5120, pixelsHigh: 2880, scale: 2,
                                   pointsWide: 2560, pointsHigh: 1440)
    private let caps = [VideoCapability(codec: "h264", maxWidth: 4096, maxHeight: 2304, maxFrameRate: 60),
                        VideoCapability(codec: "hevc", maxWidth: 5120, maxHeight: 2880, maxFrameRate: 60)]

    private func outcome(_ facts: PanelFacts, _ choice: DisplaySize, hevc: Bool) -> DisplaySizeOutcome {
        DesktopPolicy.outcome(of: DesktopPolicy.plan(facts: facts, choice: choice), choice: choice,
                              codec: hevc ? "hevc" : "h264",
                              legacyCeiling: PixelSize(width: 4096, height: 2304),
                              videoCaps: caps, displayMaxFrameRate: 60)
    }

    func testFiveKCaptionsOverHEVC() {
        XCTAssertEqual(outcome(fiveK, .largerText, hevc: true).caption, "Looks like 2048 × 1152")
        XCTAssertEqual(outcome(fiveK, .default, hevc: true).caption, "Looks like 2560 × 1440")
        XCTAssertEqual(outcome(fiveK, .moreSpace, hevc: true).caption,
                       "Looks like 3200 × 1800, sends 5120 × 2880 (scaled)")
        XCTAssertEqual(outcome(fiveK, .native, hevc: true).caption, "Looks like 5120 × 2880 at 1x")
    }

    func testFiveKCaptionsOverH264() {
        // Default is capped to a 1:1 desktop; explicit sizes keep theirs, scaled.
        XCTAssertEqual(outcome(fiveK, .default, hevc: false).caption, "Looks like 2048 × 1152")
        XCTAssertEqual(outcome(fiveK, .native, hevc: false).caption,
                       "Looks like 5120 × 2880 at 1x, sends 4096 × 2304 (scaled)")
    }

    func testIPadAir2Outcomes() {
        let iPad = PanelFacts(pixelsWide: 2048, pixelsHigh: 1536, scale: 2, pointsWide: nil, pointsHigh: nil)
        let more = outcome(iPad, .moreSpace, hevc: false)
        XCTAssertEqual(more.desktop, VirtualCanvasSize(pointsWide: 1280, pointsHigh: 960, scale: 2))
        XCTAssertEqual(more.sent, PixelSize(width: 2048, height: 1536))
        XCTAssertTrue(more.scaled)
        XCTAssertFalse(outcome(iPad, .native, hevc: false).scaled)
    }

    func testPersistenceRoundTripAndKeys() {
        let defaults = UserDefaults(suiteName: "DisplaySizeTests")!
        defaults.removePersistentDomain(forName: "DisplaySizeTests")
        XCTAssertEqual(DisplaySizeStore.key(installID: "ABC", serial: 7), "displaySize.ABC")
        XCTAssertEqual(DisplaySizeStore.key(installID: nil, serial: 0x4f53), "displaySize.serial-00004f53")
        for size in DisplaySize.allCases {
            DisplaySizeStore.save(size, key: "k", to: defaults)
            XCTAssertEqual(DisplaySizeStore.load(key: "k", from: defaults), size)
        }
        defaults.set("custom", forKey: "k")
        XCTAssertEqual(DisplaySizeStore.load(key: "k", from: defaults), .default)
    }

    func testMoreSpaceOnPortraitFiveK() {
        let portrait = PanelFacts(pixelsWide: 2880, pixelsHigh: 5120, scale: 2,
                                  pointsWide: 1440, pointsHigh: 2560)
        XCTAssertEqual(DesktopPolicy.plan(facts: portrait, choice: .moreSpace).desktop,
                       VirtualCanvasSize(pointsWide: 1800, pointsHigh: 3200, scale: 2))
    }
}
