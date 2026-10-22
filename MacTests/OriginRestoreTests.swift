import CoreGraphics
import XCTest

final class OriginRestoreTests: XCTestCase {
    private let saved = CGPoint(x: -424, y: -1_152)
    private let macDefault = CGPoint(x: 1_512, y: 0)
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testRestoresSavedOriginOverMacOSDefault() {
        var restore = OriginRestore(target: saved)

        XCTAssertEqual(restore.tick(origin: macDefault, now: t0), .apply(saved))
        restore.settled(at: saved)
        XCTAssertEqual(restore.tick(origin: saved, now: t0 + 2), .none)
        XCTAssertEqual(restore.tick(origin: saved, now: t0 + 10), .none)
    }

    /// #390: after sleep, a mode change blocked the tick for 10 s. The first
    /// tick then ran past a window measured from creation, and macOS's
    /// default spot was saved as if the user had dragged the display there.
    func testStalledFirstTickStillRestoresInsteadOfReporting() {
        var restore = OriginRestore(target: saved)

        let firstTick = t0 + 10
        XCTAssertEqual(restore.tick(origin: macDefault, now: firstTick), .apply(saved))
        restore.settled(at: saved)
        XCTAssertEqual(restore.tick(origin: saved, now: firstTick + 7), .none)
    }

    func testWindowThatNeverLandedDoesNotPersistTheDefault() {
        var restore = OriginRestore(target: saved)

        // Every apply failed (no settled(at:)), then the window ran out.
        XCTAssertEqual(restore.tick(origin: macDefault, now: t0), .apply(saved))
        XCTAssertEqual(restore.tick(origin: macDefault, now: t0 + 7), .none)
        // A later move is still the user's.
        let dragged = CGPoint(x: -1_512, y: 32)
        XCTAssertEqual(restore.tick(origin: dragged, now: t0 + 9), .report(dragged))
    }

    func testDragAfterWindowIsReported() {
        var restore = OriginRestore(target: saved)
        XCTAssertEqual(restore.tick(origin: saved, now: t0), .none)

        let dragged = CGPoint(x: 1_512, y: 0)
        XCTAssertEqual(restore.tick(origin: dragged, now: t0 + 7), .report(dragged))
        XCTAssertEqual(restore.tick(origin: dragged, now: t0 + 9), .none)
    }

    func testMacOSRestoreInsideWindowIsOverridden() {
        var restore = OriginRestore(target: saved)
        XCTAssertEqual(restore.tick(origin: saved, now: t0), .none)
        // macOS applies its own stale record a few seconds after creation.
        XCTAssertEqual(restore.tick(origin: macDefault, now: t0 + 3), .apply(saved))
    }

    func testFirstContactReportsTheInitialSpot() {
        var restore = OriginRestore(target: nil)

        XCTAssertEqual(restore.tick(origin: macDefault, now: t0), .report(macDefault))
        XCTAssertEqual(restore.tick(origin: macDefault, now: t0 + 2), .none)
    }

    func testRearmAfterResizeRestartsWindowOnNextTick() {
        var restore = OriginRestore(target: saved)
        XCTAssertEqual(restore.tick(origin: saved, now: t0), .none)

        let resized = CGPoint(x: -198, y: -1_152)
        restore.rearm(at: resized)
        // Next tick is late, but the window starts there.
        XCTAssertEqual(restore.tick(origin: macDefault, now: t0 + 30), .apply(resized))
        restore.settled(at: resized)
        XCTAssertEqual(restore.tick(origin: resized, now: t0 + 40), .none)
    }
}
