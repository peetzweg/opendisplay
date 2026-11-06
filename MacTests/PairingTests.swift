import XCTest
import Crypto

/// Code pairing crypto (Shared/Pairing.swift, PROTOCOL.md 11.3). Network-free
/// and Keychain-free: the SRP exchange and identity MACs run in memory.
final class PairingTests: XCTestCase {
    private let senderSPKI = Data((0..<91).map { UInt8($0) })
    private let receiverSPKI = Data((0..<91).map { UInt8(255 - $0) })

    func testRightCodePairsAndBothSidesAgreeOnTheIdentityKey() throws {
        let server = PairingServer(code: "042137")
        let client = PairingClient()
        let proof = try client.prove(code: "042137", saltHex: server.saltHex,
                                     serverPublicKeyHex: server.publicKeyHex)
        let verified = try server.verify(clientPublicKeyHex: client.publicKeyHex,
                                         clientProofHex: proof.clientProofHex)
        XCTAssertNoThrow(try client.verifyServer(proofHex: verified.serverProofHex, for: proof))

        let senderMAC = Pairing.identityMAC(key: proof.identityKey, role: .sender, id: "mac-1", spki: senderSPKI)
        XCTAssertTrue(Pairing.verifyIdentityMAC(senderMAC, key: verified.identityKey, role: .sender,
                                                id: "mac-1", spki: senderSPKI))
        let receiverMAC = Pairing.identityMAC(key: verified.identityKey, role: .receiver, id: "ipad-1", spki: receiverSPKI)
        XCTAssertTrue(Pairing.verifyIdentityMAC(receiverMAC, key: proof.identityKey, role: .receiver,
                                                id: "ipad-1", spki: receiverSPKI))
    }

    func testWrongCodeIsRejectedByTheReceiver() throws {
        let server = PairingServer(code: "111111")
        let client = PairingClient()
        let proof = try client.prove(code: "111112", saltHex: server.saltHex,
                                     serverPublicKeyHex: server.publicKeyHex)
        XCTAssertThrowsError(try server.verify(clientPublicKeyHex: client.publicKeyHex,
                                               clientProofHex: proof.clientProofHex)) {
            XCTAssertEqual($0 as? Pairing.Failure, .wrongCode)
        }
    }

    /// A stranger who does not know the code cannot pass as the receiver:
    /// its server proof fails on the sender.
    func testReceiverWithoutTheCodeCannotProveItself() throws {
        let impostor = PairingServer(code: "999999")
        let client = PairingClient()
        let proof = try client.prove(code: "123456", saltHex: impostor.saltHex,
                                     serverPublicKeyHex: impostor.publicKeyHex)
        // The impostor cannot verify the proof, so it has no M2 to send; any
        // made-up value must fail.
        let fakeM2 = Pairing.hex([UInt8](repeating: 0xAB, count: 32))
        XCTAssertThrowsError(try client.verifyServer(proofHex: fakeM2, for: proof)) {
            XCTAssertEqual($0 as? Pairing.Failure, .badServerProof)
        }
    }

    func testSwappedKeyOrIdOrReflectedRoleFailsTheIdentityMAC() throws {
        let server = PairingServer(code: "555000")
        let client = PairingClient()
        let proof = try client.prove(code: "555000", saltHex: server.saltHex,
                                     serverPublicKeyHex: server.publicKeyHex)
        let verified = try server.verify(clientPublicKeyHex: client.publicKeyHex,
                                         clientProofHex: proof.clientProofHex)
        let mac = Pairing.identityMAC(key: proof.identityKey, role: .sender, id: "mac-1", spki: senderSPKI)
        var otherKey = senderSPKI
        otherKey[0] ^= 1
        XCTAssertFalse(Pairing.verifyIdentityMAC(mac, key: verified.identityKey, role: .sender,
                                                 id: "mac-1", spki: otherKey))
        XCTAssertFalse(Pairing.verifyIdentityMAC(mac, key: verified.identityKey, role: .sender,
                                                 id: "mac-2", spki: senderSPKI))
        XCTAssertFalse(Pairing.verifyIdentityMAC(mac, key: verified.identityKey, role: .receiver,
                                                 id: "mac-1", spki: senderSPKI))
        // A key from a different session (another code) does not verify.
        let other = PairingServer(code: "555000")
        let otherClient = PairingClient()
        let otherProof = try otherClient.prove(code: "555000", saltHex: other.saltHex,
                                               serverPublicKeyHex: other.publicKeyHex)
        XCTAssertFalse(Pairing.verifyIdentityMAC(mac, key: otherProof.identityKey, role: .sender,
                                                 id: "mac-1", spki: senderSPKI))
    }

    /// Field boundaries are length-prefixed: moving bytes between id and key
    /// changes the MAC.
    func testFieldBoundariesAreUnambiguous() {
        let key = SymmetricKey(size: .bits256)
        let a = Pairing.identityMAC(key: key, role: .sender, id: "ab", spki: Data("c".utf8))
        let b = Pairing.identityMAC(key: key, role: .sender, id: "a", spki: Data("bc".utf8))
        XCTAssertNotEqual(a, b)
    }

    func testMalformedKeysAreRejectedNotCrashed() {
        let server = PairingServer(code: "123456")
        XCTAssertThrowsError(try server.verify(clientPublicKeyHex: "zz", clientProofHex: "00"))
        // A ≡ 0 mod N would make the shared secret predictable.
        let zero = Pairing.hex([UInt8](repeating: 0, count: Pairing.configuration.sizeN))
        let anyProof = Pairing.hex([UInt8](repeating: 1, count: 32))
        XCTAssertThrowsError(try server.verify(clientPublicKeyHex: zero, clientProofHex: anyProof)) {
            XCTAssertEqual($0 as? Pairing.Failure, .malformed)
        }
        let client = PairingClient()
        XCTAssertThrowsError(try client.prove(code: "123456", saltHex: server.saltHex, serverPublicKeyHex: zero))
    }

    func testCodesAreSixDigitsAndTypingIsForgiving() {
        for _ in 0..<200 {
            let code = Pairing.newCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy { $0.isASCII && $0.isNumber })
        }
        XCTAssertEqual(Pairing.normalizeCode(" 123 456 "), "123456")
        XCTAssertEqual(Pairing.normalizeCode("123-456"), "123456")
        XCTAssertNil(Pairing.normalizeCode("12345"))
        XCTAssertNil(Pairing.normalizeCode("1234567"))
        XCTAssertNil(Pairing.normalizeCode("١٢٣٤٥٦"))   // non-ASCII digits
    }
}
