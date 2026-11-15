import Foundation
import Network
import VideoToolbox
import CoreMedia

enum CastVideoCodec: String {
    case h264
    case hevc
}

/// Hardware encoder availability probed once per process so each Cast OFFER
/// does not spin up and tear down `VTCompressionSession` instances.
enum CastEncoderSupport {
    static func isAvailable(codec: CMVideoCodecType) -> Bool {
        let spec: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any
        ] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: 1920,
            height: 1080,
            codecType: codec,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if status == noErr, let session {
            VTCompressionSessionInvalidate(session)
            return true
        }
        return false
    }

    static let supportsH264: Bool = isAvailable(codec: kCMVideoCodecType_H264)
    static let supportsHEVC: Bool = isAvailable(codec: kCMVideoCodecType_HEVC)
}

enum CastWireError: LocalizedError, Equatable {
    case oversizedFrame(UInt32)

    var errorDescription: String? {
        switch self {
        case .oversizedFrame(let length):
            return "Cast control frame exceeded 1 MiB limit (\(length) bytes)."
        }
    }
}

/// Cast V2 `[4-byte big-endian length][CastMessage protobuf]` framing and local-LAN `NWParameters`.
enum CastWire {
    /// Upper bound (1 MiB) for a single Cast V2 control frame over TLS.
    static let maxFrameSize: UInt32 = 1_048_576

    static func encodeVarint(_ value: UInt64) -> Data {
        var data = Data()
        var v = value
        while v >= 0x80 {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v & 0x7F))
        return data
    }

    static func encodeStringField(fieldNumber: Int, string: String) -> Data {
        let utf8 = Data(string.utf8)
        let tag = UInt64((fieldNumber << 3) | 2)
        var res = Data()
        res.append(encodeVarint(tag))
        res.append(encodeVarint(UInt64(utf8.count)))
        res.append(utf8)
        return res
    }

    static func encodeIntField(fieldNumber: Int, value: Int) -> Data {
        let tag = UInt64((fieldNumber << 3) | 0)
        var res = Data()
        res.append(encodeVarint(tag))
        res.append(encodeVarint(UInt64(bitPattern: Int64(value))))
        return res
    }

    static func buildMessage(sourceId: String, destId: String, ns: String, jsonPayload: String) -> Data {
        var pb = Data()
        pb.append(encodeIntField(fieldNumber: 1, value: 0))   // protocol_version = CASTV2_1_0 (0)
        pb.append(encodeStringField(fieldNumber: 2, string: sourceId))
        pb.append(encodeStringField(fieldNumber: 3, string: destId))
        pb.append(encodeStringField(fieldNumber: 4, string: ns))
        pb.append(encodeIntField(fieldNumber: 5, value: 0))   // payload_type = STRING (0)
        pb.append(encodeStringField(fieldNumber: 6, string: jsonPayload))

        let len = UInt32(pb.count)
        var packet = Data(capacity: 4 + pb.count)
        packet.append(UInt8((len >> 24) & 0xFF))
        packet.append(UInt8((len >> 16) & 0xFF))
        packet.append(UInt8((len >> 8) & 0xFF))
        packet.append(UInt8(len & 0xFF))
        packet.append(pb)
        return packet
    }

    /// Extracts all complete `[4-byte big-endian length][protobuf]` frames from `buffer`.
    /// Byte-wise header reads keep sliced `Data` buffers safe regardless of `startIndex` alignment.
    static func extractFrames(from buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []
        while buffer.count >= 4 {
            let base = buffer.startIndex
            let msgLen = (UInt32(buffer[base]) << 24)
                | (UInt32(buffer[base + 1]) << 16)
                | (UInt32(buffer[base + 2]) << 8)
                | UInt32(buffer[base + 3])

            guard msgLen <= maxFrameSize else {
                buffer.removeAll()
                throw CastWireError.oversizedFrame(msgLen)
            }

            let totalPacketLen = 4 + Int(msgLen)
            guard buffer.count >= totalPacketLen else { break }

            let frame = Data(buffer[(base + 4)..<(base + totalPacketLen)])
            buffer.removeSubrange(base..<(base + totalPacketLen))
            frames.append(frame)
        }
        if buffer.isEmpty {
            buffer = Data()   // reset slice indices back to 0 when drained
        }
        return frames
    }

    struct ParsedMessage: Equatable {
        var sourceId: String?
        var destId: String?
        var namespaceStr: String?
        var payloadUtf8: String?
    }

    static func parseProtobuf(data: Data) -> ParsedMessage? {
        var msg = ParsedMessage()
        var offset = 0
        let count = data.count

        return data.withUnsafeBytes { rawBuffer -> ParsedMessage? in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return count == 0 ? msg : nil
            }

            func readVarint() -> UInt64? {
                var value: UInt64 = 0
                var shift: UInt64 = 0
                while offset < count {
                    guard shift < 64 else { return nil }
                    let b = bytes[offset]
                    offset += 1
                    value |= UInt64(b & 0x7F) << shift
                    if (b & 0x80) == 0 {
                        return value
                    }
                    shift += 7
                }
                return nil
            }

            while offset < count {
                guard let tag = readVarint() else { return nil }
                let fieldNumber = Int(tag >> 3)
                let wireType = Int(tag & 0x07)

                switch wireType {
                case 0:   // varint
                    guard readVarint() != nil else { return nil }
                case 1:   // 64-bit fixed
                    guard count - offset >= 8 else { return nil }
                    offset += 8
                case 2:   // length-delimited
                    guard let len = readVarint(),
                          len <= UInt64(count - offset) else { return nil }
                    let lenInt = Int(len)
                    let strData = Data(bytes: bytes + offset, count: lenInt)
                    offset += lenInt
                    if let str = String(data: strData, encoding: .utf8) {
                        switch fieldNumber {
                        case 2: msg.sourceId = str
                        case 3: msg.destId = str
                        case 4: msg.namespaceStr = str
                        case 6: msg.payloadUtf8 = str
                        default: break
                        }
                    }
                case 5:   // 32-bit fixed
                    guard count - offset >= 4 else { return nil }
                    offset += 4
                default:
                    return nil
                }
            }
            return msg
        }
    }

    static func makeConnectPayload(connType: Int) -> String {
        """
        {"type":"CONNECT","userAgent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36","connType":\(connType),"origin":{},"senderInfo":{"sdkType":2,"version":"120.0.6099.109","browserVersion":"120.0.6099.109","platform":4,"connectionType":1,"systemVersion":"Macintosh; Intel Mac OS X 10_15_7"}}
        """
    }

    /// Configures `NWParameters` for local-LAN Cast traffic: bypasses system proxies (#483)
    /// and restricts to IPv4 so Cast receivers' IPv4-only UDP media sockets match TLS.
    static func configureLocalParameters(_ parameters: NWParameters) {
        parameters.preferNoProxies = true
        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
    }
}
