import XCTest

final class H264FrameRatePolicyTests: XCTestCase {
    func testLargeRasterUses55FPSAndSmallerRastersRemain60FPS() {
        XCTAssertEqual(H264FrameRatePolicy(width: 4096, height: 2304).framesPerSecond, 55)
        XCTAssertEqual(H264FrameRatePolicy(width: 3840, height: 2160).framesPerSecond, 60)
        XCTAssertEqual(H264FrameRatePolicy(width: 3072, height: 1728).framesPerSecond, 60)
    }

    func testMacroblockDimensionsRoundUp() {
        XCTAssertEqual(H264FrameRatePolicy(width: 4097, height: 2305).framesPerSecond, 54)
    }

    func testFractionalCadenceDoesNotCollapse60HzCaptureTo30FPS() {
        var policy = H264FrameRatePolicy(width: 4096, height: 2304)
        let accepted = (0..<600).filter { policy.shouldSubmit(at: Double($0) / 60) }
        XCTAssertEqual(accepted.count, 550)
    }

    func testDeferredLastFrameCanBeReplayedWithoutAnotherCapture() {
        var policy = H264FrameRatePolicy(width: 4096, height: 2304)
        XCTAssertTrue(policy.shouldSubmit(at: 0))
        XCTAssertFalse(policy.shouldSubmit(at: 1.0 / 60))
        // The existing drop replay timer supplies the latest frame after 30 ms.
        XCTAssertTrue(policy.shouldSubmit(at: 1.0 / 60 + 0.030))
        XCTAssertFalse(policy.shouldSubmit(at: 1.0 / 60 + 0.030))
    }

    func testLongIdleGapDoesNotAccumulateCatchUpSubmissions() {
        var policy = H264FrameRatePolicy(width: 4096, height: 2304)
        XCTAssertTrue(policy.shouldSubmit(at: 0))
        XCTAssertTrue(policy.shouldSubmit(at: 86400))
        XCTAssertFalse(policy.shouldSubmit(at: 86400))
        XCTAssertTrue(policy.shouldSubmit(at: 86400 + 1.0 / 55))
    }

    func testEarlyAdmissionConsumesOneDeadlineSlot() {
        var policy = H264FrameRatePolicy(width: 4096, height: 2304)
        XCTAssertTrue(policy.shouldSubmit(at: 0))
        let slightlyEarly = 1.0 / 55 - 0.0004
        XCTAssertTrue(policy.shouldSubmit(at: slightlyEarly))
        XCTAssertFalse(policy.shouldSubmit(at: slightlyEarly))
    }

    func testLateFrameNearFollowingSlotCannotBeSubmittedTwice() {
        var policy = H264FrameRatePolicy(width: 4096, height: 2304)
        XCTAssertTrue(policy.shouldSubmit(at: 0))
        XCTAssertTrue(policy.shouldSubmit(at: 0.0362))
        XCTAssertFalse(policy.shouldSubmit(at: 0.0362))
    }

    func testNewEncoderResetsDeadline() {
        var policy = H264FrameRatePolicy(width: 4096, height: 2304)
        XCTAssertTrue(policy.shouldSubmit(at: 10))
        XCTAssertFalse(policy.shouldSubmit(at: 10))
        policy = H264FrameRatePolicy(width: 4096, height: 2304)
        XCTAssertTrue(policy.shouldSubmit(at: 0))
    }

    func testInvalidTimestampDoesNotPoisonDeadline() {
        var policy = H264FrameRatePolicy(width: 4096, height: 2304)
        XCTAssertTrue(policy.shouldSubmit(at: .nan))
        XCTAssertTrue(policy.shouldSubmit(at: .infinity))
        XCTAssertTrue(policy.shouldSubmit(at: 0))
        XCTAssertFalse(policy.shouldSubmit(at: 0))
    }

    func testSafeRastersKeepExistingUnpacedBehavior() {
        var policy = H264FrameRatePolicy(width: 1920, height: 1080)
        XCTAssertTrue(policy.shouldSubmit(at: 0))
        XCTAssertTrue(policy.shouldSubmit(at: 0))
    }
}
