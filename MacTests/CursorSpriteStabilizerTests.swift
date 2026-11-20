import XCTest

final class CursorSpriteStabilizerTests: XCTestCase {
    func testInitialCursorAndRealShapeChange() {
        var policy = CursorSpriteStabilizer()
        XCTAssertTrue(policy.shouldPublish(1, at: 0))
        XCTAssertFalse(policy.shouldPublish(2, at: 0.03))
        XCTAssertFalse(policy.shouldPublish(2, at: 0.06))
        XCTAssertTrue(policy.shouldPublish(2, at: 0.13))
        XCTAssertFalse(policy.shouldPublish(2, at: 0.16))
    }
    func testAlternatingArrowAndIBeamDoesNotFlicker() {
        var policy = CursorSpriteStabilizer()
        XCTAssertTrue(policy.shouldPublish(2, at: 0))
        for index in 1...60 {
            XCTAssertFalse(policy.shouldPublish(index % 2 == 0 ? 2 : 1, at: Double(index) / 30))
        }
    }
    func testTransientShapeDoesNotPoisonLaterRealChange() {
        var policy = CursorSpriteStabilizer()
        XCTAssertTrue(policy.shouldPublish(1, at: 0))
        XCTAssertFalse(policy.shouldPublish(2, at: 0.01))
        XCTAssertFalse(policy.shouldPublish(1, at: 0.07))
        XCTAssertFalse(policy.shouldPublish(2, at: 0.1))
        XCTAssertFalse(policy.shouldPublish(2, at: 0.17))
        XCTAssertTrue(policy.shouldPublish(2, at: 0.2))
        XCTAssertFalse(policy.shouldPublish(3, at: .nan))
    }
    func testReconnectImmediatelyResendsUnchangedSprite() {
        var policy = CursorSpriteStabilizer()
        XCTAssertTrue(policy.shouldPublish(1, at: 0))
        XCTAssertFalse(policy.shouldPublish(1, at: 1))
        XCTAssertTrue(policy.shouldPublish(1, at: 2, force: true))
        XCTAssertFalse(policy.shouldPublish(1, at: 2.01))
    }

    func testReconnectDiscardsPendingTransition() {
        var policy = CursorSpriteStabilizer()
        XCTAssertTrue(policy.shouldPublish(1, at: 0))
        XCTAssertFalse(policy.shouldPublish(2, at: 0.01))
        XCTAssertTrue(policy.shouldPublish(3, at: 0.02, force: true))
        XCTAssertFalse(policy.shouldPublish(2, at: 1))
        XCTAssertFalse(policy.shouldPublish(2, at: 1.05))
        XCTAssertTrue(policy.shouldPublish(2, at: 1.1))
    }
}
