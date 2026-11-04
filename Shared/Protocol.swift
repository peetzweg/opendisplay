// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation/Network-only so it stays platform-neutral.

import Foundation
import Network

/// The wire-protocol contract between the two apps, decoupled from the app's
/// marketing version. See COMPATIBILITY.md.
///
/// Bumped only when the wire changes, not every release, so UI-only releases
/// never trigger a compatibility event. A peer that advertises no version is
/// protocol 1 — that's every install in the field that predates the handshake.
enum WireProtocol {
    /// The protocol version this build speaks.
    static let version = 3

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

/// Control-message `type` strings introduced with the handshake. The pre-
/// existing types (`hello`, `ping`, `pong`, `touch`, …) stay inline for now to
/// keep this change additive and low-risk; unify later if we do a wider pass.
enum WireMessage {
    static let welcome = "welcome"                  // Mac -> phone: Mac's pv + min supported
    static let updateRequired = "updateRequired"    // Mac -> phone: peer is below the Mac's floor
    static let sleeping = "sleeping"                // phone -> Mac: device locked, reconnect on wake
    static let closing = "closing"                  // phone -> Mac: app quit, end the session for good
    static let streamConfig = "streamConfig"        // Mac -> receiver: selected video operating point
    static let power = "power"                      // Mac -> receiver: shut down (PROTOCOL.md 6.6)

    // Symmetric unpair (PROTOCOL.md 11.5), from #151. Sent on a live mutual
    // TLS session by the side whose user chose Forget, before it closes.
    // `fromID` is the sender's install id (the pin the peer drops); `toID`
    // the intended peer's, which a receiver of another id ignores.
    static let unpair = "unpair"                    // either direction

    // Pairing channel (PROTOCOL.md 11.3). Spoken only on the pairing port.
    static let pairStart = "pairStart"              // sender -> receiver
    static let pairChallenge = "pairChallenge"      // receiver -> sender
    static let pairProof = "pairProof"              // sender -> receiver
    static let pairDone = "pairDone"                // receiver -> sender
    static let pairError = "pairError"              // receiver -> sender
}

/// Constants for pairing and the encrypted transport (issue #16,
/// PROTOCOL.md section 11). Foundation-only, like the rest of this file.
enum WireCrypto {
    /// Ports are the receiver's base port plus these offsets: base + 1 is
    /// already the UDP cursor channel.
    static let tlsPortOffset: UInt16 = 2
    static let pairPortOffset: UInt16 = 3
    /// Upper bound for one pairing frame; SRP keys are 384 bytes in hex.
    static let maxPairFrameBytes = 16 << 10
    /// Each listener is also published as its own Bonjour service under the
    /// receiver's service name, so a sender can dial it by name: resolving
    /// the main service only ever yields the base port.
    static let tlsServiceType = "_od-tls._tcp"
    static let pairServiceType = "_od-pair._tcp"

    /// Where to reach the TLS or pairing listener of the receiver behind
    /// `endpoint`: the same-named service of `serviceType`, or the same
    /// host at base port + offset for a literal address (-host/-port).
    static func endpoint(_ endpoint: NWEndpoint, serviceType: String, portOffset: UInt16) -> NWEndpoint {
        switch endpoint {
        case .service(let name, _, let domain, let interface):
            return .service(name: name, type: serviceType, domain: domain, interface: interface)
        case .hostPort(let host, let port):
            return .hostPort(host: host, port: NWEndpoint.Port(rawValue: port.rawValue &+ portOffset) ?? port)
        default:
            return endpoint
        }
    }

    // Keychain namespace (".v1" is the migration lever). From #151.
    /// kSecAttrApplicationTag (as UTF-8 Data) of our private key AND
    /// kSecAttrLabel of our certificate — the identity forms from the pair.
    static let identityKeychainLabel = "com.opendisplay.identity.v1"
    /// kSecClassGenericPassword service holding one row per pinned peer
    /// (account = peer install id, label = display name, value = SPKI DER).
    static let pinKeychainService = "com.opendisplay.trust.v1"
    /// Account of the row holding this install's id, in the identity's
    /// namespace so id and key live and die together.
    static let installIDAccount = "macInstallID"
    /// UserDefaults flag for reinstall cleanup: Keychain items survive an
    /// app deletion on iOS, UserDefaults do not, so a missing flag on launch
    /// means stale Keychain state to purge.
    static let trustStoreInitializedDefaultsKey = "trustStoreInitialized.v1"

    // Fingerprint derivation ("safety number" style), from #151.
    static let fingerprintHKDFSalt = Data("OpenDisplay-TLS-Pairing-v1".utf8)
    static let fingerprintHKDFInfo = Data("fingerprint".utf8)
}

/// What a `power` message asks the receiver to do (PROTOCOL.md 6.6). The
/// wire says what, each receiver platform decides how.
enum PowerAction: String, CaseIterable {
    case shutdown
}

/// One receiver-supported operating envelope. Every non-nil limit in an
/// entry applies together; multiple entries for the same codec are alternatives.
/// Codec names stay strings so older builds can ignore future codecs.
struct VideoCapability: Codable, Equatable {
    let codec: String
    let maxWidth: Int?
    let maxHeight: Int?
    let maxFrameRate: Int?
    let maxPixelsPerSecond: Int?

    init(codec: String, maxWidth: Int? = nil, maxHeight: Int? = nil,
         maxFrameRate: Int? = nil, maxPixelsPerSecond: Int? = nil) {
        self.codec = codec
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFrameRate = maxFrameRate
        self.maxPixelsPerSecond = maxPixelsPerSecond
    }
}
