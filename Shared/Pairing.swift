// Code pairing for the encrypted transport (issue #16, PROTOCOL.md 11.3).
// Compiled into the sender, both receivers and the Mac tests. Crypto only:
// the network halves are PairingListener (receivers) and PairingClient (Mac).
//
// The receiver shows a 6-digit code; the user types it on the sender. The
// code is proven with SRP-6a (RFC 5054 3072-bit group, SHA-256), never used
// as a key: a recorded exchange gives an attacker nothing to brute-force
// offline, and every online guess costs a full exchange the receiver sees
// and rate-limits. Once both sides know the code, each authenticates its
// long-term TLS key (SPKI) with an HMAC under a key derived from the SRP
// session key, so a man in the middle cannot swap either key in.

import Foundation
import Crypto
import SRP

enum Pairing {
    /// SRP identity `I`. Fixed: the code alone is the secret, and both ids
    /// travel (and are authenticated) separately.
    static let username = "opendisplay-pair"

    /// RFC 5054 3072-bit group with SHA-256.
    static let configuration = SRPConfiguration<SHA256>(.N3072)

    static let codeDigits = 6

    /// Codes the user types: uniform over 000000…999999.
    static func newCode() -> String {
        var rng = SystemRandomNumberGenerator()
        let value = Int.random(in: 0..<1_000_000, using: &rng)
        return String(format: "%06d", value)
    }

    /// Strip what users type around a code ("123 456", "123-456").
    static func normalizeCode(_ text: String) -> String? {
        let digits = text.filter(\.isNumber)
        guard digits.count == codeDigits, digits.allSatisfy(\.isASCII) else { return nil }
        return digits
    }

    /// The key that authenticates the long-term identities:
    /// HKDF-SHA256(ikm: H(PAD(S)), salt: "OpenDisplay-Pair-v1", info: "identity", L: 32).
    static func identityKey(sharedSecret: SRPKey) -> SymmetricKey {
        let padded = sharedSecret.with(padding: configuration.sizeN).bytes
        let k = SHA256.hash(data: padded)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(k)),
                                      salt: Data("OpenDisplay-Pair-v1".utf8),
                                      info: Data("identity".utf8),
                                      outputByteCount: 32)
    }

    enum Role: String {
        case sender, receiver
    }

    /// HMAC-SHA256(key, LP(role) || LP(id) || LP(spki)), where LP(x) is x
    /// prefixed with its length as a big-endian UInt32. The role label keeps
    /// a reflected MAC from verifying as the other side's.
    static func identityMAC(key: SymmetricKey, role: Role, id: String, spki: Data) -> Data {
        var message = Data()
        for field in [Data(role.rawValue.utf8), Data(id.utf8), spki] {
            var length = UInt32(field.count).bigEndian
            message.append(Data(bytes: &length, count: 4))
            message.append(field)
        }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    static func verifyIdentityMAC(_ mac: Data, key: SymmetricKey, role: Role,
                                  id: String, spki: Data) -> Bool {
        var message = Data()
        for field in [Data(role.rawValue.utf8), Data(id.utf8), spki] {
            var length = UInt32(field.count).bigEndian
            message.append(Data(bytes: &length, count: 4))
            message.append(field)
        }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: key)
    }

    enum Failure: Error, Equatable {
        case malformed          // a field is missing or not what it should be
        case wrongCode          // the client proof did not verify
        case badServerProof     // the receiver did not prove the code
        case badIdentity        // an identity MAC did not verify
    }

    // MARK: - Hex helpers (keys and proofs travel as lowercase hex)

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0, hex.count <= 4 * configuration.sizeN else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

/// The receiver's half of one pairing attempt (SRP server). One instance
/// per attempt: a fresh code, salt and key pair every time.
struct PairingServer {
    let code: String
    private let salt: [UInt8]
    private let verifier: SRPKey
    private let keys: SRPKeyPair
    private let server = SRPServer<SHA256>(configuration: Pairing.configuration)

    init(code: String = Pairing.newCode()) {
        self.code = code
        let client = SRPClient<SHA256>(configuration: Pairing.configuration)
        let (salt, verifier) = client.generateSaltAndVerifier(username: Pairing.username,
                                                              password: code, saltLength: 16)
        self.salt = salt
        self.verifier = verifier
        self.keys = server.generateKeys(verifier: verifier)
    }

    var saltHex: String { Pairing.hex(salt) }
    var publicKeyHex: String { Pairing.hex(keys.public.bytes) }

    struct Verified {
        let serverProofHex: String
        let identityKey: SymmetricKey
    }

    /// Check the sender's proof of the code. Throws `.wrongCode` when the
    /// code (or anything else in the exchange) does not match.
    func verify(clientPublicKeyHex: String, clientProofHex: String) throws -> Verified {
        guard let aBytes = Pairing.bytes(hex: clientPublicKeyHex), !aBytes.isEmpty,
              let proof = Pairing.bytes(hex: clientProofHex), proof.count == SHA256.byteCount else {
            throw Pairing.Failure.malformed
        }
        let clientKey = SRPKey(aBytes, padding: Pairing.configuration.sizeN)
        let secret: SRPKey
        do {
            secret = try server.calculateSharedSecret(clientPublicKey: clientKey,
                                                      serverKeys: keys, verifier: verifier)
        } catch {
            throw Pairing.Failure.malformed   // A ≡ 0 mod N
        }
        let serverProof: [UInt8]
        do {
            serverProof = try server.verifyClientProof(proof: proof, username: Pairing.username,
                                                       salt: salt, clientPublicKey: clientKey,
                                                       serverPublicKey: keys.public,
                                                       sharedSecret: secret)
        } catch {
            throw Pairing.Failure.wrongCode
        }
        return Verified(serverProofHex: Pairing.hex(serverProof),
                        identityKey: Pairing.identityKey(sharedSecret: secret))
    }
}

/// The sender's half of one pairing attempt (SRP client).
struct PairingClient {
    private let client = SRPClient<SHA256>(configuration: Pairing.configuration)
    private let keys: SRPKeyPair

    init() {
        keys = client.generateKeys()
    }

    var publicKeyHex: String { Pairing.hex(keys.public.bytes) }

    struct Proof {
        let clientProofHex: String
        let identityKey: SymmetricKey
        fileprivate let clientProof: [UInt8]
        fileprivate let sharedSecret: SRPKey
    }

    /// Answer the receiver's challenge with the code the user typed.
    func prove(code: String, saltHex: String, serverPublicKeyHex: String) throws -> Proof {
        guard let salt = Pairing.bytes(hex: saltHex), !salt.isEmpty,
              let bBytes = Pairing.bytes(hex: serverPublicKeyHex), !bBytes.isEmpty else {
            throw Pairing.Failure.malformed
        }
        let serverKey = SRPKey(bBytes, padding: Pairing.configuration.sizeN)
        let secret: SRPKey
        do {
            secret = try client.calculateSharedSecret(username: Pairing.username, password: code,
                                                      salt: salt, clientKeys: keys,
                                                      serverPublicKey: serverKey)
        } catch {
            throw Pairing.Failure.malformed   // B ≡ 0 mod N
        }
        let proof = client.calculateClientProof(username: Pairing.username, salt: salt,
                                                clientPublicKey: keys.public,
                                                serverPublicKey: serverKey,
                                                sharedSecret: secret)
        return Proof(clientProofHex: Pairing.hex(proof),
                     identityKey: Pairing.identityKey(sharedSecret: secret),
                     clientProof: proof, sharedSecret: secret)
    }

    /// The receiver proves it knew the code too; without this a stranger
    /// could accept any proof and hand over its own key.
    func verifyServer(proofHex: String, for proof: Proof) throws {
        guard let serverProof = Pairing.bytes(hex: proofHex) else { throw Pairing.Failure.malformed }
        do {
            try client.verifyServerProof(serverProof: serverProof, clientProof: proof.clientProof,
                                         clientPublicKey: keys.public, sharedSecret: proof.sharedSecret)
        } catch {
            throw Pairing.Failure.badServerProof
        }
    }
}
