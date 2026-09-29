import XCTest

final class StreamConfigurationTests: XCTestCase {
    func testFiveKBestUsesReceiverRasterAtSafeH264Rate() throws {
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 5120, height: 2880),
            quality: .best,
            legacyCeiling: PixelSize(width: 4096, height: 2304))

        XCTAssertEqual(config.encodedSize, PixelSize(width: 4096, height: 2304))
        XCTAssertEqual(config.framesPerSecond, 55)
        XCTAssertEqual(config.bitrate, 18_000_000)
    }

    func testFiveKCanvasIsCappedAtTheStreamSoCaptureIsOneToOne() throws {
        let canvas = VideoStreamConfiguration.canvasPixels(
            forReceiver: PixelSize(width: 5120, height: 2880))
        XCTAssertEqual(canvas, PixelSize(width: 4096, height: 2304))

        // Selecting a stream from that canvas must not scale it again.
        let config = try VideoStreamConfiguration.make(source: canvas, quality: .best)
        XCTAssertEqual(config.encodedSize, canvas)
    }

    func testCanvasKeepsPanelThatFitsTheStream() {
        let panel = PixelSize(width: 2732, height: 2048)
        XCTAssertEqual(VideoStreamConfiguration.canvasPixels(forReceiver: panel), panel)
    }

    func testCanvasFollowsReceiverDecodeCeiling() {
        let canvas = VideoStreamConfiguration.canvasPixels(
            forReceiver: PixelSize(width: 2560, height: 1600),
            legacyCeiling: PixelSize(width: 1920, height: 1920))
        XCTAssertEqual(canvas, PixelSize(width: 1920, height: 1200))
    }

    func testCanvasFallsBackToPanelWhenNoStreamIsPossible() {
        let panel = PixelSize(width: 2560, height: 1440)
        XCTAssertEqual(VideoStreamConfiguration.canvasPixels(
            forReceiver: panel,
            receiverCapabilities: [VideoCapability(codec: "hevc")]), panel)
    }

    func testLowerPresetsOnACappedCanvasKeepTheirPanelRaster() throws {
        // The canvas is capped for Best; Balanced/Fast must still scale from
        // the 5K panel, not scale the capped canvas down a second time.
        let panel = PixelSize(width: 5120, height: 2880)
        let canvas = VideoStreamConfiguration.canvasPixels(forReceiver: panel)
        let expected: [(StreamQuality, PixelSize)] = [
            (.best, PixelSize(width: 4096, height: 2304)),
            (.balanced, PixelSize(width: 3840, height: 2160)),
            (.fast, PixelSize(width: 2560, height: 1440)),
        ]
        for (quality, size) in expected {
            let config = try VideoStreamConfiguration.makeForCanvas(
                canvas, panel: panel, quality: quality)
            XCTAssertEqual(config.encodedSize, size, "\(quality)")
        }
    }

    func testMacReceiverHelloCapsCanvasAndCapturesOneToOne() throws {
        // What the Mac receiver sends on a 5K iMac: its panel plus the
        // legacy 4096x2304 decode ceiling.
        let panel = PixelSize(width: 5120, height: 2880)
        let ceiling = PixelSize(width: 4096, height: 2304)
        let canvas = VideoStreamConfiguration.canvasPixels(forReceiver: panel,
                                                          legacyCeiling: ceiling)
        XCTAssertEqual(canvas, ceiling)
        let config = try VideoStreamConfiguration.makeForCanvas(
            canvas, panel: panel, quality: .best, legacyCeiling: ceiling)
        XCTAssertEqual(config.encodedSize, canvas)
    }

    func testLevelTrimmedCanvasRoundTripsThroughVirtualCanvasSizing() throws {
        // A 4.5K panel is trimmed by the H.264 level, then rounded to even
        // points; whatever lands on the display must be captured 1:1.
        let panel = PixelSize(width: 4480, height: 2520)
        let canvas = VideoStreamConfiguration.canvasPixels(forReceiver: panel)
        let display = try XCTUnwrap(VirtualCanvasSizing.requested(
            pixelsWide: canvas.width, pixelsHigh: canvas.height))
        let onDisplay = PixelSize(width: display.pixelsWide, height: display.pixelsHigh)
        let config = try VideoStreamConfiguration.makeForCanvas(
            onDisplay, panel: panel, quality: .best)
        XCTAssertEqual(config.encodedSize, onDisplay)
    }

    func testDecodeBudgetThatLowersRateLeavesCanvasAtPanel() {
        let caps = [VideoCapability(codec: "h264", maxFrameRate: 60,
                                    maxPixelsPerSecond: 522_240 * 256)]
        let panel = PixelSize(width: 2048, height: 1536)
        XCTAssertEqual(VideoStreamConfiguration.canvasPixels(
            forReceiver: panel, receiverCapabilities: caps, displayMaxFrameRate: 60), panel)
    }

    func testFiveKIsBoundedByCodecLevelWithoutModelSpecificCeiling() throws {
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 5120, height: 2880), quality: .best)

        XCTAssertEqual(config.encodedSize, PixelSize(width: 4096, height: 2304))
        XCTAssertEqual(config.framesPerSecond, 55)
    }

    func testExistingQualityChoicesUseOneSafeSelector() throws {
        let source = PixelSize(width: 5120, height: 2880)
        let ceiling = PixelSize(width: 4096, height: 2304)

        let balanced = try VideoStreamConfiguration.make(
            source: source, quality: .balanced, legacyCeiling: ceiling)
        XCTAssertEqual(balanced.encodedSize, PixelSize(width: 3840, height: 2160))
        XCTAssertEqual(balanced.framesPerSecond, 60)
        XCTAssertEqual(balanced.bitrate, 10_000_000)

        let fast = try VideoStreamConfiguration.make(
            source: source, quality: .fast, legacyCeiling: ceiling)
        XCTAssertEqual(fast.encodedSize, PixelSize(width: 2560, height: 1440))
        XCTAssertEqual(fast.framesPerSecond, 60)
        XCTAssertEqual(fast.bitrate, 6_000_000)
    }

    func testCapabilityConstraintsApplyTogether() throws {
        let caps = [VideoCapability(codec: "h264", maxWidth: 3000,
                                    maxHeight: 2000, maxFrameRate: 30,
                                    maxPixelsPerSecond: 150_000_000)]
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 4000, height: 3000), quality: .best,
            receiverCapabilities: caps, displayMaxFrameRate: 120)

        XCTAssertEqual(config.encodedSize, PixelSize(width: 2666, height: 2000))
        XCTAssertEqual(config.framesPerSecond, 28)
    }

    func testMultipleCapabilityEntriesAreAlternatives() throws {
        let caps = [
            VideoCapability(codec: "future", maxWidth: 8000, maxHeight: 8000),
            VideoCapability(codec: "h264", maxWidth: 1920, maxHeight: 1080,
                            maxFrameRate: 60),
            VideoCapability(codec: "h264", maxWidth: 2560, maxHeight: 1440,
                            maxFrameRate: 30),
        ]
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 3840, height: 2160), quality: .best,
            receiverCapabilities: caps)

        XCTAssertEqual(config.encodedSize, PixelSize(width: 2560, height: 1440))
        XCTAssertEqual(config.framesPerSecond, 30)
    }

    func testCapabilityMayConstrainOneRasterAxis() throws {
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 4000, height: 3000), quality: .best,
            receiverCapabilities: [VideoCapability(codec: "h264", maxWidth: 2000)])

        XCTAssertEqual(config.encodedSize, PixelSize(width: 2000, height: 1500))
    }

    func testA8DecodeBudgetKeepsPanelRasterAndLowersRate() throws {
        // iPad Air 2 / mini 4 announce H.264 Level 4.2 throughput
        // (iOS/DecodeBudget.swift) for their 2048×1536 panel. The sender must
        // keep the panel sharp and pay in frame rate, not the other way round.
        let caps = [VideoCapability(codec: "h264", maxFrameRate: 60,
                                    maxPixelsPerSecond: 522_240 * 256)]
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 2048, height: 1536), quality: .best,
            receiverCapabilities: caps, displayMaxFrameRate: 60)

        XCTAssertEqual(config.encodedSize, PixelSize(width: 2048, height: 1536))
        XCTAssertEqual(config.framesPerSecond, 42)
    }

    func testPixelThroughputReducesRasterWhenOneFrameWouldExceedIt() throws {
        let maximum = 1_000_000
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 1920, height: 1080), quality: .best,
            receiverCapabilities: [VideoCapability(codec: "h264",
                                                    maxPixelsPerSecond: maximum)])

        XCTAssertLessThanOrEqual(config.encodedSize.width * config.encodedSize.height
            * config.framesPerSecond, maximum)
        XCTAssertEqual(config.framesPerSecond, 1)
    }

    func testUnusablePixelThroughputIsRejected() {
        XCTAssertThrowsError(try VideoStreamConfiguration.make(
            source: PixelSize(width: 1920, height: 1080), quality: .best,
            receiverCapabilities: [VideoCapability(codec: "h264",
                                                    maxPixelsPerSecond: 3)])) { error in
                XCTAssertEqual(error as? VideoStreamConfiguration.SelectionError,
                               .noCompatibleConfiguration)
            }
    }

    func testCapabilityTooSmallForEvenVideoIsRejected() {
        XCTAssertThrowsError(try VideoStreamConfiguration.make(
            source: PixelSize(width: 1920, height: 1080), quality: .best,
            receiverCapabilities: [VideoCapability(codec: "h264", maxWidth: 1)])) { error in
                XCTAssertEqual(error as? VideoStreamConfiguration.SelectionError,
                               .noCompatibleConfiguration)
            }
    }

    func testLegacyCeilingTooSmallForEvenVideoIsRejected() {
        XCTAssertThrowsError(try VideoStreamConfiguration.make(
            source: PixelSize(width: 1920, height: 1080), quality: .best,
            legacyCeiling: PixelSize(width: 1, height: 1080))) { error in
                XCTAssertEqual(error as? VideoStreamConfiguration.SelectionError,
                               .noCompatibleConfiguration)
            }
    }

    func testMissingCapabilitiesRetainLegacyH264() throws {
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 1920, height: 1080), quality: .best)
        XCTAssertEqual(config.framesPerSecond, 60)
    }

    func testExplicitCapabilitiesRequireH264() {
        XCTAssertThrowsError(try VideoStreamConfiguration.make(
            source: PixelSize(width: 1920, height: 1080), quality: .best,
            receiverCapabilities: [VideoCapability(codec: "future")])) { error in
                XCTAssertEqual(error as? VideoStreamConfiguration.SelectionError,
                               .noCompatibleCodec)
            }
    }

    func testHEVCRequiresExplicitCapability() {
        XCTAssertThrowsError(try VideoStreamConfiguration.make(
            source: PixelSize(width: 5120, height: 2880), quality: .best,
            codec: VideoStreamConfiguration.hevcCodec)) { error in
                XCTAssertEqual(error as? VideoStreamConfiguration.SelectionError,
                               .noCompatibleCodec)
            }
    }

    func testHEVC5KUsesItsOwnCapabilityInsteadOfLegacyH264Ceiling() throws {
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 5120, height: 2880), quality: .best,
            codec: VideoStreamConfiguration.hevcCodec,
            legacyCeiling: PixelSize(width: 4096, height: 2304),
            receiverCapabilities: [
                VideoCapability(codec: "h264", maxWidth: 4096, maxHeight: 2304),
                VideoCapability(codec: "hevc", maxWidth: 5120, maxHeight: 2880,
                                maxFrameRate: 60),
            ])
        XCTAssertEqual(config.codec, "hevc")
        XCTAssertEqual(config.encodedSize, PixelSize(width: 5120, height: 2880))
        XCTAssertEqual(config.framesPerSecond, 60)
    }

    private let hevcMacReceiver = [
        VideoCapability(codec: "h264", maxWidth: 4096, maxHeight: 2304, maxFrameRate: 60),
        VideoCapability(codec: "hevc", maxWidth: 5120, maxHeight: 2880, maxFrameRate: 60),
    ]

    func testSenderPrefersHEVCWheneverBothSidesCanDoItInHardware() {
        XCTAssertEqual(VideoStreamConfiguration.preferredCodec(
            receiverCapabilities: hevcMacReceiver, senderEncodesHEVC: true), "hevc")
        XCTAssertEqual(VideoStreamConfiguration.preferredCodec(
            receiverCapabilities: hevcMacReceiver, senderEncodesHEVC: false), "h264")
        XCTAssertEqual(VideoStreamConfiguration.preferredCodec(
            receiverCapabilities: [VideoCapability(codec: "h264")], senderEncodesHEVC: true), "h264")
        XCTAssertEqual(VideoStreamConfiguration.preferredCodec(
            receiverCapabilities: nil, senderEncodesHEVC: true), "h264")
        XCTAssertEqual(VideoStreamConfiguration.preferredCodec(
            receiverCapabilities: [VideoCapability(codec: "HEVC")], senderEncodesHEVC: true), "hevc")
    }

    func testHEVCCanvasFollowsThePanelUpToItsCapability() {
        let legacy = PixelSize(width: 4096, height: 2304)
        let cases: [(PixelSize, PixelSize)] = [
            (PixelSize(width: 3840, height: 2160), PixelSize(width: 3840, height: 2160)),  // 4K display
            (PixelSize(width: 4096, height: 2304), PixelSize(width: 4096, height: 2304)),  // 21.5" 4K iMac
            (PixelSize(width: 5120, height: 2880), PixelSize(width: 5120, height: 2880)),  // 5K at Default
            (PixelSize(width: 6400, height: 3600), PixelSize(width: 5120, height: 2880)),  // 5K at More Space
            (PixelSize(width: 6016, height: 3384), PixelSize(width: 5120, height: 2880)),  // 6K display
            (PixelSize(width: 3024, height: 1964), PixelSize(width: 3024, height: 1964)),  // MacBook Pro 14"
        ]
        for (panel, expected) in cases {
            let canvas = VideoStreamConfiguration.canvasPixels(
                forReceiver: panel, codec: "hevc", legacyCeiling: legacy,
                receiverCapabilities: hevcMacReceiver, displayMaxFrameRate: 60)
            XCTAssertEqual(canvas.width, expected.width, "\(panel)")
            XCTAssertLessThanOrEqual(abs(canvas.height - expected.height), 2, "\(panel)")
        }
    }

    func testHEVCPresetsOnFiveKScaleFromThePanelAtFullRate() throws {
        let panel = PixelSize(width: 5120, height: 2880)
        let canvas = VideoStreamConfiguration.canvasPixels(
            forReceiver: panel, codec: "hevc", receiverCapabilities: hevcMacReceiver)
        let expected: [(StreamQuality, PixelSize)] = [
            (.best, PixelSize(width: 5120, height: 2880)),
            (.balanced, PixelSize(width: 3840, height: 2160)),
            (.fast, PixelSize(width: 2560, height: 1440)),
        ]
        for (quality, size) in expected {
            let config = try VideoStreamConfiguration.makeForCanvas(
                canvas, panel: panel, quality: quality, codec: "hevc",
                receiverCapabilities: hevcMacReceiver)
            XCTAssertEqual(config.codec, "hevc")
            XCTAssertEqual(config.encodedSize, size, "\(quality)")
            XCTAssertEqual(config.framesPerSecond, 60, "\(quality)")
        }
    }

    func testMirroringASixKDisplayToAnIPhoneIsBoundedByItsHEVCOffer() throws {
        // iOS offers HEVC up to its panel's long side on both axes.
        let iPhone = [VideoCapability(codec: "h264", maxFrameRate: 60),
                      VideoCapability(codec: "hevc", maxWidth: 2868, maxHeight: 2868, maxFrameRate: 60)]
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 6016, height: 3384), quality: .best, codec: "hevc",
            receiverCapabilities: iPhone, displayMaxFrameRate: 120)
        XCTAssertEqual(config.encodedSize.width, 2868)
        XCTAssertLessThanOrEqual(abs(config.encodedSize.height - 1613), 2)
        XCTAssertEqual(config.framesPerSecond, 60)
    }

    func testHEVCHonoursADecodeBudget() throws {
        let budget = 1920 * 1080 * 30
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 1920, height: 1080), quality: .best, codec: "hevc",
            receiverCapabilities: [VideoCapability(codec: "hevc", maxFrameRate: 60,
                                                   maxPixelsPerSecond: budget)])
        XCTAssertEqual(config.encodedSize, PixelSize(width: 1920, height: 1080))
        XCTAssertLessThanOrEqual(config.encodedSize.width * config.encodedSize.height
                                 * config.framesPerSecond, budget)
    }

    func testH264FallbackFromAnHEVCSizedCanvasStaysInsideTheH264Level() throws {
        // The encoder fallback keeps the 5K canvas it already built.
        let config = try VideoStreamConfiguration.makeForCanvas(
            PixelSize(width: 5120, height: 2880), panel: PixelSize(width: 5120, height: 2880),
            quality: .best, codec: "h264", legacyCeiling: PixelSize(width: 4096, height: 2304),
            receiverCapabilities: hevcMacReceiver)
        XCTAssertEqual(config.codec, "h264")
        XCTAssertEqual(config.encodedSize, PixelSize(width: 4096, height: 2304))
    }

    func testOddDimensionsRoundDownAndPreserveAspectWhenCapped() throws {
        let config = try VideoStreamConfiguration.make(
            source: PixelSize(width: 4097, height: 2305), quality: .best,
            legacyCeiling: PixelSize(width: 3001, height: 2001))
        XCTAssertEqual(config.encodedSize, PixelSize(width: 3000, height: 1688))
    }

    func testInvalidSourceFailsClearly() {
        XCTAssertThrowsError(try VideoStreamConfiguration.make(
            source: PixelSize(width: 0, height: 1080), quality: .best))
    }

    func testFractionalLimiterProduces55From60HzSource() {
        var limiter = FrameRateLimiter(framesPerSecond: 55)
        let accepted = (0..<600).filter { limiter.shouldSubmit(at: Double($0) / 60) }
        XCTAssertEqual(accepted.count, 550)
    }

    func testLimiterPreservesDeferredFinalFrameAndAvoidsDuplicates() {
        var limiter = FrameRateLimiter(framesPerSecond: 55)
        XCTAssertTrue(limiter.shouldSubmit(at: 0))
        XCTAssertFalse(limiter.shouldSubmit(at: 1.0 / 60))
        XCTAssertTrue(limiter.shouldSubmit(at: 1.0 / 60 + 0.030))
        XCTAssertFalse(limiter.shouldSubmit(at: 1.0 / 60 + 0.030))
    }

    func testLimiterDoesNotBurstAfterIdleAndIgnoresInvalidTime() {
        var limiter = FrameRateLimiter(framesPerSecond: 55)
        XCTAssertTrue(limiter.shouldSubmit(at: .nan))
        XCTAssertTrue(limiter.shouldSubmit(at: 0))
        XCTAssertTrue(limiter.shouldSubmit(at: 86_400))
        XCTAssertFalse(limiter.shouldSubmit(at: 86_400))
    }

    func testSelectedRateRejectsDuplicateTimestamp() {
        var limiter = FrameRateLimiter(framesPerSecond: 60)
        XCTAssertTrue(limiter.shouldSubmit(at: 0))
        XCTAssertFalse(limiter.shouldSubmit(at: 0))
        XCTAssertTrue(limiter.shouldSubmit(at: 1.0 / 60))
    }

    func testSelected60FpsCapsA120HzSource() {
        var limiter = FrameRateLimiter(framesPerSecond: 60)
        let accepted = (0..<1_200).filter { limiter.shouldSubmit(at: Double($0) / 120) }
        XCTAssertEqual(accepted.count, 600)
    }

    func testVideoCapabilityCodableKeepsUnknownFieldsAdditive() throws {
        let json = Data(#"{"codec":"h264","maxWidth":4096,"future":true}"#.utf8)
        let capability = try JSONDecoder().decode(VideoCapability.self, from: json)
        XCTAssertEqual(capability.codec, "h264")
        XCTAssertEqual(capability.maxWidth, 4096)
        XCTAssertNil(capability.maxHeight)
    }
}
