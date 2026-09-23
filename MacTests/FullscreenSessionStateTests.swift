import XCTest

final class FullscreenSessionStateTests: XCTestCase {
    func testNewSessionWantsFullscreen() {
        let state = FullscreenSessionState()

        XCTAssertTrue(state.wantsFullscreen)
    }

    func testLeavingFullscreenIsKeptForTheSession() {
        var state = FullscreenSessionState()

        state.userLeftFullscreen()

        XCTAssertFalse(state.wantsFullscreen)
    }

    func testReenteringFullscreenIsKeptForTheSession() {
        var state = FullscreenSessionState()
        state.userLeftFullscreen()

        state.userEnteredFullscreen()

        XCTAssertTrue(state.wantsFullscreen)
    }

    func testNextSessionRearmsFullscreen() {
        var state = FullscreenSessionState()
        state.userLeftFullscreen()

        state.beginNextSession()

        XCTAssertTrue(state.wantsFullscreen)
    }
}
