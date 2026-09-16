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
    static let version = 4

    /// Protocol version that introduced Apple Pencil / proximity wire messages.
    /// Peers below this get pencil input as legacy `touch` events.
    static let pencilWireVersion = 3

    /// Protocol version that introduced tagged frames (see `FrameType`). Below
    /// this, a frame's kind is inferred from its bytes; at or above it, the
    /// frame carries an explicit type byte and audio becomes expressible.
    static let taggedFrameVersion = 4

    /// Oldest peer protocol version this build still supports. Stays at 1
    /// (support everything) until a deliberate two-phase breaking change
    /// raises it — raising this is what turns "peer too old" into a hard gate.
    static let minSupportedPeer = 1

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
}

/// What a frame carries, as the explicit type byte of a tagged frame
/// (protocol 4+, PROTOCOL.md 5).
///
/// Before protocol 4 the kind was *inferred*: a payload starting with `{` and
/// containing no NUL byte was control JSON, anything else was video. That
/// worked only because the two kinds happened to be distinguishable — video
/// frames also begin with `{` (a telemetry prefix) and were told apart by the
/// NUL bytes in their Annex B start codes. Compressed audio has neither
/// property reliably, so a third kind cannot join that scheme: an audio packet
/// whose first byte is `{` and which contains no NUL would be parsed as JSON.
/// Hence the explicit tag.
///
/// Unknown raw values are skipped by the receiver rather than treated as an
/// error, which is what keeps a future type additive for older peers.
enum FrameType: UInt8 {
    case video = 0      // Annex B H.264
    case json = 1       // control message
    case audio = 2      // compressed audio packet (AudioPacket)
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
