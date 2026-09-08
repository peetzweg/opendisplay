import XCTest

/// Framing is the one part of the wire both apps must agree on byte for byte,
/// and protocol 4 changed it. These are pure-logic tests: no sockets, no
/// display, no capture.
final class FrameCodecTests: XCTestCase {

    // MARK: - Round trips

    func testTaggedRoundTripPreservesTypeAndPayload() {
        let payloads: [(FrameType, Data)] = [
            (.video, Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88])),
            (.json, Data(#"{"type":"pong"}"#.utf8)),
            (.audio, Data([0x00, 0x01, 0x01, 0xE0, 0x02, 0x00, 0xDE, 0xAD])),
        ]
        for (type, payload) in payloads {
            let frame = FrameCodec.encode(payload, type: type, tagged: true)
            let decoded = FrameCodec.decode(body: frame.dropFirst(4), tagged: true)
            XCTAssertEqual(decoded?.type, type)
            XCTAssertEqual(decoded?.payload, payload)
        }
    }

    func testLengthCoversTypeByte() {
        // The deframing loop reads the length then takes exactly that many
        // bytes. If the tag were excluded from the count, every frame would be
        // one byte short and the stream would desynchronise permanently.
        let payload = Data([0xAA, 0xBB, 0xCC])
        let frame = FrameCodec.encode(payload, type: .video, tagged: true)
        let declared = frame.prefix(4).withUnsafeBytes {
            Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        XCTAssertEqual(declared, payload.count + 1)
        XCTAssertEqual(frame.count, 4 + payload.count + 1)
    }

    // MARK: - Legacy compatibility

    func testUntaggedFramingIsByteIdenticalToPreProtocol4() {
        // A protocol-4 build must produce the exact bytes an older receiver
        // expects, or every install in the field breaks on update.
        let payload = Data(#"{"type":"hello"}"#.utf8)
        let frame = FrameCodec.encode(payload, type: .json, tagged: false)

        var expected = Data()
        var header = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &header) { expected.append(contentsOf: $0) }
        expected.append(payload)

        XCTAssertEqual(frame, expected)
    }

    func testLegacyDecodeStillInfersKindFromBytes() {
        let json = Data(#"{"type":"pong","t":123}"#.utf8)
        XCTAssertEqual(FrameCodec.decode(body: json, tagged: false)?.type, .json)

        let annexB = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42])
        XCTAssertEqual(FrameCodec.decode(body: annexB, tagged: false)?.type, .video)
    }

    // MARK: - The heuristic's blind spot

    func testTaggingSurvivesPayloadThatFoolsTheLegacyHeuristic() {
        // The pre-protocol-4 sniffing rule reads "starts with { and has no NUL"
        // as JSON. Audio can satisfy both by coincidence — this payload does —
        // and would have been handed to the JSON parser. The tag is what makes
        // it unambiguous, so assert both halves: the heuristic is still fooled,
        // and tagging is not.
        let deceptive = Data([UInt8(ascii: "{"), 0x11, 0x22, 0x33])
        XCTAssertTrue(FrameCodec.looksLikeJSON(deceptive),
                      "payload no longer exercises the blind spot this test exists for")

        let frame = FrameCodec.encode(deceptive, type: .audio, tagged: true)
        let decoded = FrameCodec.decode(body: frame.dropFirst(4), tagged: true)
        XCTAssertEqual(decoded?.type, .audio)
        XCTAssertEqual(decoded?.payload, deceptive)
    }

    func testVideoFrameWithTelemetryPrefixIsNotMistakenForJSON() {
        // Video frames really do begin with '{'; the NUL in the start code is
        // what saved the legacy path. Documented here because it is the reason
        // the heuristic cannot simply be extended to a third kind.
        var videoWithPrefix = Data(#"{"c":12.5}"#.utf8)
        videoWithPrefix.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x65])
        XCTAssertFalse(FrameCodec.looksLikeJSON(videoWithPrefix))
    }

    // MARK: - Forward compatibility and malformed input

    func testUnknownTypeDecodesAsNilRatherThanFailing() {
        // An older build meeting a newer frame type must skip it, not treat the
        // stream as corrupt — this is what keeps new types additive.
        var frame = Data([0x00, 0x00, 0x00, 0x03])
        frame.append(contentsOf: [0x7F, 0xAA, 0xBB])
        let decoded = FrameCodec.decode(body: frame.dropFirst(4), tagged: true)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.type)
        XCTAssertEqual(decoded?.payload, Data([0xAA, 0xBB]))
    }

    func testEmptyTaggedBodyIsRejected() {
        XCTAssertNil(FrameCodec.decode(body: Data(), tagged: true))
    }

    func testEmptyUntaggedBodyIsNotRejected() {
        // Legacy framing has no type byte to be missing, so an empty body is
        // merely an empty video payload, not malformed.
        XCTAssertNotNil(FrameCodec.decode(body: Data(), tagged: false))
    }

    func testEmptyPayloadTagsAndDecodesCleanly() {
        let frame = FrameCodec.encode(Data(), type: .audio, tagged: true)
        XCTAssertEqual(frame.count, 5)
        let decoded = FrameCodec.decode(body: frame.dropFirst(4), tagged: true)
        XCTAssertEqual(decoded?.type, .audio)
        XCTAssertTrue(decoded?.payload.isEmpty ?? false)
    }

    // MARK: - Deframing

    /// The production drain loop, reproduced faithfully enough to test the
    /// bounds arithmetic that the type byte changed. Slicing mirrors
    /// StreamReceiver.drainFrames, including its non-zero-based indices.
    private func drain(_ buffer: Data, tagged: Bool) -> [FrameCodec.Frame] {
        var frames: [FrameCodec.Frame] = []
        var cursor = buffer.startIndex
        while buffer.distance(from: cursor, to: buffer.endIndex) >= 4 {
            let len = buffer[cursor..<buffer.index(cursor, offsetBy: 4)]
                .withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard buffer.distance(from: cursor, to: buffer.endIndex) >= 4 + len else { break }
            let start = buffer.index(cursor, offsetBy: 4)
            let end = buffer.index(start, offsetBy: len)
            if let frame = FrameCodec.decode(body: Data(buffer[start..<end]), tagged: tagged) {
                frames.append(frame)
            }
            cursor = end
        }
        return frames
    }

    func testBackToBackTaggedFramesDrainInOrder() {
        var stream = Data()
        stream.append(FrameCodec.encode(Data([0x01]), type: .video, tagged: true))
        stream.append(FrameCodec.encode(Data(#"{"a":1}"#.utf8), type: .json, tagged: true))
        stream.append(FrameCodec.encode(Data([0x02, 0x03]), type: .audio, tagged: true))

        let frames = drain(stream, tagged: true)
        XCTAssertEqual(frames.map(\.type), [.video, .json, .audio])
        XCTAssertEqual(frames[2].payload, Data([0x02, 0x03]))
    }

    func testPartialFrameIsLeftForTheNextRead() {
        // TCP splits wherever it likes; a frame arriving in pieces must wait
        // rather than being parsed from a short buffer.
        let whole = FrameCodec.encode(Data([0xAA, 0xBB, 0xCC]), type: .video, tagged: true)
        XCTAssertTrue(drain(whole.dropLast(2), tagged: true).isEmpty)
        XCTAssertEqual(drain(whole, tagged: true).count, 1)
    }
}
