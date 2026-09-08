// Compiled into the Mac sender, the iOS receiver and the Mac receiver (see
// project.yml `sources`). Keep this Foundation-only so it stays platform-
// neutral, and keep it free of any API newer than the receiver's deployment
// target — the receiver app is pinned several majors below the sender.

import Foundation

/// Wire framing, owned in one place so the sender and receiver cannot drift
/// apart on it.
///
/// Legacy (protocol < 4):  [4-byte big-endian length][payload]
/// Tagged (protocol 4+):   [4-byte big-endian length][1-byte type][payload]
///
/// The length covers the type byte, so the deframing loop's bounds arithmetic
/// is identical in both eras: read 4, read that many, repeat. Only the
/// interpretation of the bytes that follow changes.
enum FrameCodec {

    /// Frame `payload` for a peer that speaks `tagged` framing or not.
    ///
    /// The tag is a *negotiated* capability, never assumed: passing
    /// `tagged: false` reproduces the pre-protocol-4 wire byte for byte, which
    /// is what lets a protocol-4 build talk to every install already in the
    /// field.
    static func encode(_ payload: Data, type: FrameType, tagged: Bool) -> Data {
        let bodyCount = tagged ? payload.count + 1 : payload.count
        var frame = Data(capacity: bodyCount + 4)
        var header = UInt32(bodyCount).bigEndian
        withUnsafeBytes(of: &header) { frame.append(contentsOf: $0) }
        if tagged { frame.append(type.rawValue) }
        frame.append(payload)
        return frame
    }

    /// One deframed frame: its declared kind and its bytes.
    struct Frame {
        let type: FrameType?    // nil = tagged frame carrying an unknown type
        let payload: Data
    }

    /// Split a frame body into its type and payload.
    ///
    /// `tagged` says how to read it, and is the caller's negotiated per-
    /// connection state rather than anything inferred from these bytes. When
    /// false, the kind is recovered with the legacy heuristic — see
    /// `looksLikeJSON`.
    ///
    /// Returns nil only for a tagged body that is empty (no room for the type
    /// byte), which is a malformed frame.
    static func decode(body: Data, tagged: Bool) -> Frame? {
        guard tagged else {
            return Frame(type: looksLikeJSON(body) ? .json : .video, payload: body)
        }
        guard let first = body.first else { return nil }
        return Frame(type: FrameType(rawValue: first),
                     payload: body.dropFirst())
    }

    /// The pre-protocol-4 heuristic, preserved exactly as it behaved when it
    /// was the only way to tell a frame's kind.
    ///
    /// It is retained *only* for peers below protocol 4. Tagged frames never
    /// consult it, which is the point of the tag: the ambiguity it papers over
    /// (a video frame's leading `{`, ruled out by the NUL bytes in Annex B
    /// start codes) has no equivalent answer once audio is on the wire.
    static func looksLikeJSON(_ data: Data) -> Bool {
        data.count < 32_768 && data.first == UInt8(ascii: "{") && !data.contains(0x00)
    }
}
