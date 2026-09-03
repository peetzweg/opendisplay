import XCTest
import CoreGraphics

final class ResolutionLogicTests: XCTestCase {
    private struct TestMode {
        let width: UInt
        let pixelWidth: UInt
    }

    private func buildModes(w: Int, h: Int) -> [TestMode] {
        resolutionSteps.map { s in
            TestMode(width: UInt((CGFloat(w) * s).rounded(.toNearestOrEven)),
                     pixelWidth: UInt((CGFloat(w * 2) * s).rounded(.toNearestOrEven)))
        }
    }

    private func shouldReassert(currentWidth: Int, currentPixelWidth: Int,
                                published: [TestMode], targetStep: Int = 0,
                                settled: Bool, missingTicks: Int) -> Bool {
        let publishedIndex = published.firstIndex {
            $0.width == UInt(currentWidth) && $0.width * 2 == UInt(currentPixelWidth)
        }
        if !settled {
            let targetIndex = published.indices.contains(targetStep) ? targetStep : 0
            return publishedIndex != targetIndex
        }
        if publishedIndex != nil { return false }
        return missingTicks >= 3
    }

    func testPublishesMultipleModesWithNativeFirst() {
        let modes = buildModes(w: 1179, h: 2556)
        XCTAssertGreaterThan(modes.count, 1)
        XCTAssertEqual(modes[0].width, 1179)
        XCTAssertEqual(modes[0].pixelWidth, 2358)
        XCTAssertEqual(modes.count, resolutionSteps.count)
    }

    func testUserPickedScaledModeIsNotRevertedWhenSettled() {
        let modes = buildModes(w: 1179, h: 2556)
        let scaled = modes[2]
        XCTAssertFalse(shouldReassert(currentWidth: Int(scaled.width), currentPixelWidth: Int(scaled.pixelWidth),
                                      published: modes, targetStep: 0, settled: true, missingTicks: 0))
    }

    func testNativeHiDPIModeStandsWhenSettled() {
        let modes = buildModes(w: 1179, h: 2556)
        XCTAssertFalse(shouldReassert(currentWidth: 1179, currentPixelWidth: 2358,
                                      published: modes, targetStep: 0, settled: true, missingTicks: 0))
    }

    func testStartupRaceReassertsSavedTargetMode() {
        let modes = buildModes(w: 1179, h: 2556)
        XCTAssertTrue(shouldReassert(currentWidth: 1179, currentPixelWidth: 2358,
                                     published: modes, targetStep: 2, settled: false, missingTicks: 0))
    }

    func testStartupAcceptsTargetModeImmediately() {
        let modes = buildModes(w: 1179, h: 2556)
        let scaled = modes[2]
        XCTAssertFalse(shouldReassert(currentWidth: Int(scaled.width), currentPixelWidth: Int(scaled.pixelWidth),
                                      published: modes, targetStep: 2, settled: false, missingTicks: 0))
    }

    func test1xRelapseBeforeSettleReasserts() {
        let modes = buildModes(w: 1179, h: 2556)
        XCTAssertTrue(shouldReassert(currentWidth: 1179, currentPixelWidth: 1179,
                                     published: modes, targetStep: 0, settled: false, missingTicks: 0))
    }

    func test1xRelapseDebouncesForLessThan3Ticks() {
        let modes = buildModes(w: 1179, h: 2556)
        XCTAssertFalse(shouldReassert(currentWidth: 1179, currentPixelWidth: 1179,
                                      published: modes, targetStep: 0, settled: true, missingTicks: 2))
    }

    func test1xRelapseRecoversAfter3Ticks() {
        let modes = buildModes(w: 1179, h: 2556)
        XCTAssertTrue(shouldReassert(currentWidth: 1179, currentPixelWidth: 1179,
                                     published: modes, targetStep: 0, settled: true, missingTicks: 3))
    }

    func testResolutionStorePersistsAndLoadsDeviceStep() {
        let deviceID = "test-device-uuid-1234"
        ResolutionStore.save(step: 2, device: deviceID)
        XCTAssertEqual(ResolutionStore.load(device: deviceID), 2)
    }
}
