// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Shared but NOT Foundation-only (unlike Protocol.swift): imports CryptoKit,
// Security, X509, SwiftASN1.

import Foundation
import CryptoKit
import Security
import X509
import SwiftASN1

/// Own TLS identity + per-peer SPKI pin store. Shared by both targets.
///
/// All Keychain access uses the data-protection keychain (TN3137) under the
/// `WireCrypto.*` namespace. Thread-safe: every public method is internally
/// synchronized (private `NSLock`); `allPinnedPeerSPKIs()` reads ONLY the
/// in-memory snapshot (no Keychain I/O) so it is safe to call from a TLS
/// verify block (wifi-tls-pairing-plan §4, SEV-7).
///
/// Runtime caveat (not a compile-time concern): on macOS, the data-protection
/// keychain requires the app to be signed with an application identifier
/// (TN3137). Normal team-signed Debug/Release builds are fine; a fully
/// unsigned build (`DEVELOPMENT_TEAM` unset, as in CI) will get
/// `errSecMissingEntitlement` at runtime. Every method below fails soft
/// (nil / false / empty, logged) in that case — never crashes.
final class TrustStore {
    static let shared = TrustStore()

    private let lock = NSLock()
    /// In-memory snapshot of all pinned peer SPKI DER blobs (SEV-7). Refreshed
    /// from the Keychain by `refreshSnapshot()`; read lock-only everywhere else.
    private var snapshot: [Data] = []

    private init() {
        refreshSnapshot()
    }

    // MARK: - Own identity (plan §3, SEV-2 same-source fix)

    /// Fetch the stored identity, generating and persisting a fresh one on
    /// first call. nil = keychain unusable (logged, never crashes).
    func ownIdentity() -> SecIdentity? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = queryIdentity() {
            return existing
        }
        return generateAndStoreIdentity()
    }

    /// DER SubjectPublicKeyInfo of our own public key — the exact bytes the
    /// bootstrap exchange sends and the peer pins. Always produced by
    /// CryptoKit's `P256.Signing.PublicKey.derRepresentation` (same-source).
    func ownSPKI() -> Data? {
        guard let identity = ownIdentity() else { return nil }
        var cert: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &cert)
        guard status == errSecSuccess, let cert else {
            Log.info("ERROR: ownSPKI failed to copy certificate from identity (status \(status))")
            return nil
        }
        return spkiFromCertificate(cert)
    }

    /// Keychain-backed install ID, created atomically with the identity and
    /// deleted by `purgeAll()` — id and key live and die together (SEV-5).
    /// The Mac app adopts this as macInstallID in the next milestone.
    func installID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = queryInstallID() {
            return existing
        }
        // No identity yet ⇒ nothing generated ⇒ no install ID either. Drive
        // generation through the same path as ownIdentity() so the two never
        // diverge (SEV-5: id+key created together, in the same call).
        guard generateAndStoreIdentity() != nil else { return nil }
        return queryInstallID()
    }

    // MARK: - Peer pins (kSecClassGenericPassword rows, plan §3 table)

    func hasPin(peerID: String) -> Bool {
        pin(peerID: peerID) != nil
    }

    /// Pinned SPKI DER for a peer, or nil. Reads the Keychain (cold path).
    func pin(peerID: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.pinKeychainService,
            kSecAttrAccount: peerID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound {
                Log.info("ERROR: pin(peerID:) lookup failed (status \(status))")
            }
            return nil
        }
        return data
    }

    /// Persist/overwrite a pin, then refresh the snapshot. Delete-then-add
    /// semantics. false = Keychain write failed (logged).
    @discardableResult
    func setPin(peerID: String, spki: Data, displayName: String) -> Bool {
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.pinKeychainService,
            kSecAttrAccount: peerID,
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.pinKeychainService,
            kSecAttrAccount: peerID,
            kSecAttrLabel: displayName,
            kSecValueData: spki,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            Log.info("ERROR: setPin failed for peer \(peerID) (status \(status))")
            return false
        }
        refreshSnapshot()
        return true
    }

    /// Remove one peer's pin and refresh the snapshot.
    func forget(peerID: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.pinKeychainService,
            kSecAttrAccount: peerID,
            kSecUseDataProtectionKeychain: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Log.info("ERROR: forget(peerID:) failed for \(peerID) (status \(status))")
        }
        refreshSnapshot()
    }

    /// Nuke everything in both namespaces: all pins, identity key+cert,
    /// install-ID row; empty the snapshot. (Reinstall cleanup §6(ii) and
    /// "Reset identity" both land here.)
    func purgeAll() {
        let deletions: [[CFString: Any]] = [
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: WireCrypto.pinKeychainService,
                kSecUseDataProtectionKeychain: true,
            ],
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: WireCrypto.identityKeychainLabel,
                kSecUseDataProtectionKeychain: true,
            ],
            [
                kSecClass: kSecClassCertificate,
                kSecAttrLabel: WireCrypto.identityKeychainLabel,
                kSecUseDataProtectionKeychain: true,
            ],
            [
                kSecClass: kSecClassKey,
                kSecAttrApplicationTag: Data(WireCrypto.identityKeychainLabel.utf8),
                kSecUseDataProtectionKeychain: true,
            ],
        ]
        for query in deletions {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound {
                Log.info("ERROR: purgeAll deletion failed for class \(query[kSecClass] ?? "?") (status \(status))")
            }
        }
        lock.lock()
        snapshot = []
        lock.unlock()
    }

    /// (peerID, displayName) rows for the "Paired Macs"/forget UI
    /// (kSecMatchLimitAll enumeration, plan §3). UI wiring is next milestone.
    func pinnedPeers() -> [(peerID: String, displayName: String)] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.pinKeychainService,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let items = out as? [[CFString: Any]] else {
            if status != errSecItemNotFound {
                Log.info("ERROR: pinnedPeers lookup failed (status \(status))")
            }
            return []
        }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount] as? String else { return nil }
            let label = item[kSecAttrLabel] as? String ?? account
            return (peerID: account, displayName: label)
        }
    }

    // MARK: - In-memory SPKI snapshot (SEV-7)

    /// Lock-protected copy of the snapshot. NEVER touches the Keychain —
    /// this is what TLS verify blocks read via the `pinnedSPKIs` closure.
    func allPinnedPeerSPKIs() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Re-read all pins from the Keychain into the snapshot. Called by
    /// init, setPin, forget, purgeAll; listeners also call it on start.
    func refreshSnapshot() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.pinKeychainService,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        var fresh: [Data] = []
        // kSecReturnData + kSecMatchLimitAll returns an array of the raw value
        // Data blobs — NOT an array of attribute dictionaries. Casting to
        // [[CFString: Any]] silently fails and leaves the snapshot empty, which
        // makes the TLS verify block reject every pinned peer (NoAuth).
        if status == errSecSuccess, let items = out as? [Data] {
            fresh = items
        } else if status != errSecItemNotFound {
            Log.info("ERROR: refreshSnapshot lookup failed (status \(status))")
        }
        lock.lock()
        snapshot = fresh
        lock.unlock()
    }

    // MARK: - Fingerprint (plan §0/§6(iii))

    /// Human-comparable grouped digits: HKDF-SHA256(ikm: spki,
    /// salt: WireCrypto.fingerprintHKDFSalt, info: WireCrypto.fingerprintHKDFInfo,
    /// outputByteCount: 10); split into five 2-byte big-endian integers; each
    /// rendered `% 10000` zero-padded to 4 digits; joined with single spaces.
    /// Example: "0421 9977 1024 0003 8810".
    static func fingerprint(spki: Data) -> String {
        let key = SymmetricKey(data: spki)
        let output = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: WireCrypto.fingerprintHKDFSalt,
            info: WireCrypto.fingerprintHKDFInfo,
            outputByteCount: 10)
        let bytes = output.withUnsafeBytes { Array($0) }
        var groups: [String] = []
        groups.reserveCapacity(5)
        for i in stride(from: 0, to: 10, by: 2) {
            let value = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            groups.append(String(format: "%04d", value % 10000))
        }
        return groups.joined(separator: " ")
    }

    // MARK: - Private helpers

    /// The ONLY sanctioned identity retrieval path (plan §3) — never
    /// `SecIdentityCreateWithCertificate`. Must be called with `lock` held.
    private func queryIdentity() -> SecIdentity? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: WireCrypto.identityKeychainLabel,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        // Safe force-cast: errSecSuccess + kSecReturnRef on kSecClassIdentity
        // is documented to yield a SecIdentity; `as!` here is a type-system
        // formality, not a possible-failure force-unwrap.
        return (out as! SecIdentity)
    }

    /// Must be called with `lock` held.
    private func queryInstallID() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.identityKeychainLabel,
            kSecAttrAccount: WireCrypto.installIDAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Frozen identity-generation call sequence (plan §3). Must be called
    /// with `lock` held. On any failure, deletes whatever partial items were
    /// added and returns nil — no orphans, no crash (SEV-2).
    private func generateAndStoreIdentity() -> SecIdentity? {
        // 1. CryptoKit key — we own the SPKI bytes end to end.
        let priv = P256.Signing.PrivateKey()
        let installID = UUID().uuidString

        // 2. Self-sign with swift-certificates (native CryptoKit signer, no
        //    SecKey bridge for signing).
        let certKey: Certificate.PrivateKey
        let certificate: Certificate
        do {
            certKey = Certificate.PrivateKey(priv)
            let name = try DistinguishedName { CommonName(installID) }
            let now = Date()
            certificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),
                publicKey: certKey.publicKey,
                notValidBefore: now.addingTimeInterval(-86_400),
                notValidAfter: now.addingTimeInterval(20 * 365 * 86_400),
                issuer: name,
                subject: name,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                },
                issuerPrivateKey: certKey)
        } catch {
            Log.info("ERROR: identity self-sign failed: \(error)")
            return nil
        }

        // 3. DER-serialize (SwiftASN1).
        let certDER: Data
        do {
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            certDER = Data(serializer.serializedBytes)
        } catch {
            Log.info("ERROR: identity DER serialization failed: \(error)")
            return nil
        }

        // 4. Import the private key as a SecKey (X9.63: 04||X||Y||K).
        var cfErr: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(priv.x963Representation as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ] as CFDictionary, &cfErr) else {
            Log.info("ERROR: SecKeyCreateWithData failed: \(String(describing: cfErr?.takeRetainedValue()))")
            return nil
        }

        // 5. Add key, then cert. The keychain auto-derives the key's
        //    kSecAttrApplicationLabel (SHA-1 of public key); the identity
        //    forms when that matches the cert's public key — byte-identical
        //    by construction here.
        var status = SecItemAdd([
            kSecClass: kSecClassKey,
            kSecValueRef: secKey,
            kSecAttrApplicationTag: Data(WireCrypto.identityKeychainLabel.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            Log.info("ERROR: SecItemAdd(key) failed (status \(status))")
            return nil
        }

        guard let secCert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            Log.info("ERROR: SecCertificateCreateWithData failed")
            deletePartialIdentityItems()
            return nil
        }
        status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: secCert,
            kSecAttrLabel: WireCrypto.identityKeychainLabel,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            Log.info("ERROR: SecItemAdd(certificate) failed (status \(status))")
            deletePartialIdentityItems()
            return nil
        }

        // 6. Persist installID in the SAME namespace (SEV-5: id+key die together).
        status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.identityKeychainLabel,
            kSecAttrAccount: WireCrypto.installIDAccount,
            kSecValueData: Data(installID.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            Log.info("ERROR: SecItemAdd(installID) failed (status \(status))")
            deletePartialIdentityItems()
            return nil
        }

        // 7. Fetch the implicitly-formed identity — the ONLY sanctioned
        //    retrieval (plan §3's fallback ladder item (a) is NOT
        //    implemented in this phase).
        var out: CFTypeRef?
        status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: WireCrypto.identityKeychainLabel,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary, &out)
        guard status == errSecSuccess else {
            Log.info("ERROR: identity fetch after generation failed (status \(status))")
            deletePartialIdentityItems()
            return nil
        }
        guard let identity = out else {
            Log.info("ERROR: identity fetch after generation returned no ref")
            deletePartialIdentityItems()
            return nil
        }
        // Safe force-cast: errSecSuccess + kSecReturnRef on kSecClassIdentity
        // is documented to yield a SecIdentity.
        return (identity as! SecIdentity)
    }

    /// Cleanup for a failed/partial generateAndStoreIdentity() run: deletes
    /// the key (by tag) and cert (by label) so nothing orphaned survives.
    /// Does NOT touch the install-ID row from a prior successful generation.
    private func deletePartialIdentityItems() {
        SecItemDelete([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(WireCrypto.identityKeychainLabel.utf8),
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: WireCrypto.identityKeychainLabel,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary)
    }

    /// SEV-2 same-source SPKI extraction from a certificate already in the
    /// Keychain: cert → SecKey → X9.63 → CryptoKit → DER. Never hand-assemble
    /// SPKI headers; never return raw X9.63 from any public API.
    private func spkiFromCertificate(_ cert: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(cert) else {
            Log.info("ERROR: SecCertificateCopyKey failed")
            return nil
        }
        var cfErr: Unmanaged<CFError>?
        guard let x963 = SecKeyCopyExternalRepresentation(key, &cfErr) as Data? else {
            Log.info("ERROR: SecKeyCopyExternalRepresentation failed: \(String(describing: cfErr?.takeRetainedValue()))")
            return nil
        }
        guard let pub = try? P256.Signing.PublicKey(x963Representation: x963) else {
            Log.info("ERROR: P256 public key reconstruction from X9.63 failed")
            return nil
        }
        return pub.derRepresentation
    }
}
