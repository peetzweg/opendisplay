import XCTest

/// How a failed USB open or control request maps to an answer (#462).
final class AOAProtocolAnswerTests: XCTestCase {
    /// IOKit errors reach Swift as NSError codes, sign-extended or not.
    private func answer(_ code: UInt32) -> [AOA.ProtocolAnswer] {
        [Int(Int32(bitPattern: code)), Int(code)].map {
            AOA.ProtocolAnswer(failure: NSError(domain: NSOSStatusErrorDomain, code: $0))
        }
    }

    /// A running adb server opens the device for itself.
    func testExclusiveAccessIsBusy() {
        XCTAssertEqual(answer(0xE000_02C5), [.busy, .busy])
    }

    func testStallIsRefused() {
        XCTAssertEqual(answer(0xE000_5000), [.refused, .refused])
    }

    /// Timeouts and anything else stay silent, which is retried briefly.
    func testOtherFailuresAreSilent() {
        XCTAssertEqual(answer(0xE000_02D6), [.silent, .silent])   // kIOReturnTimeout
        XCTAssertEqual(answer(0xE000_02C0), [.silent, .silent])   // kIOReturnNoDevice
    }

    func testBusyTellsHowToFreeTheDevice() {
        XCTAssertTrue(AOA.Failure.busy.localizedDescription.contains("adb kill-server"))
    }
}
