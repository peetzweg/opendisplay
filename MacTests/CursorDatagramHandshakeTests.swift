import XCTest

final class CursorDatagramHandshakeTests: XCTestCase {
    func testUDPHandshakeSurvivesTCPWinningFirstPacket() {
        var handshake = CursorDatagramHandshake()
        let first = handshake.receive(sequence: 8, lastApplied: 10)
        XCTAssertTrue(first.acknowledge)
        XCTAssertFalse(first.apply)
        let next = handshake.receive(sequence: 11, lastApplied: 10)
        XCTAssertFalse(next.acknowledge)
        XCTAssertTrue(next.apply)
        handshake.resetFlow()
        let reordered = handshake.receive(sequence: 9, lastApplied: 11)
        XCTAssertTrue(reordered.acknowledge)
        XCTAssertFalse(reordered.apply)
    }

}
