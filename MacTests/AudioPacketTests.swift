import XCTest

/// The audio packet header is pure byte layout, so it is fully testable
/// without CoreAudio, a socket, or a device.
final class AudioPacketTests: XCTestCase {

    private func sample(payload: Data = Data([0xDE, 0xAD, 0xBE, 0xEF])) -> AudioPacket {
        AudioPacket(codec: .aacLC, hasConfig: false, sampleRate: 48_000,
                    channels: 2, ptsMs: 1234.5, payload: payload)
    }

    // MARK: - Round trips

    func testRoundTripPreservesEveryField() {
        let original = sample()
        let decoded = AudioPacket.decode(original.encoded())
        XCTAssertEqual(decoded, original)
    }

    func testConfigFlagRoundTrips() {
        var packet = sample()
        packet.hasConfig = true
        XCTAssertEqual(AudioPacket.decode(packet.encoded())?.hasConfig, true)

        packet.hasConfig = false
        XCTAssertEqual(AudioPacket.decode(packet.encoded())?.hasConfig, false)
    }

    func testFractionalSampleRateSurvives() {
        // 44.1kHz is why the field is tenths of a kHz rather than whole kHz —
        // a whole-kHz field would round it to 44000 and the decoder would
        // drift against the sender.
        var packet = sample()
        packet.sampleRate = 44_100
        XCTAssertEqual(AudioPacket.decode(packet.encoded())?.sampleRate, 44_100)
    }

    func testCommonSampleRatesRoundTrip() {
        for rate in [8_000, 16_000, 22_050, 32_000, 44_100, 48_000, 96_000, 192_000] {
            var packet = sample()
            packet.sampleRate = rate
            XCTAssertEqual(AudioPacket.decode(packet.encoded())?.sampleRate, rate,
                           "sample rate \(rate) did not survive the wire")
        }
    }

    func testMonoAndStereoRoundTrip() {
        for channels in [1, 2] {
            var packet = sample()
            packet.channels = channels
            XCTAssertEqual(AudioPacket.decode(packet.encoded())?.channels, channels)
        }
    }

    // MARK: - Timestamps

    func testTimestampSurvivesFullDoublePrecision() {
        // ptsMs carries a wall-clock millisecond value that the receiver
        // subtracts from its own clock; losing precision here shows up as
        // audio/video misalignment, so it travels as a full double.
        var packet = sample()
        packet.ptsMs = 1_763_925_123_456.789
        let decoded = AudioPacket.decode(packet.encoded())
        XCTAssertEqual(decoded?.ptsMs, 1_763_925_123_456.789)
    }

    func testTimestampIsBigEndianOnTheWire() {
        var packet = sample()
        packet.ptsMs = 1.0     // 0x3FF0000000000000
        let bytes = Array(packet.encoded())
        XCTAssertEqual(Array(bytes[6..<14]), [0x3F, 0xF0, 0, 0, 0, 0, 0, 0])
    }

    func testSampleRateIsBigEndianHzOnTheWire() {
        // Plain Hz, not a scaled unit: 48000 = 0x0000BB80. Asserted on the
        // bytes because this is a cross-implementation contract, and a rate
        // that round-trips through our own code could still be encoded in a
        // unit another implementation would not expect.
        let bytes = Array(sample().encoded())
        XCTAssertEqual(Array(bytes[2..<6]), [0x00, 0x00, 0xBB, 0x80])
    }

    func testZeroTimestampRoundTrips() {
        var packet = sample()
        packet.ptsMs = 0
        XCTAssertEqual(AudioPacket.decode(packet.encoded())?.ptsMs, 0)
    }

    // MARK: - Layout

    func testHeaderIsExactlyFifteenBytes() {
        // Pinned to a literal, not just to headerSize: the constant and the
        // bytes encoded() actually writes are two different things, and the
        // bug this caught was exactly them disagreeing.
        let encoded = sample(payload: Data()).encoded()
        XCTAssertEqual(encoded.count, AudioPacket.headerSize)
        XCTAssertEqual(encoded.count, 15)
    }

    func testPayloadFollowsTheHeaderUntouched() {
        let payload = Data((0..<64).map { UInt8($0) })
        let encoded = sample(payload: payload).encoded()
        XCTAssertEqual(encoded.count, AudioPacket.headerSize + payload.count)
        XCTAssertEqual(encoded.suffix(from: AudioPacket.headerSize), payload)
    }

    func testChannelCountSitsAfterTheTimestamp() {
        XCTAssertEqual(Array(sample().encoded())[14], 2)
    }

    // MARK: - Malformed input

    func testTruncatedPacketsAreRejectedNotCrashed() {
        // These arrive from the network ~50 times a second; a malformed one
        // must be droppable, never fatal.
        let encoded = sample().encoded()
        for length in 0..<AudioPacket.headerSize {
            XCTAssertNil(AudioPacket.decode(encoded.prefix(length)),
                         "a \(length)-byte packet must not decode")
        }
    }

    func testUnknownCodecIsRejected() {
        var bytes = Array(sample().encoded())
        bytes[0] = 0x7F
        XCTAssertNil(AudioPacket.decode(Data(bytes)))
    }

    func testZeroSampleRateOrChannelsIsRejected() {
        var zeroRate = Array(sample().encoded())
        zeroRate[2] = 0; zeroRate[3] = 0; zeroRate[4] = 0; zeroRate[5] = 0
        XCTAssertNil(AudioPacket.decode(Data(zeroRate)))

        var zeroChannels = Array(sample().encoded())
        zeroChannels[14] = 0
        XCTAssertNil(AudioPacket.decode(Data(zeroChannels)))
    }

    func testEmptyPayloadIsValid() {
        // A header with no audio is well-formed — a config-only packet uses it.
        let decoded = AudioPacket.decode(sample(payload: Data()).encoded())
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded?.payload.isEmpty ?? false)
    }

    // MARK: - Slicing

    func testDecodingWorksOnANonZeroBasedSlice() {
        // Payloads reach this parser as slices of the receive buffer, whose
        // indices do not start at zero. Indexing from 0 instead of startIndex
        // would read the wrong bytes — or trap.
        let packet = sample()
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        buffer.append(packet.encoded())
        let slice = buffer.suffix(from: 8)

        XCTAssertNotEqual(slice.startIndex, 0, "slice no longer exercises non-zero indexing")
        XCTAssertEqual(AudioPacket.decode(slice), packet)
    }

    // MARK: - Framing integration

    func testAudioPacketSurvivesTaggedFraming() {
        // End to end at the wire level: packet → tagged frame → deframe →
        // packet, which is the whole phase-2 send path minus the codec.
        let packet = sample()
        let frame = FrameCodec.encode(packet.encoded(), type: .audio, tagged: true)
        let decodedFrame = FrameCodec.decode(body: frame.dropFirst(4), tagged: true)
        XCTAssertEqual(decodedFrame?.type, .audio)
        XCTAssertEqual(decodedFrame.flatMap { AudioPacket.decode($0.payload) }, packet)
    }
}

/// The AAC-LC AudioSpecificConfig the receiver reconstructs instead of
/// receiving. Two bytes of bit-packing, and a wrong one makes the decoder
/// reject every frame while still reporting a healthy stream.
final class AACCookieTests: XCTestCase {

    func test48kHzStereoMatchesTheSpec() {
        // objectType 2, freqIndex 3 (48000), channels 2:
        // 00010 0011 0010 000 -> 0x11 0x90
        XCTAssertEqual(AudioPacket.aacLCCookie(sampleRate: 48_000, channels: 2),
                       Data([0x11, 0x90]))
    }

    func test44_1kHzStereoMatchesTheSpec() {
        // freqIndex 4 (44100): 00010 0100 0010 000 -> 0x12 0x10
        XCTAssertEqual(AudioPacket.aacLCCookie(sampleRate: 44_100, channels: 2),
                       Data([0x12, 0x10]))
    }

    func testMonoDiffersFromStereo() {
        XCTAssertNotEqual(AudioPacket.aacLCCookie(sampleRate: 48_000, channels: 1),
                          AudioPacket.aacLCCookie(sampleRate: 48_000, channels: 2))
    }

    func testEveryRateTheEncoderCanProduceHasACookie() {
        for rate in [8_000, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000, 88_200, 96_000] {
            XCTAssertNotNil(AudioPacket.aacLCCookie(sampleRate: rate, channels: 2),
                            "no cookie for \(rate)Hz — decoder would reject every frame")
        }
    }

    func testUnsupportedInputIsRejectedRatherThanGuessed() {
        XCTAssertNil(AudioPacket.aacLCCookie(sampleRate: 12_345, channels: 2))
        XCTAssertNil(AudioPacket.aacLCCookie(sampleRate: 48_000, channels: 0))
    }
}
