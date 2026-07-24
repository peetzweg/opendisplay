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
    static let version = 2

    /// Oldest peer protocol version this build still supports. Stays at 1
    /// (support everything) until a deliberate two-phase breaking change
    /// raises it — raising this is what turns "peer too old" into a hard gate.
    static let minSupportedPeer = 1

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
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

/// The reverse direction (issue #122, iPad -> Mac): the device's broadcast
/// extension captures the screen and streams it to a Mac window. Same framing
/// and roles as the forward direction — the receiver LISTENS, the sender
/// dials — but discovered under its own Bonjour type so the Mac's existing
/// device browser and the receiving Mac never mistake each other for a
/// forward-direction peer. (Bonjour service labels max out at 15 chars —
/// "opensidecar-rev" is exactly 15.)
enum ReverseWire {
    static let serviceType = "_opensidecar-rev._tcp"

    /// App-group container shared by the iOS app and its broadcast upload
    /// extension: the app writes the chosen Mac's service name, the extension
    /// reads it and reports its status back. Must match
    /// `com.apple.security.application-groups` in both entitlements files.
    static let appGroup = "group.com.peetzweg.opensidecar.ios"

    /// App-group defaults keys.
    static let targetNameKey = "sendTargetName"     // Mac service name to dial
    static let statusKey = "broadcastStatus"        // extension -> app, for UI
}
