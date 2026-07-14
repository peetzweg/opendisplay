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
    static let version = 3

    /// Oldest peer protocol version this build still supports. Raised 1 → 3
    /// in Phase 2 of the WiFi TLS rollout (wifi-tls-pairing-plan §8): pv≤2
    /// peers predate the cert-pinned TLS transport, and plaintext WiFi is
    /// closed — "peer too old" is now a hard welcome/updateRequired gate.
    static let minSupportedPeer = 3

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
}

/// Control-message `type` strings introduced with the handshake. The pre-
/// existing types (`hello`, `ping`, `pong`, `touch`, …) stay inline for now to
/// keep this change additive and low-risk; unify later if we do a wider pass.
enum WireMessage {
    static let welcome = "welcome"                  // Mac -> phone: Mac's pv + min supported
    static let updateRequired = "updateRequired"    // Mac -> phone: peer is below the Mac's floor

    // USB trust-bootstrap channel (wifi-tls-pairing-plan §2). Spoken ONLY on
    // the loopback-bound bootstrap port, framed [UInt32 BE length][JSON],
    // single message < WireCrypto.maxBootstrapFrameBytes.
    static let trustOffer  = "trustOffer"    // Mac -> phone: {"type","pv","macID","macName","spki"}
    static let trustAccept = "trustAccept"   // phone -> Mac: {"type","phoneID","spki"}
    static let trustDeny   = "trustDeny"     // phone -> Mac: {"type"}

    // Symmetric unpair (revocation), issue: one-sided forget leaves trust
    // asymmetric. Sent on the live control channel by the side whose user
    // tapped Forget/Reset, BEFORE that side tears the connection down.
    // fromID = the sender's installID — the pin the receiver must drop.
    // toID   = the intended receiver's installID — a receiver whose own ID
    //          differs ignores the message (protects an unrelated Mac on the
    //          USB cable, where there is no cryptographic peer identity).
    // Additive: old peers log-and-ignore unknown types.
    static let unpair = "unpair"    // either direction: {"type","fromID","toID"}
}

/// Constants for the cert-pinned mutual-TLS transport and USB trust bootstrap
/// (wifi-tls-pairing-plan §2-§4, §8). Foundation-only, like the rest of this file.
enum WireCrypto {
    /// Loopback-only USB trust-bootstrap listener port (plan §2, §6(i)).
    static let bootstrapPort: UInt16 = 9010
    /// Mutual-TLS 1.3 video/control listener port (plan §4).
    static let tlsPort: UInt16 = 9001
    /// Upper bound for a single framed bootstrap message (plan §2).
    static let maxBootstrapFrameBytes = 1 << 20

    // Keychain namespace (plan §3 table; ".v1" is the migration lever).
    /// kSecAttrApplicationTag (as UTF-8 Data) of our private key AND
    /// kSecAttrLabel of our certificate — identity forms implicitly from the pair.
    static let identityKeychainLabel = "com.opendisplay.identity.v1"
    /// kSecClassGenericPassword service holding one row per pinned peer
    /// (account = peer installID, label = display name, value = SPKI DER).
    static let pinKeychainService = "com.opendisplay.trust.v1"
    /// Account name of the generic-password row storing this install's ID in
    /// the SAME service namespace as the identity, so id+key live and die
    /// together (plan §3, SEV-5 fix).
    static let installIDAccount = "macInstallID"
    /// UserDefaults flag for reinstall cleanup (plan §6(ii)) — consumed by the
    /// platform apps in the NEXT milestone; defined here so both use one key.
    static let trustStoreInitializedDefaultsKey = "trustStoreInitialized.v1"

    // Fingerprint derivation (plan §0 "Signal safety-number style", §6(iii)).
    // HKDF-SHA256(ikm: SPKI DER, salt:, info:, out: 10 bytes) — domain-separated
    // so the displayed digits can never be confused with any other hash of the key.
    static let fingerprintHKDFSalt = Data("OpenDisplay-TLS-Pairing-v1".utf8)
    static let fingerprintHKDFInfo = Data("fingerprint".utf8)
}
