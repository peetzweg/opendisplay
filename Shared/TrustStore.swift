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
/// verify block.
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
    /// In-memory snapshot of all pinned peers as (peerID, SPKI DER) pairs.
    /// Refreshed from the Keychain by `refreshSnapshot()`; read lock-only
    /// everywhere else, so both the TLS verify block (SPKI membership) and
    /// resolvePeerID (SPKI → peerID) run with zero Keychain I/O on the queue.
    private var snapshot: [(peerID: String, spki: Data)] = []

    private init() {
        // Keychain items outlive an app deletion on iOS; UserDefaults do not.
        // No flag means a fresh install (or the first launch of a build that
        // has pairing): whatever trust state is left belongs to a previous
        // install whose peers no longer know us.
        if !UserDefaults.standard.bool(forKey: WireCrypto.trustStoreInitializedDefaultsKey) {
            purgeAll()
            UserDefaults.standard.set(true, forKey: WireCrypto.trustStoreInitializedDefaultsKey)
        }
        refreshSnapshot()
    }

    /// The data-protection keychain (TN3137) needs a keychain-access-group
    /// entitlement on macOS, which only team-signed builds carry. Ad hoc dev
    /// builds (run.sh) and unsigned CI builds get errSecMissingEntitlement,
    /// so on macOS they fall back to the login keychain: same items, same
    /// queries. iOS always uses the data-protection keychain and ignores this.
    static let useDataProtectionKeychain: Bool = {
        #if os(macOS)
        // Reads of a missing item succeed without the entitlement; only a
        // write tells. Add and remove a throwaway row.
        let probe: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.pinKeychainService + ".probe",
            kSecAttrAccount: "probe",
            kSecValueData: Data([0]),
            kSecUseDataProtectionKeychain: true,
        ]
        var status = SecItemAdd(probe as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            var delete = probe
            delete.removeValue(forKey: kSecValueData)
            SecItemDelete(delete as CFDictionary)
            status = errSecSuccess
        }
        if status == errSecMissingEntitlement {
            Log.info("trust store: no keychain entitlement (unsigned or ad hoc build) — using the login keychain")
            return false
        }
        #endif
        return true
    }()

    // MARK: - Own identity

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
        return Self.spki(of: cert)
    }

    /// Keychain-backed install ID, created atomically with the identity and
    /// deleted by `purgeAll()` — id and key live and die together.
    /// The sender's id in pairing and `unpair` (receivers pin it). Receivers
    /// identify themselves with StreamReceiver.installID instead, the id
    /// their hello and Bonjour TXT already carry.
    func installID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = queryInstallID() {
            return existing
        }
        // No identity yet ⇒ nothing generated ⇒ no install ID either. Drive
        // generation through the same path as ownIdentity() so the two never
        // diverge (id+key created together, in the same call).
        guard generateAndStoreIdentity() != nil else { return nil }
        return queryInstallID()
    }

    // MARK: - Peer pins (kSecClassGenericPassword rows)

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
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
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
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.pinKeychainService,
            kSecAttrAccount: peerID,
            kSecAttrLabel: displayName,
            kSecValueData: spki,
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
        ]
        let status = SecItemAdd(withAccessibility(addQuery) as CFDictionary, nil)
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
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Log.info("ERROR: forget(peerID:) failed for \(peerID) (status \(status))")
        }
        refreshSnapshot()
    }

    /// Nuke everything in both namespaces: all pins, identity key+cert,
    /// install-ID row; empty the snapshot. (Reinstall cleanup and
    /// "Reset identity" both land here.)
    func purgeAll() {
        let deletions: [[CFString: Any]] = [
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: WireCrypto.pinKeychainService,
                kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
            ],
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: WireCrypto.identityKeychainLabel,
                kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
            ],
            [
                kSecClass: kSecClassCertificate,
                kSecAttrLabel: WireCrypto.identityKeychainLabel,
                kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
            ],
            [
                kSecClass: kSecClassKey,
                kSecAttrApplicationTag: Data(WireCrypto.identityKeychainLabel.utf8),
                kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
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
    /// (kSecMatchLimitAll enumeration). Wired to the iOS Settings
    /// "Paired Macs" list.
    func pinnedPeers() -> [(peerID: String, displayName: String)] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.pinKeychainService,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
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

    // MARK: - In-memory SPKI snapshot

    /// Lock-protected copy of the snapshot. NEVER touches the Keychain —
    /// this is what TLS verify blocks read via the `pinnedSPKIs` closure.
    func allPinnedPeerSPKIs() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.map { $0.spki }
    }

    /// Which pinned peerID owns this leaf SPKI, from the in-memory snapshot
    /// ONLY — no Keychain I/O, so it is safe on the TLS/video queue right after
    /// a handshake (resolvePeerID). nil if the SPKI matches no current pin.
    func peerID(forSPKI spki: Data) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.first { $0.spki == spki }?.peerID
    }

    /// Re-read all pins from the Keychain into the snapshot. Called by
    /// init, setPin, forget, purgeAll; listeners also call it on start.
    func refreshSnapshot() {
        // Attributes for all rows, then each row's data: the macOS login
        // keychain refuses kSecReturnData together with kSecMatchLimitAll
        // (errSecParam), and the same two steps work everywhere.
        var fresh: [(peerID: String, spki: Data)] = []
        for peer in pinnedPeers() {
            if let spki = pin(peerID: peer.peerID) {
                fresh.append((peerID: peer.peerID, spki: spki))
            }
        }
        lock.lock()
        snapshot = fresh
        lock.unlock()
    }

    // MARK: - Fingerprint

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

    /// The ONLY sanctioned identity retrieval path — never
    /// `SecIdentityCreateWithCertificate`. Must be called with `lock` held.
    private func queryIdentity() -> SecIdentity? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: WireCrypto.identityKeychainLabel,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
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
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Identity generation. Must be called with `lock` held. On any failure,
    /// deletes whatever partial items were added and returns nil — no
    /// orphans, no crash.
    ///
    /// The key is born in the keychain (SecKeyCreateRandomKey, permanent) and
    /// the certificate is signed through that SecKey. #151 generated the key
    /// in CryptoKit and added it with kSecValueRef, which only the
    /// data-protection keychain accepts; the macOS login keychain (ad hoc
    /// builds, Developer ID builds without a provisioning profile) rejects
    /// such a ref with errSecInvalidItemRef.
    private func generateAndStoreIdentity() -> SecIdentity? {
        let installID = UUID().uuidString
        let tag = Data(WireCrypto.identityKeychainLabel.utf8)

        // 1. Key pair, private half stored in the keychain.
        var privateAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: tag,
            kSecAttrLabel: WireCrypto.identityKeychainLabel,
        ]
        if Self.useDataProtectionKeychain {
            privateAttributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
            kSecPrivateKeyAttrs: privateAttributes,
        ]
        var cfErr: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &cfErr) else {
            Log.info("ERROR: SecKeyCreateRandomKey failed: \(String(describing: cfErr?.takeRetainedValue()))")
            return nil
        }

        // 2. Self-sign with swift-certificates through the SecKey.
        let certificate: Certificate
        do {
            let certKey = try Certificate.PrivateKey(privateKey)
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
            deletePartialIdentityItems()
            return nil
        }

        // 3. DER-serialize (SwiftASN1) and store the certificate. The
        //    identity forms when its public key matches the stored key.
        let certDER: Data
        do {
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            certDER = Data(serializer.serializedBytes)
        } catch {
            Log.info("ERROR: identity DER serialization failed: \(error)")
            deletePartialIdentityItems()
            return nil
        }
        guard let secCert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            Log.info("ERROR: SecCertificateCreateWithData failed")
            deletePartialIdentityItems()
            return nil
        }
        var status = SecItemAdd(withAccessibility([
            kSecClass: kSecClassCertificate,
            kSecValueRef: secCert,
            kSecAttrLabel: WireCrypto.identityKeychainLabel,
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
        ]) as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            Log.info("ERROR: SecItemAdd(certificate) failed (status \(status))")
            deletePartialIdentityItems()
            return nil
        }

        // 4. Persist installID in the SAME namespace (id+key die together).
        status = SecItemAdd(withAccessibility([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: WireCrypto.identityKeychainLabel,
            kSecAttrAccount: WireCrypto.installIDAccount,
            kSecValueData: Data(installID.utf8),
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
        ]) as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            Log.info("ERROR: SecItemAdd(installID) failed (status \(status))")
            deletePartialIdentityItems()
            return nil
        }

        // 5. Fetch the identity the pair formed.
        guard let identity = queryIdentity() else {
            Log.info("ERROR: identity fetch after generation failed")
            deletePartialIdentityItems()
            return nil
        }
        return identity
    }

    /// kSecAttrAccessible exists only in the data-protection keychain; the
    /// login keychain rejects it.
    private func withAccessibility(_ query: [CFString: Any]) -> [CFString: Any] {
        var query = query
        if Self.useDataProtectionKeychain {
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return query
    }

    /// Cleanup for a failed/partial generateAndStoreIdentity() run: deletes
    /// the key (by tag) and cert (by label) so nothing orphaned survives.
    /// Does NOT touch the install-ID row from a prior successful generation.
    private func deletePartialIdentityItems() {
        SecItemDelete([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(WireCrypto.identityKeychainLabel.utf8),
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: WireCrypto.identityKeychainLabel,
            kSecUseDataProtectionKeychain: Self.useDataProtectionKeychain,
        ] as CFDictionary)
    }

    /// Same-source SPKI extraction from a certificate already in the
    /// Keychain: cert → SecKey → X9.63 → CryptoKit → DER. Never hand-assemble
    /// SPKI headers; never return raw X9.63 from any public API.
    static func spki(of cert: SecCertificate) -> Data? {
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
