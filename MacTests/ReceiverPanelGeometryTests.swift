import XCTest

/// The iOS receiver's hello.panel, from window and screen sizes. Duo sizes
/// are the iPhone Duo simulator's (iOS 27.1): outer 466x678 pt, inner
/// 669x951 pt, both at 3x.
final class ReceiverPanelGeometryTests: XCTestCase {
    private func panel(window: CGSize, screen: CGSize, native: CGSize,
                       scale: CGFloat) throws -> ReceiverPanelGeometry {
        try XCTUnwrap(ReceiverPanelGeometry(window: window, screen: screen,
                                            nativePixels: native, nativeScale: scale))
    }

    private let duoOuter = CGSize(width: 466, height: 678)
    private let duoOuterNative = CGSize(width: 1398, height: 2034)
    private let duoInner = CGSize(width: 669, height: 951)
    private let duoInnerNative = CGSize(width: 2007, height: 2853)

    func testFoldAndUnfoldWithoutRotatingChangeThePanel() throws {
        let outer = try panel(window: duoOuter, screen: duoOuter, native: duoOuterNative, scale: 3)
        let inner = try panel(window: duoInner, screen: duoInner, native: duoInnerNative, scale: 3)
        let outerAgain = try panel(window: duoOuter, screen: duoOuter, native: duoOuterNative, scale: 3)

        XCTAssertEqual([outer.pixelsWide, outer.pixelsHigh], [1398, 2034])
        XCTAssertEqual([inner.pixelsWide, inner.pixelsHigh], [2007, 2853])
        XCTAssertEqual(outerAgain, outer)
    }

    func testRotationSwapsAxesAndKeepsScale() throws {
        let landscapeInner = CGSize(width: duoInner.height, height: duoInner.width)
        let portrait = try panel(window: duoInner, screen: duoInner, native: duoInnerNative, scale: 3)
        let landscape = try panel(window: landscapeInner, screen: landscapeInner,
                                  native: duoInnerNative, scale: 3)

        XCTAssertEqual(landscape.pixelsWide, portrait.pixelsHigh)
        XCTAssertEqual(landscape.pixelsHigh, portrait.pixelsWide)
        XCTAssertEqual(landscape.scale, 3)
    }

    func testSplitViewReportsTheHalfWindow() throws {
        let landscapeInner = CGSize(width: duoInner.height, height: duoInner.width)
        let half = try panel(window: CGSize(width: 469, height: 669), screen: landscapeInner,
                             native: duoInnerNative, scale: 3)

        XCTAssertEqual([half.pixelsWide, half.pixelsHigh], [1407, 2007])
    }

    func testIPadWindowsUseTheirOwnSize() throws {
        // iPad Pro 11-inch: 1194x834 pt at 2x, nativeBounds 1668x2388.
        let screen = CGSize(width: 1194, height: 834)
        let native = CGSize(width: 1668, height: 2388)
        let full = try panel(window: screen, screen: screen, native: native, scale: 2)
        let third = try panel(window: CGSize(width: 375, height: 834), screen: screen,
                              native: native, scale: 2)
        let stageManager = try panel(window: CGSize(width: 786.5, height: 512.5), screen: screen,
                                     native: native, scale: 2)

        XCTAssertEqual([full.pixelsWide, full.pixelsHigh], [2388, 1668])
        XCTAssertEqual([third.pixelsWide, third.pixelsHigh], [750, 1668])
        XCTAssertEqual([stageManager.pixelsWide, stageManager.pixelsHigh], [1573, 1025])
    }

    func testFullScreenDisplayZoomKeepsTheExactPanel() throws {
        // iPhone 8 Plus zoomed: 375x667 pt at nativeScale 2.88 is 1080x1921
        // by multiplication, but the panel is 1080x1920.
        for landscape in [false, true] {
            let screen = landscape ? CGSize(width: 667, height: 375) : CGSize(width: 375, height: 667)
            let zoomed = try panel(window: screen, screen: screen,
                                   native: CGSize(width: 1080, height: 1920), scale: 2.88)

            XCTAssertEqual([zoomed.pixelsWide, zoomed.pixelsHigh],
                           landscape ? [1920, 1080] : [1080, 1920])
            XCTAssertEqual(zoomed.scale, 2.88)
        }
    }

    func testUnusableLayoutsAreIgnored() {
        let screen = duoOuter
        for window in [CGSize.zero, CGSize(width: 466, height: 0),
                       CGSize(width: -1, height: 678),
                       CGSize(width: CGFloat.nan, height: 678),
                       CGSize(width: CGFloat.infinity, height: 678)] {
            XCTAssertNil(ReceiverPanelGeometry(window: window, screen: screen,
                                               nativePixels: duoOuterNative, nativeScale: 3),
                         "\(window)")
        }
        XCTAssertNil(ReceiverPanelGeometry(window: screen, screen: screen,
                                           nativePixels: duoOuterNative, nativeScale: 0))
    }
}
