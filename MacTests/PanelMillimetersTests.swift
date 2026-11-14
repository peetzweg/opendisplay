import XCTest

final class PanelMillimetersTests: XCTestCase {
    func testScreenSizeDescribesTheAnnouncedPixels() throws {
        // 27" 5K iMac.
        let mm = try XCTUnwrap(PanelMillimeters.of(pixelsWide: 5120, pixelsHigh: 2880,
                                                   nativeWide: 5120, nativeHigh: 2880,
                                                   screen: CGSize(width: 596.7, height: 335.6)))
        XCTAssertEqual(mm.wide, 596.7)
        XCTAssertEqual(mm.high, 335.6)
    }

    func testNotchStripShrinksTheHeight() throws {
        // 14" MacBook Pro, 3024x1964 native, 74 pixel menu-bar strip.
        let mm = try XCTUnwrap(PanelMillimeters.of(pixelsWide: 3024, pixelsHigh: 1890,
                                                   nativeWide: 3024, nativeHigh: 1964,
                                                   screen: CGSize(width: 302.4, height: 196.4)))
        XCTAssertEqual(mm.wide, 302.4)
        XCTAssertEqual(mm.high, 189.0)
    }

    func testRotatedScreenIsOrientedLikeThePixels() throws {
        let mm = try XCTUnwrap(PanelMillimeters.of(pixelsWide: 1440, pixelsHigh: 2560,
                                                   nativeWide: 1440, nativeHigh: 2560,
                                                   screen: CGSize(width: 597, height: 336)))
        XCTAssertEqual(mm.wide, 336)
        XCTAssertEqual(mm.high, 597)
    }

    func testUnknownSizeIsOmitted() {
        XCTAssertNil(PanelMillimeters.of(pixelsWide: 1920, pixelsHigh: 1080,
                                         nativeWide: 1920, nativeHigh: 1080, screen: .zero))
    }
}
