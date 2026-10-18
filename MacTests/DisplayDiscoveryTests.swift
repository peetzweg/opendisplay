import XCTest

final class DisplayDiscoveryTests: XCTestCase {
    func testDistinguishesCoreGraphicsOfflineFromScreenCaptureKitMissing() {
        let offline = DisplayDiscoverySnapshot(
            coreGraphicsOnline: false, coreGraphicsActive: false,
            shareableContentDisplayCount: 2, shareableDisplaySize: nil)
        XCTAssertTrue(offline.diagnosis(expectedSize: nil).contains("not online in CoreGraphics"))

        let missingFromScreenCapture = DisplayDiscoverySnapshot(
            coreGraphicsOnline: true, coreGraphicsActive: true,
            shareableContentDisplayCount: 2, shareableDisplaySize: nil)
        XCTAssertTrue(missingFromScreenCapture.diagnosis(expectedSize: nil)
            .contains("online in CoreGraphics but missing from ScreenCaptureKit"))
    }

    func testReportsScreenCaptureKitSizeMismatch() {
        let snapshot = DisplayDiscoverySnapshot(
            coreGraphicsOnline: true, coreGraphicsActive: true,
            shareableContentDisplayCount: 3,
            shareableDisplaySize: DisplayDiscoverySize(width: 1280, height: 720))

        XCTAssertTrue(snapshot.diagnosis(expectedSize: DisplayDiscoverySize(width: 1366, height: 768))
            .contains("listed in ScreenCaptureKit at 1280x720, expected 1366x768"))
    }
}
