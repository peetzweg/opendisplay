// Compiled into the Mac sender, the iOS receiver and the Mac receiver (see
// project.yml `sources`). Foundation-only and free of any API newer than the
// receiver's deployment target — the receiver app is pinned several majors
// below the sender.

import Foundation

/// One compressed audio packet as it crosses the wire, inside a frame tagged
/// `FrameType.audio` (PROTOCOL.md 4.1).
///
/// Layout, big-endian throughout, 15 bytes of header then the payload:
///
/// ```
/// [1] codec        0 = AAC-LC
/// [1] flags        bit0 = codec config present
/// [4] sampleRate   Hz  (44100, 48000, …)
/// [8] ptsMs        IEEE 754 double — capture time on the SENDER's clock
/// [1] channels     1 = mono, 2 = stereo
/// [.] payload      compressed audio
/// ```
///
/// The sample rate is carried in plain Hz rather than a scaled unit. A
/// narrower field tempts a kHz-based encoding, and rates like 22050 are not a
/// whole number of any kHz unit — they round, and a receiver decoding at the
/// rounded rate drifts against the sender for the length of the session.
///
/// `ptsMs` is deliberately on the sender's clock and in the same units as the
/// video path's `cap` timestamp, so a receiver maps it to its own clock with
/// the ping/pong offset it already computes for video. That shared timebase is
/// what keeps audio and video aligned without a second synchronisation
/// mechanism.
struct AudioPacket: Equatable {

    enum Codec: UInt8 {
        case aacLC = 0
    }

    static let headerSize = 15

    var codec: Codec = .aacLC
    /// True when `payload` is preceded by, or accompanied by, codec setup the
    /// decoder needs (AAC's AudioSpecificConfig). Re-sent on reconfiguration so
    /// a receiver that joined late can still start decoding.
    var hasConfig = false
    var sampleRate: Int
    var channels: Int
    var ptsMs: Double
    var payload: Data

    // MARK: - Encoding

    func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(codec.rawValue)
        out.append(hasConfig ? 0x01 : 0x00)
        var rate = UInt32(clamping: sampleRate).bigEndian
        withUnsafeBytes(of: &rate) { out.append(contentsOf: $0) }
        var bits = ptsMs.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        out.append(UInt8(clamping: channels))
        out.append(payload)
        return out
    }

    // MARK: - Decoding

    /// Parse a packet, or nil if the bytes are too short or name a codec this
    /// build does not know.
    ///
    /// Returning nil rather than throwing keeps the caller's job simple: an
    /// undecodable packet is dropped like a late one, never fatal. A malformed
    /// packet must not be able to take the session down — it arrives from the
    /// network at ~50 packets a second.
    static func decode(_ data: Data) -> AudioPacket? {
        guard data.count >= headerSize else { return nil }
        // Index from startIndex: a Data sliced out of the receive buffer does
        // not start at zero, and assuming it does reads the wrong bytes.
        let base = data.startIndex
        func byte(_ offset: Int) -> UInt8 { data[base + offset] }

        guard let codec = Codec(rawValue: byte(0)) else { return nil }
        var rate: UInt32 = 0
        for i in 0..<4 { rate = (rate << 8) | UInt32(byte(2 + i)) }
        let sampleRate = Int(rate)
        let channels = Int(byte(14))
        guard sampleRate > 0, channels > 0 else { return nil }

        var bits: UInt64 = 0
        for i in 0..<8 { bits = (bits << 8) | UInt64(byte(6 + i)) }

        return AudioPacket(codec: codec,
                           hasConfig: byte(1) & 0x01 != 0,
                           sampleRate: sampleRate,
                           channels: channels,
                           ptsMs: Double(bitPattern: bits),
                           payload: data.suffix(from: base + headerSize))
    }

    /// The 2-byte AAC-LC AudioSpecificConfig for a sample rate and channel
    /// count (ISO/IEC 14496-3).
    ///
    /// Reconstructed rather than carried on the wire: for AAC-LC it is fully
    /// determined by these two values, both of which every packet already
    /// carries, so sending it would be redundant bytes at ~47 packets a second.
    ///
    ///   5 bits  audioObjectType        2 = AAC-LC
    ///   4 bits  samplingFrequencyIndex
    ///   4 bits  channelConfiguration
    ///   3 bits  zero
    static func aacLCCookie(sampleRate: Int, channels: Int) -> Data? {
        let rates = [96000, 88200, 64000, 48000, 44100, 32000,
                     24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard let index = rates.firstIndex(of: sampleRate),
              (1...7).contains(channels) else { return nil }
        let bits = (2 << 11) | (index << 7) | (channels << 3)
        return Data([UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)])
    }
}
