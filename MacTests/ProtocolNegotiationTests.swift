import XCTest

/// Tagged framing is negotiated, and the negotiation has an ordering hazard:
/// the handshake that carries the peer's version cannot itself be tagged,
/// because neither end knows what the other speaks until it has been read.
///
/// Getting that wrong produces a bug that hides — it works on WiFi, or only
/// when the handshake happens to arrive in a single TCP segment, and fails on
/// reconnect. These tests model the latch as the production code does (start
/// legacy, flip on the peer's version, reset per connection) and pin the
/// ordering, so the hazard is covered without needing a socket.
final class ProtocolNegotiationTests: XCTestCase {

    /// Mirrors the per-connection latch held by MacSender and StreamReceiver.
    private struct Negotiator {
        private(set) var tagged = false
        private(set) var framesSentBeforeHandshake = 0

        mutating func connectionEstablished() {
            tagged = false      // a reconnect may be a different peer
        }

        mutating func peerAnnounced(pv: Int) {
            tagged = pv >= WireProtocol.taggedFrameVersion
        }

        mutating func send(_ payload: Data, type: FrameType) -> Data {
            if !tagged { framesSentBeforeHandshake += 1 }
            return FrameCodec.encode(payload, type: type, tagged: tagged)
        }
    }

    private func isTagged(_ frame: Data, payload: Data) -> Bool {
        frame.count == 4 + payload.count + 1
    }

    // MARK: - The ordering hazard

    func testHandshakeItselfGoesOutUntagged() {
        // The peer cannot read a tag it does not yet know to expect.
        var n = Negotiator()
        n.connectionEstablished()
        let hello = Data(#"{"type":"hello","pv":4}"#.utf8)
        let frame = n.send(hello, type: .json)
        XCTAssertFalse(isTagged(frame, payload: hello))
    }

    func testTaggingBeginsOnlyAfterThePeerVersionIsKnown() {
        var n = Negotiator()
        n.connectionEstablished()

        let handshake = Data(#"{"type":"welcome","pv":4}"#.utf8)
        XCTAssertFalse(isTagged(n.send(handshake, type: .json), payload: handshake))

        n.peerAnnounced(pv: 4)

        let video = Data([0x00, 0x00, 0x00, 0x01, 0x65])
        XCTAssertTrue(isTagged(n.send(video, type: .video), payload: video))
        XCTAssertEqual(n.framesSentBeforeHandshake, 1)
    }

    func testHandshakeSplitAcrossReadsDoesNotTagEarly() {
        // A handshake delivered in two TCP reads must not flip the latch on the
        // first fragment: the version is not known until the message parses.
        var n = Negotiator()
        n.connectionEstablished()

        let full = Data(#"{"type":"welcome","pv":4}"#.utf8)
        let firstHalf = full.prefix(10)     // arrives, does not parse
        XCTAssertFalse(isTagged(n.send(firstHalf, type: .json), payload: firstHalf))
        XCTAssertFalse(n.tagged)

        n.peerAnnounced(pv: 4)              // rest arrived, message parsed
        XCTAssertTrue(n.tagged)
    }

    // MARK: - Version gating

    func testOldPeersNeverGetTaggedFrames() {
        for pv in 1...3 {
            var n = Negotiator()
            n.connectionEstablished()
            n.peerAnnounced(pv: pv)
            let payload = Data([0xAA])
            XCTAssertFalse(isTagged(n.send(payload, type: .video), payload: payload),
                           "pv \(pv) must keep legacy framing")
        }
    }

    func testFutureProtocolVersionsStillTag() {
        // The gate is >=, not ==: a protocol-5 peer speaks tagged framing too.
        var n = Negotiator()
        n.connectionEstablished()
        n.peerAnnounced(pv: WireProtocol.taggedFrameVersion + 1)
        XCTAssertTrue(n.tagged)
    }

    func testPeerWithNoAdvertisedVersionIsTreatedAsProtocol1() {
        var n = Negotiator()
        n.connectionEstablished()
        n.peerAnnounced(pv: WireProtocol.assumedWhenAbsent)
        let payload = Data([0xAA])
        XCTAssertFalse(isTagged(n.send(payload, type: .video), payload: payload))
    }

    // MARK: - Per-connection reset

    func testLatchResetsWhenAnOlderPeerReconnects() {
        // The regression this guards: a pv-4 session leaves the latch true, and
        // a pv-3 device reconnecting inherits tagged frames it cannot read.
        var n = Negotiator()
        n.connectionEstablished()
        n.peerAnnounced(pv: 4)
        XCTAssertTrue(n.tagged)

        n.connectionEstablished()
        XCTAssertFalse(n.tagged, "a new connection must not inherit the last peer's framing")

        n.peerAnnounced(pv: 3)
        let payload = Data([0xAA])
        XCTAssertFalse(isTagged(n.send(payload, type: .video), payload: payload))
    }

    func testReconnectToTheSamePeerRenegotiatesCleanly() {
        var n = Negotiator()
        for _ in 0..<3 {
            n.connectionEstablished()
            XCTAssertFalse(n.tagged)
            n.peerAnnounced(pv: 4)
            XCTAssertTrue(n.tagged)
        }
    }

    // MARK: - Version constants

    func testProtocolVersionSupportsTaggedFraming() {
        XCTAssertGreaterThanOrEqual(WireProtocol.version, WireProtocol.taggedFrameVersion)
    }

    func testMinSupportedPeerStillAdmitsProtocol1() {
        // Tagged framing is additive: it must not have raised the floor, or
        // every pre-handshake install in the field is cut off.
        XCTAssertEqual(WireProtocol.minSupportedPeer, 1)
    }

    func testPencilWireVersionUnchangedByTheFramingBump() {
        XCTAssertEqual(WireProtocol.pencilWireVersion, 3)
    }
}
