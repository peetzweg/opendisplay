import XCTest

final class StreamNegotiationTests: XCTestCase {
    // The Mac receiver's advertised ceilings (MacReceiver.start).
    private let h264 = (wide: 4096, high: 2304)
    private let hevc = (wide: 5120, high: 2880)

    private func choose(_ w: Int, _ h: Int,
                        h264Ceiling: (wide: Int, high: Int)? = nil,
                        hevcCeiling: (wide: Int, high: Int)? = nil,
                        receiverDecodesHEVC: Bool = false,
                        forceHEVC: Bool = false,
                        encoderAvailable: Bool = true) -> StreamNegotiation.Choice {
        StreamNegotiation.choose(desiredWidth: w, desiredHeight: h,
                                 h264Ceiling: h264Ceiling, hevcCeiling: hevcCeiling,
                                 receiverDecodesHEVC: receiverDecodesHEVC,
                                 forceHEVC: forceHEVC,
                                 senderEncodesHEVC: { _, _ in encoderAvailable })
    }

    func testReceiverAdvertisingNothingKeepsFullSizeH264() {
        // A shipped phone receiver: no ceilings, no codecs field.
        let c = choose(2778, 1284)
        XCTAssertEqual(c, .init(width: 2778, height: 1284, useHEVC: false))
    }

    func testStreamInsideTheCeilingStaysH264EvenWhenReceiverDecodesHEVC() {
        // The sweet-spot rule: HEVC buys nothing below the H.264 ceiling,
        // so its extra encode cost is never paid there.
        let c = choose(3840, 2160, h264Ceiling: h264, hevcCeiling: hevc,
                       receiverDecodesHEVC: true)
        XCTAssertEqual(c, .init(width: 3840, height: 2160, useHEVC: false))
    }

    func testFiveKGoesHEVCUnclamped() {
        let c = choose(5120, 2880, h264Ceiling: h264, hevcCeiling: hevc,
                       receiverDecodesHEVC: true)
        XCTAssertEqual(c, .init(width: 5120, height: 2880, useHEVC: true))
    }

    func testSixKGoesHEVCClampedToTheHEVCCeiling() {
        let c = choose(6016, 3384, h264Ceiling: h264, hevcCeiling: hevc,
                       receiverDecodesHEVC: true)
        XCTAssertEqual(c, .init(width: 5120, height: 2880, useHEVC: true))
    }

    func testFiveKWithoutHEVCFallsBackToTheH264Cap() {
        // Receiver decodes only H.264 (2015 Mac): shipped 6.5 behavior.
        let c = choose(5120, 2880, h264Ceiling: h264, receiverDecodesHEVC: false)
        XCTAssertEqual(c, .init(width: 4096, height: 2304, useHEVC: false))
    }

    func testFiveKWithoutASenderEncoderFallsBackToTheH264Cap() {
        let c = choose(5120, 2880, h264Ceiling: h264, hevcCeiling: hevc,
                       receiverDecodesHEVC: true, encoderAvailable: false)
        XCTAssertEqual(c, .init(width: 4096, height: 2304, useHEVC: false))
    }

    func testForceHEVCOverridesTheSizeTriggerButNotReceiverSupport() {
        let forced = choose(1920, 1080, h264Ceiling: h264, hevcCeiling: hevc,
                            receiverDecodesHEVC: true, forceHEVC: true)
        XCTAssertEqual(forced, .init(width: 1920, height: 1080, useHEVC: true))

        let unsupported = choose(1920, 1080, h264Ceiling: h264,
                                 receiverDecodesHEVC: false, forceHEVC: true)
        XCTAssertEqual(unsupported, .init(width: 1920, height: 1080, useHEVC: false))
    }

    func testClampKeepsDimensionsEven() {
        let c = choose(5120, 2881, h264Ceiling: h264, receiverDecodesHEVC: false)
        XCTAssertEqual(c.width % 2, 0)
        XCTAssertEqual(c.height % 2, 0)
        XCTAssertLessThanOrEqual(c.width, h264.wide)
        XCTAssertLessThanOrEqual(c.height, h264.high)
    }
}
