import Foundation
import Network

/// RTP/RTCP packet framing, O(1) burst buffering, and receiver feedback parsing for Google Cast Mirroring.
enum CastRTP {
    /// O(1) FIFO packet queue backed by a read-head cursor instead of `Array.removeFirst()`.
    struct PacketBuffer {
        private var storage: [Data] = []
        private var head: Int = 0

        var count: Int { storage.count - head }
        var isEmpty: Bool { head >= storage.count }

        mutating func append(contentsOf packets: [Data]) {
            guard !packets.isEmpty else { return }
            storage.append(contentsOf: packets)
        }

        mutating func popBurst(maxCount: Int) -> ArraySlice<Data> {
            guard maxCount > 0, !isEmpty else { return [] }
            let end = min(storage.count, head + maxCount)
            let slice = storage[head..<end]
            head = end
            if head >= storage.count {
                storage.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 256 && head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
            }
            return slice
        }

        mutating func removeAll() {
            storage.removeAll(keepingCapacity: false)
            head = 0
        }
    }

    struct LossField: Equatable {
        let frameId8: UInt8
        let lostPacketId: UInt16
        let bitVector: UInt8
    }

    enum RtcpEvent: Equatable {
        case rrtr
        case pli
        case castFeedback([LossField])
    }

    /// Packetizes an AES-CTR encrypted frame into Cast RTP packets (12-byte RTP + 7-byte Cast header).
    static func packetizeFrame(
        encryptedPayload: Data,
        isKeyframe: Bool,
        frameId: UInt32,
        refFrameId: UInt8,
        rtpTimestamp: UInt32,
        ssrc: UInt32,
        rtpSeq: inout UInt16,
        maxPayload: Int = 1300
    ) -> [Data] {
        let totalLen = encryptedPayload.count
        guard totalLen > 0, maxPayload > 0 else { return [] }

        let numPackets = (totalLen + maxPayload - 1) / maxPayload
        guard numPackets <= Int(UInt16.max) + 1 else { return [] }
        let maxPacketId = UInt16(numPackets - 1)

        var packets: [Data] = []
        packets.reserveCapacity(numPackets)

        encryptedPayload.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }

            var offset = 0
            var packetId: UInt16 = 0
            while offset < totalLen {
                let chunkLen = min(maxPayload, totalLen - offset)
                let isLast = (offset + chunkLen == totalLen)

                var packet = Data(count: 19 + chunkLen)
                packet.withUnsafeMutableBytes { outRawBuffer in
                    guard let outBuf = outRawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }

                    // RTP header (12 bytes)
                    outBuf[0] = 0x80                          // V=2, P=0, X=0, CC=0
                    outBuf[1] = (isLast ? 0x80 : 0x00) | 96   // marker on final chunk + PT 96

                    let seq = rtpSeq
                    rtpSeq &+= 1
                    outBuf[2] = UInt8((seq >> 8) & 0xFF)
                    outBuf[3] = UInt8(seq & 0xFF)

                    outBuf[4] = UInt8((rtpTimestamp >> 24) & 0xFF)
                    outBuf[5] = UInt8((rtpTimestamp >> 16) & 0xFF)
                    outBuf[6] = UInt8((rtpTimestamp >> 8) & 0xFF)
                    outBuf[7] = UInt8(rtpTimestamp & 0xFF)

                    outBuf[8] = UInt8((ssrc >> 24) & 0xFF)
                    outBuf[9] = UInt8((ssrc >> 16) & 0xFF)
                    outBuf[10] = UInt8((ssrc >> 8) & 0xFF)
                    outBuf[11] = UInt8(ssrc & 0xFF)

                    // Cast payload header (7 bytes)
                    outBuf[12] = (isKeyframe ? 0x80 : 0x00) | 0x40   // keyframe | has refFrameId
                    outBuf[13] = UInt8(frameId & 0xFF)
                    outBuf[14] = UInt8((packetId >> 8) & 0xFF)
                    outBuf[15] = UInt8(packetId & 0xFF)
                    outBuf[16] = UInt8((maxPacketId >> 8) & 0xFF)
                    outBuf[17] = UInt8(maxPacketId & 0xFF)
                    outBuf[18] = refFrameId

                    memcpy(outBuf + 19, bytes + offset, chunkLen)
                }

                packets.append(packet)
                offset += chunkLen
                packetId &+= 1
            }
        }

        return packets
    }

    static func buildSenderReport(
        ssrc: UInt32,
        ntpSec: UInt32,
        ntpFrac: UInt32,
        rtpTimestamp: UInt32,
        packetCount: UInt32,
        octetCount: UInt32
    ) -> Data {
        var rtcp = [UInt8](repeating: 0, count: 28)
        rtcp[0] = 0x80   // V=2, P=0, RC=0
        rtcp[1] = 200    // PT = 200 (Sender Report)
        rtcp[2] = 0
        rtcp[3] = 6      // length in 32-bit words minus one (6 -> 28 bytes)

        func writeUInt32(_ val: UInt32, at index: Int) {
            rtcp[index] = UInt8((val >> 24) & 0xFF)
            rtcp[index + 1] = UInt8((val >> 16) & 0xFF)
            rtcp[index + 2] = UInt8((val >> 8) & 0xFF)
            rtcp[index + 3] = UInt8(val & 0xFF)
        }

        writeUInt32(ssrc, at: 4)
        writeUInt32(ntpSec, at: 8)
        writeUInt32(ntpFrac, at: 12)
        writeUInt32(rtpTimestamp, at: 16)
        writeUInt32(packetCount, at: 20)
        writeUInt32(octetCount, at: 24)

        return Data(rtcp)
    }

    static func sendSenderReport(
        udpConn: NWConnection?,
        ssrc: UInt32,
        ntpSec: UInt32,
        ntpFrac: UInt32,
        rtpTimestamp: UInt32,
        packetCount: UInt32,
        octetCount: UInt32
    ) {
        guard let udpConn else { return }
        let data = buildSenderReport(
            ssrc: ssrc,
            ntpSec: ntpSec,
            ntpFrac: ntpFrac,
            rtpTimestamp: rtpTimestamp,
            packetCount: packetCount,
            octetCount: octetCount
        )
        udpConn.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Parses compound RTCP packets into actionable receiver feedback events.
    static func parseRtcpEvents(_ data: Data) -> [RtcpEvent] {
        var events: [RtcpEvent] = []
        data.withUnsafeBytes { rawBuffer in
            guard let buf = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            let totalBytes = data.count

            while offset + 4 <= totalBytes {
                let firstByte = buf[offset]
                let version = (firstByte >> 6) & 0x03
                guard version == 2 else { break }

                let fmt = firstByte & 0x1F
                let pt = buf[offset + 1]
                let words = (UInt16(buf[offset + 2]) << 8) | UInt16(buf[offset + 3])
                let blockLen = (Int(words) + 1) * 4

                guard blockLen >= 4, offset + blockLen <= totalBytes else { break }
                let block = buf + offset

                switch pt {
                case 207:
                    // Block Type 4 = RRTR (Receiver Reference Time Report)
                    if blockLen >= 20, block[8] == 4 {
                        events.append(.rrtr)
                    }
                case 206 where fmt == 1:
                    // RFC 4585 Picture Loss Indication (PLI)
                    events.append(.pli)
                case 204, 206:
                    guard pt == 204 || fmt == 15 else { break }
                    // Cast receiver feedback ('CAST' magic at bytes 12..15)
                    if blockLen >= 20,
                       block[12] == 0x43, block[13] == 0x41,
                       block[14] == 0x53, block[15] == 0x54 {
                        let lossFieldCount = Int(block[17])
                        if lossFieldCount > 0 {
                            var fields: [LossField] = []
                            fields.reserveCapacity(lossFieldCount)
                            for i in 0..<lossFieldCount {
                                let fieldOffset = 20 + i * 4
                                guard fieldOffset + 4 <= blockLen else { break }
                                let frameId8 = block[fieldOffset]
                                let lostPId = (UInt16(block[fieldOffset + 1]) << 8) | UInt16(block[fieldOffset + 2])
                                let bitVector = block[fieldOffset + 3]
                                fields.append(LossField(frameId8: frameId8, lostPacketId: lostPId, bitVector: bitVector))
                            }
                            if !fields.isEmpty {
                                events.append(.castFeedback(fields))
                            }
                        }
                    }
                default:
                    break
                }

                offset += blockLen
            }
        }
        return events
    }

    /// Decodes a Cast NACK loss field into packet indices within a cached frame.
    /// Returns `nil` when `lostPacketId == 0xFFFF` (meaning retransmit the entire frame).
    static func missingPacketIndices(lostPacketId: UInt16, bitVector: UInt8, totalPacketCount: Int) -> [Int]? {
        if lostPacketId == 0xFFFF { return nil }
        var indices: [Int] = []
        let primary = Int(lostPacketId)
        if primary < totalPacketCount {
            indices.append(primary)
        }
        if bitVector != 0 {
            for bit in 0..<8 where (bitVector & (1 << bit)) != 0 {
                let nextIdx = Int(lostPacketId &+ UInt16(bit + 1))
                if nextIdx < totalPacketCount {
                    indices.append(nextIdx)
                }
            }
        }
        return indices
    }
}
