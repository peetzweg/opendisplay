// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Shared but NOT Foundation-only: imports Network, Security, CryptoKit.

import Foundation
import Network
import Security
import CryptoKit

/// Builds pinned mutual-TLS 1.3 `NWProtocolTLS.Options` for both the phone
/// listener and the Mac dialer. Returns nil on any
/// failure — the caller treats that as a hard stop; it must NEVER fall back
/// to plaintext for a pinned peer, and there is no force-unwrap in the
/// identity path.
enum TLSConfigurator {
    /// - identity:    own SecIdentity from TrustStore.ownIdentity()
    /// - pinnedSPKIs: closure returning the current pinned-SPKI set; MUST read
    ///                an in-memory snapshot (TrustStore.allPinnedPeerSPKIs on
    ///                the phone, a captured single-element array on the Mac).
    ///                It is invoked on `queue` during handshakes — Keychain
    ///                I/O in it is forbidden.
    /// - isListener:  true ⇒ additionally require a client certificate.
    /// - queue:       the connection's serial queue; verify block runs here.
    static func mutualTLSOptions(identity: SecIdentity,
                                  pinnedSPKIs: @escaping () -> [Data],
                                  isListener: Bool,
                                  queue: DispatchQueue) -> NWProtocolTLS.Options? {
        guard let secIdentity = sec_identity_create(identity) else {
            Log.info("ERROR: sec_identity_create failed — identity unusable, refusing TLS setup")
            return nil // no crash, no plaintext fallback
        }
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13) // min == max: downgrade-proof
        sec_protocol_options_set_local_identity(sec, secIdentity)       // both roles present a cert
        if isListener {
            // Without this the listener silently degrades to one-way server
            // auth.
            sec_protocol_options_set_peer_authentication_required(sec, true)
        }
        sec_protocol_options_set_verify_block(sec, { _, sec_trust, complete in
            // Self-signed world: pinning REPLACES chain trust — deliberately
            // no SecTrustEvaluateWithError.
            let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first,
                  let key = SecCertificateCopyKey(leaf),
                  let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data?,
                  let pub = try? P256.Signing.PublicKey(x963Representation: x963) else {
                complete(false)
                return
            }
            // Same-source rule: re-encode through the SAME CryptoKit encoder
            // that produced every pinned value, so pinned == extracted
            // byte-for-byte. Plain Data equality — both operands public,
            // so a constant-time compare is deliberately not needed.
            complete(pinnedSPKIs().contains(pub.derRepresentation))
        }, queue)
        return tls
    }
}
