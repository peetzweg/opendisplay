import XCTest
import Network

/// Unit tests for Google Cast wire framing, mDNS parsing, AES-128-CTR encryption,
/// RTP/RTCP packetization, IPv4 sanitization, and sender lifecycle.
final class CastTests: XCTestCase {

    // MARK: - CastDevice & IPv4 Sanitization

    func testCastDeviceDisplayLabel() {
        let tvDevice = CastDevice(
            id: "cast-uuid-1",
            name: "Living Room TV",
            model: "Sony BRAVIA",
            endpoint: .hostPort(host: "192.168.1.100", port: 8009),
            host: "192.168.1.100",
            port: 8009,
            supportsVideo: true
        )
        XCTAssertEqual(tvDevice.displayLabel, "Living Room TV (Sony BRAVIA)")
        XCTAssertEqual(tvDevice.port, 8009)
        XCTAssertTrue(tvDevice.supportsVideo)

        let chromecastDevice = CastDevice(
            id: "cast-uuid-2",
            name: "Bedroom TV",
            model: "Chromecast",
            endpoint: .hostPort(host: "192.168.1.101", port: 8009),
            host: "192.168.1.101",
            port: 8009,
            supportsVideo: true
        )
        XCTAssertEqual(chromecastDevice.displayLabel, "Bedroom TV")
    }

    func testCastDeviceEqualityAndHashing() {
        let dev1 = CastDevice(
            id: "same-id",
            name: "TV A",
            model: "Model A",
            endpoint: .hostPort(host: "10.0.0.1", port: 8009),
            host: "10.0.0.1",
            port: 8009,
            supportsVideo: true
        )
        let dev2 = CastDevice(
            id: "same-id",
            name: "TV B",
            model: "Model B",
            endpoint: .hostPort(host: "10.0.0.2", port: 8009),
            host: "10.0.0.2",
            port: 8009,
            supportsVideo: true
        )
        let dev3 = CastDevice(
            id: "different-id",
            name: "TV A",
            model: "Model A",
            endpoint: .hostPort(host: "10.0.0.1", port: 8009),
            host: "10.0.0.1",
            port: 8009,
            supportsVideo: true
        )

        XCTAssertEqual(dev1, dev2)
        XCTAssertNotEqual(dev1, dev3)
        XCTAssertEqual(dev1.hashValue, dev2.hashValue)
    }

    func testSanitizeIPv4StripsInterfaceScopeAndRejectsNonLANAddresses() {
        XCTAssertEqual(CastDiscovery.sanitizeIPv4("10.0.0.131"), "10.0.0.131")
        XCTAssertEqual(CastDiscovery.sanitizeIPv4("10.0.0.81%en1"), "10.0.0.81")
        XCTAssertEqual(CastDiscovery.sanitizeIPv4("  192.168.1.42%en0 \n"), "192.168.1.42")

        XCTAssertNil(CastDiscovery.sanitizeIPv4("Google-TV-Streamer._googlecast._tcp.local."))
        XCTAssertNil(CastDiscovery.sanitizeIPv4("cast-device.local"))
        XCTAssertNil(CastDiscovery.sanitizeIPv4("127.0.0.1"))
        XCTAssertNil(CastDiscovery.sanitizeIPv4("0.0.0.0"))
        XCTAssertNil(CastDiscovery.sanitizeIPv4("224.0.0.251"))
        XCTAssertNil(CastDiscovery.sanitizeIPv4("255.255.255.255"))
        XCTAssertNil(CastDiscovery.sanitizeIPv4(""))
    }

    // MARK: - Unicast mDNS DNS Response Parser

    func testParseDNSResponseExtractsTXTAndSRVRecords() {
        var packet = Data([
            0x00, 0x00, 0x84, 0x00,   // ID=0, Flags=Response+Authoritative
            0x00, 0x01,               // QDCOUNT = 1
            0x00, 0x01,               // ANCOUNT = 1
            0x00, 0x00,               // NSCOUNT = 0
            0x00, 0x01                // ARCOUNT = 1
        ])
        // Question: _googlecast._tcp.local (offset 12)
        packet.append(contentsOf: [
            0x0b, 0x5f, 0x67, 0x6f, 0x6f, 0x67, 0x6c, 0x65, 0x63, 0x61, 0x73, 0x74,
            0x04, 0x5f, 0x74, 0x63, 0x70,
            0x05, 0x6c, 0x6f, 0x63, 0x61, 0x6c, 0x00,
            0x00, 0x0c, 0x00, 0x01
        ])

        // Answer 1: TXT record using compressed name pointer 0xC0 0x0C
        let txtEntries = [
            "id=streamer-uuid-123",
            "fn=Google TV Streamer",
            "md=Google TV Streamer",
            "ca=464901"
        ]
        var txtRdata = Data()
        for entry in txtEntries {
            let utf8 = Data(entry.utf8)
            txtRdata.append(UInt8(utf8.count))
            txtRdata.append(utf8)
        }
        packet.append(contentsOf: [0xC0, 0x0C])
        packet.append(contentsOf: [0x00, 0x10])
        packet.append(contentsOf: [0x80, 0x01])
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x78])
        packet.append(UInt8((txtRdata.count >> 8) & 0xFF))
        packet.append(UInt8(txtRdata.count & 0xFF))
        packet.append(txtRdata)

        // Additional 1: SRV record on custom port 8019
        let srvTarget = Data([0x04, 0x68, 0x6f, 0x73, 0x74, 0x00])   // "host."
        let srvLen = 6 + srvTarget.count
        packet.append(contentsOf: [0xC0, 0x0C])
        packet.append(contentsOf: [0x00, 0x21])
        packet.append(contentsOf: [0x80, 0x01])
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x78])
        packet.append(UInt8((srvLen >> 8) & 0xFF))
        packet.append(UInt8(srvLen & 0xFF))
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        packet.append(contentsOf: [0x1F, 0x53])                      // 8019
        packet.append(srvTarget)

        // Wrap in a non-zero-startIndex slice to verify slice-safe indexing.
        var padded = Data([0xAA, 0xBB, 0xCC])
        padded.append(packet)
        let slice = padded.dropFirst(3)

        let parsed = CastDiscovery.parseDNSResponse(slice)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.id, "streamer-uuid-123")
        XCTAssertEqual(parsed?.name, "Google TV Streamer")
        XCTAssertEqual(parsed?.model, "Google TV Streamer")
        XCTAssertEqual(parsed?.port, 8019)
        XCTAssertEqual(parsed?.ca, 464901)
    }

    func testParseDNSResponseRejectsTruncatedAndMalformedPackets() {
        XCTAssertNil(CastDiscovery.parseDNSResponse(Data()))
        XCTAssertNil(CastDiscovery.parseDNSResponse(Data([0, 1, 2, 3])))

        let truncatedPointer = Data([
            0x00, 0x00, 0x84, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xC0
        ])
        XCTAssertNil(CastDiscovery.parseDNSResponse(truncatedPointer))

        let truncatedQuestion = Data([
            0x00, 0x00, 0x84, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x0C
        ])
        XCTAssertNil(CastDiscovery.parseDNSResponse(truncatedQuestion))
    }

    // MARK: - CastWire Framing & Protobuf

    func testCastWireCoalescedUnalignedFramesAndPartialChunks() throws {
        // Non-4-byte-aligned first frame exercises sliced `Data` startIndex alignment.
        let msg1 = CastWire.buildMessage(
            sourceId: "sender-10",
            destId: "receiver-0",
            ns: "urn:x-cast:com.google.cast.tp.heartbeat",
            jsonPayload: "{\"type\":\"PING\"}"
        )
        let msg2 = CastWire.buildMessage(
            sourceId: "receiver-0",
            destId: "sender-10",
            ns: "urn:x-cast:com.google.cast.receiver",
            jsonPayload: "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1}"
        )
        XCTAssertNotEqual(msg1.count % 4, 0)

        var rxBuffer = Data()
        rxBuffer.append(msg1)
        rxBuffer.append(msg2.prefix(7))

        let firstPass = try CastWire.extractFrames(from: &rxBuffer)
        XCTAssertEqual(firstPass.count, 1)
        XCTAssertEqual(rxBuffer.count, 7)

        let parsed1 = CastWire.parseProtobuf(data: firstPass[0])
        XCTAssertEqual(parsed1?.sourceId, "sender-10")
        XCTAssertEqual(parsed1?.destId, "receiver-0")
        XCTAssertEqual(parsed1?.namespaceStr, "urn:x-cast:com.google.cast.tp.heartbeat")
        XCTAssertEqual(parsed1?.payloadUtf8, "{\"type\":\"PING\"}")

        rxBuffer.append(msg2.dropFirst(7))
        let secondPass = try CastWire.extractFrames(from: &rxBuffer)
        XCTAssertEqual(secondPass.count, 1)
        XCTAssertTrue(rxBuffer.isEmpty)

        let parsed2 = CastWire.parseProtobuf(data: secondPass[0])
        XCTAssertEqual(parsed2?.sourceId, "receiver-0")
        XCTAssertEqual(parsed2?.destId, "sender-10")
        XCTAssertEqual(parsed2?.payloadUtf8, "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1}")
    }

    func testCastWireRejectsOversizedFrameAndOverlongVarint() {
        var corrupt = Data([0x01, 0x00, 0x00, 0x00, 0x08, 0x00])   // 16 MiB > 1 MiB cap
        XCTAssertThrowsError(try CastWire.extractFrames(from: &corrupt)) { error in
            XCTAssertEqual(error as? CastWireError, .oversizedFrame(16_777_216))
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
        XCTAssertTrue(corrupt.isEmpty)

        // 12 continuation bytes (> 64-bit varint) must return nil instead of trapping on `<< shift`.
        let badVarint = Data(repeating: 0x81, count: 12)
        XCTAssertNil(CastWire.parseProtobuf(data: badVarint))
    }

    // MARK: - CastCrypto

    func testCastCryptoRoundtripAndFailsClosedOnInvalidKeys() {
        let key1 = CastCrypto.randomBytes(count: 16)
        let key2 = CastCrypto.randomBytes(count: 16)
        let ivMask = CastCrypto.randomBytes(count: 16)

        XCTAssertEqual(key1.count, 16)
        XCTAssertNotEqual(key1, key2)

        let plainData = Data("Hello Cast WebRTC Encrypted Stream".utf8)
        let frameId: UInt32 = 42

        guard let encrypted = CastCrypto.encryptPayload(
            frameId: frameId, inData: plainData, aesKey: key1, aesIvMask: ivMask
        ) else {
            return XCTFail("Expected encryption to succeed with 16-byte key and IV mask")
        }
        XCTAssertEqual(encrypted.count, plainData.count)
        XCTAssertNotEqual(encrypted, plainData)

        let decrypted = CastCrypto.encryptPayload(frameId: frameId, inData: encrypted, aesKey: key1, aesIvMask: ivMask)
        XCTAssertEqual(decrypted, plainData)

        let wrongFrame = CastCrypto.encryptPayload(frameId: frameId + 1, inData: encrypted, aesKey: key1, aesIvMask: ivMask)
        XCTAssertNotEqual(wrongFrame, plainData)

        XCTAssertNil(CastCrypto.encryptPayload(frameId: frameId, inData: plainData, aesKey: [], aesIvMask: ivMask))
        XCTAssertNil(CastCrypto.encryptPayload(frameId: frameId, inData: plainData, aesKey: key1, aesIvMask: [1, 2, 3]))
    }

    // MARK: - CastRTP Packetization, Buffer & RTCP Feedback

    func testCastRTPPacketBufferPopAndCompaction() {
        var buffer = CastRTP.PacketBuffer()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.count, 0)

        let packets = (0..<300).map { i in Data([UInt8(i & 0xFF)]) }
        buffer.append(contentsOf: packets)
        XCTAssertEqual(buffer.count, 300)

        var popped: [UInt8] = []
        while !buffer.isEmpty {
            let burst = buffer.popBurst(maxCount: 64)
            XCTAssertLessThanOrEqual(burst.count, 64)
            popped.append(contentsOf: burst.compactMap(\.first))
        }
        XCTAssertEqual(popped.count, 300)
        XCTAssertEqual(popped, packets.compactMap(\.first))
        XCTAssertEqual(buffer.count, 0)
    }

    func testCastRTPPacketizeFrameHeadersAndWraparound() {
        let payload = Data((0..<2700).map { UInt8($0 & 0xFF) })
        var seq: UInt16 = 65535   // exercise UInt16 wraparound (65535, 0, 1)
        let packets = CastRTP.packetizeFrame(
            encryptedPayload: payload,
            isKeyframe: true,
            frameId: 258,
            refFrameId: 2,
            rtpTimestamp: 0x1234_5678,
            ssrc: 1,
            rtpSeq: &seq,
            maxPayload: 1300
        )

        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(seq, 2)

        XCTAssertEqual(packets[0].count, 19 + 1300)
        XCTAssertEqual(packets[0][0], 0x80)
        XCTAssertEqual(packets[0][1], 96)
        XCTAssertEqual(packets[0][2], 0xFF)
        XCTAssertEqual(packets[0][3], 0xFF)
        XCTAssertEqual(packets[0][12], 0xC0)
        XCTAssertEqual(packets[0][13], 2)
        XCTAssertEqual(packets[0][15], 0)
        XCTAssertEqual(packets[0][17], 2)
        XCTAssertEqual(packets[0][18], 2)

        XCTAssertEqual(packets[2].count, 19 + 100)
        XCTAssertEqual(packets[2][1], 0x80 | 96)
        XCTAssertEqual(packets[2][2], 0x00)
        XCTAssertEqual(packets[2][3], 0x01)
        XCTAssertEqual(packets[2][15], 2)
    }

    func testParseCompoundRtcpEventsAndNackBitVector() {
        var compound = Data()

        // 1. RTCP XR RRTR (PT=207, 20 bytes, blockType=4 at byte 8)
        var rrtr = [UInt8](repeating: 0, count: 20)
        rrtr[0] = 0x80
        rrtr[1] = 207
        rrtr[3] = 4
        rrtr[8] = 4
        compound.append(contentsOf: rrtr)

        // 2. RTCP PSFB PLI (PT=206, FMT=1, 12 bytes)
        var pli = [UInt8](repeating: 0, count: 12)
        pli[0] = 0x81
        pli[1] = 206
        pli[3] = 2
        compound.append(contentsOf: pli)

        // 3. Cast Feedback (PT=206, FMT=15, 'CAST' magic, 1 loss field = 24 bytes)
        var castFb = [UInt8](repeating: 0, count: 24)
        castFb[0] = 0x8F
        castFb[1] = 206
        castFb[3] = 5
        castFb[12] = 0x43; castFb[13] = 0x41; castFb[14] = 0x53; castFb[15] = 0x54
        castFb[17] = 1
        castFb[20] = 7
        castFb[21] = 0x00; castFb[22] = 0x03
        castFb[23] = 0b0000_0101
        compound.append(contentsOf: castFb)

        let events = CastRTP.parseRtcpEvents(compound)
        XCTAssertEqual(events, [
            .rrtr,
            .pli,
            .castFeedback([CastRTP.LossField(frameId8: 7, lostPacketId: 3, bitVector: 0b0000_0101)])
        ])

        let indices = CastRTP.missingPacketIndices(lostPacketId: 3, bitVector: 0b0000_0101, totalPacketCount: 10)
        XCTAssertEqual(indices, [3, 4, 6])
        XCTAssertNil(CastRTP.missingPacketIndices(lostPacketId: 0xFFFF, bitVector: 0, totalPacketCount: 10))
    }

    func testRtpTimestamp90kHzWrapsModularlyPast14Hours() {
        let fourteenHoursUs: Int64 = 14 * 3600 * 1_000_000
        let ts = CastSender.rtpTimestamp90kHz(elapsedMicroseconds: fourteenHoursUs)
        let expected = UInt32(truncatingIfNeeded: Int64(14 * 3600) * 90_000)
        XCTAssertEqual(ts, expected)
    }

    // MARK: - Sender & Hardware Support

    func testCastSenderOfflineLifecycle() {
        final class MockDelegate: CastSenderDelegate {
            var statusMessages: [String] = []
            func castSenderStatusDidChange(_ status: String) {
                statusMessages.append(status)
            }
        }

        let delegate = MockDelegate()
        let sender = CastSender(host: "127.0.0.1", port: 18009, delegate: delegate)
        XCTAssertFalse(sender.isStreaming)
        XCTAssertFalse(sender.isConnected)
        XCTAssertEqual(sender.framesSent, 0)

        sender.start(width: 1920, height: 1080, fps: 60, maxBitrate: 10_000_000)
        let dummyData = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1f])
        sender.enqueueAnnexBFrame(frameData: dummyData, isKeyframe: true, ptsMicroseconds: 1_000_000)
        XCTAssertEqual(sender.framesSent, 0)

        sender.stop()
        XCTAssertFalse(sender.isStreaming)
        XCTAssertFalse(sender.isConnected)
    }

    @MainActor
    func testCastDiscoveryInitialization() {
        let discovery = CastDiscovery.shared
        XCTAssertNotNil(discovery)
        XCTAssertFalse(discovery.isSearching)
        XCTAssertTrue(discovery.devices.isEmpty)
    }

    func testHardwareEncoderSupportCached() {
        #if arch(arm64)
        XCTAssertTrue(CastEncoderSupport.supportsH264)
        XCTAssertTrue(CastEncoderSupport.supportsHEVC)
        #endif
    }
}
