import XCTest

final class FrameRateTests: XCTestCase {

    func testRawValuesAndCases() {
        XCTAssertEqual(FrameRate.allCases.count, 4)
        XCTAssertEqual(FrameRate.fps30.rawValue, 30)
        XCTAssertEqual(FrameRate.fps60.rawValue, 60)
        XCTAssertEqual(FrameRate.fps90.rawValue, 90)
        XCTAssertEqual(FrameRate.fps120.rawValue, 120)
    }

    func testLabelsContainProMotion() {
        XCTAssertTrue(FrameRate.fps120.label.contains("ProMotion"))
        XCTAssertTrue(FrameRate.fps60.label.contains("Default"))
        XCTAssertTrue(FrameRate.fps30.label.contains("Low Power"))
    }

    func testBitrateScaling() {
        let bestBase = StreamQuality.best.bitrate // 18_000_000
        let balancedBase = StreamQuality.balanced.bitrate // 10_000_000
        let fastBase = StreamQuality.fast.bitrate // 6_000_000

        // 60 FPS should preserve base bitrate
        XCTAssertEqual(FrameRate.fps60.bitrate(for: .best), bestBase)
        XCTAssertEqual(FrameRate.fps60.bitrate(for: .balanced), balancedBase)
        XCTAssertEqual(FrameRate.fps60.bitrate(for: .fast), fastBase)

        // 120 FPS should boost bitrate by 1.6x (28.8 Mbps for best)
        XCTAssertEqual(FrameRate.fps120.bitrate(for: .best), 28_800_000)
        XCTAssertEqual(FrameRate.fps120.bitrate(for: .balanced), 16_000_000)
        XCTAssertEqual(FrameRate.fps120.bitrate(for: .fast), 9_600_000)

        // 90 FPS should scale by 1.25x
        XCTAssertEqual(FrameRate.fps90.bitrate(for: .best), Int(Double(bestBase) * 1.25))

        // 30 FPS should scale down to 0.75x to conserve bandwidth
        XCTAssertEqual(FrameRate.fps30.bitrate(for: .best), Int(Double(bestBase) * 0.75))
    }

    func testInitFromRawValueFallback() {
        XCTAssertEqual(FrameRate(rawValue: 120), .fps120)
        XCTAssertEqual(FrameRate(rawValue: 60), .fps60)
        XCTAssertNil(FrameRate(rawValue: 144))
    }
}
