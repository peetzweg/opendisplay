// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation-only so it stays platform-neutral.

import Foundation

/// The wire-protocol contract between the two apps, decoupled from the app's
/// marketing version. See COMPATIBILITY.md.
///
/// Bumped only when the wire changes, not every release, so UI-only releases
/// never trigger a compatibility event. A peer that advertises no version is
/// protocol 1 — that's every install in the field that predates the handshake.
enum WireProtocol {
    /// The protocol version this build speaks.
    // Protocol 5 adds optional receiver-device-ICC passthrough and ProRes
    // 4444 XQ negotiation. It also includes protocol 3's Pencil messages.
    static let version = 5

    /// Protocol version that introduced Apple Pencil / proximity wire messages.
    /// Peers below this get pencil input as legacy `touch` events.
    static let pencilWireVersion = 3

    /// Oldest peer protocol version this build still supports. Stays at 1
    /// (support everything) until a deliberate two-phase breaking change
    /// raises it — raising this is what turns "peer too old" into a hard gate.
    static let minSupportedPeer = 1

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
}

/// Device-independent working color spaces supported by the stream. The
/// receiver chooses the smallest space that preserves its panel gamut; the
/// sender uses that same space for the virtual display, capture and codec VUI.
/// Unknown/absent values intentionally fall back to sRGB for old peers.
enum WireColorSpace: String, Codable {
    case sRGB = "srgb"
    case displayP3 = "displayP3"
}

/// Reads the RGB primary XYZ tags from an ICC display profile and chooses the
/// closest stream working space. This stays Foundation-only so both Mac apps
/// can share the decision without making the iOS target depend on ColorSync.
enum ICCProfileGamut {
    static func preferredWorkingSpace(profileData: Data?, name: String?) -> WireColorSpace {
        if name?.lowercased().contains("p3") == true { return .displayP3 }
        guard let profileData, let primaries = rgbXYZ(from: profileData) else { return .sRGB }

        // D50-adapted XYZ values from Apple's standard sRGB and Display P3
        // profiles. Calibrated iMac profiles vary slightly but remain much
        // closer to P3 than sRGB.
        let sRGB = [
            0.436096, 0.222504, 0.013931,
            0.385071, 0.716888, 0.097076,
            0.143036, 0.060608, 0.713898,
        ]
        let displayP3 = [
            0.515121, 0.241196, -0.001053,
            0.291977, 0.692245, 0.041885,
            0.157104, 0.066574, 0.784073,
        ]
        func distance(to reference: [Double]) -> Double {
            zip(primaries, reference).reduce(0) { result, pair in
                let delta = pair.0 - pair.1
                return result + delta * delta
            }
        }
        return distance(to: displayP3) < distance(to: sRGB) ? .displayP3 : .sRGB
    }

    private static func rgbXYZ(from data: Data) -> [Double]? {
        guard let tagCount = uint32(data, at: 128), tagCount <= 256 else { return nil }
        var tags: [UInt32: Int] = [:]
        for index in 0..<Int(tagCount) {
            let entry = 132 + index * 12
            guard let signature = uint32(data, at: entry),
                  let offset = uint32(data, at: entry + 4) else { return nil }
            tags[signature] = Int(offset)
        }
        let signatures: [UInt32] = [0x7258_595A, 0x6758_595A, 0x6258_595A] // rXYZ/gXYZ/bXYZ
        var result: [Double] = []
        for signature in signatures {
            guard let offset = tags[signature],
                  uint32(data, at: offset) == 0x5859_5A20 else { return nil } // "XYZ "
            for component in 0..<3 {
                guard let raw = uint32(data, at: offset + 8 + component * 4) else { return nil }
                result.append(Double(Int32(bitPattern: raw)) / 65536.0)
            }
        }
        return result
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { bytes in
            let p = bytes.bindMemory(to: UInt8.self)
            return UInt32(p[offset]) << 24
                | UInt32(p[offset + 1]) << 16
                | UInt32(p[offset + 2]) << 8
                | UInt32(p[offset + 3])
        }
    }
}

/// Control-message `type` strings introduced with the handshake. The pre-
/// existing types (`hello`, `ping`, `pong`, `touch`, …) stay inline for now to
/// keep this change additive and low-risk; unify later if we do a wider pass.
enum WireMessage {
    static let welcome = "welcome"                  // Mac -> phone: Mac's pv + min supported
    static let updateRequired = "updateRequired"    // Mac -> phone: peer is below the Mac's floor
    static let sleeping = "sleeping"                // phone -> Mac: device locked, reconnect on wake
    static let closing = "closing"                  // phone -> Mac: app quit, end the session for good
}
