import Foundation
import Security
import CommonCrypto

/// AES-128-CTR frame payload encryption and CSPRNG key generation for Google Cast Mirroring.
enum CastCrypto {
    /// Generates cryptographically secure random bytes via `SecRandomCopyBytes`,
    /// falling back to `SystemRandomNumberGenerator` if needed.
    static func randomBytes(count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess {
            return bytes
        }
        var rng = SystemRandomNumberGenerator()
        for i in 0..<count {
            bytes[i] = UInt8.random(in: .min ... .max, using: &rng)
        }
        return bytes
    }

    /// Encrypts an encoded video frame payload using AES-128-CTR with a `frameId`-derived nonce.
    /// Fails closed (`nil`) when key/mask sizes are invalid or CommonCrypto fails, so plaintext
    /// video frames are never transmitted on the wire.
    static func encryptPayload(frameId: UInt32, inData: Data,
                               aesKey: [UInt8], aesIvMask: [UInt8]) -> Data? {
        guard aesKey.count == 16, aesIvMask.count == 16 else { return nil }
        guard !inData.isEmpty else { return Data() }

        var nonce = [UInt8](repeating: 0, count: 16)
        nonce[8] = UInt8((frameId >> 24) & 0xFF)
        nonce[9] = UInt8((frameId >> 16) & 0xFF)
        nonce[10] = UInt8((frameId >> 8) & 0xFF)
        nonce[11] = UInt8(frameId & 0xFF)
        for i in 0..<16 {
            nonce[i] ^= aesIvMask[i]
        }

        var cryptor: CCCryptorRef?
        let createStatus = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt),
            CCMode(kCCModeCTR),
            CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding),
            nonce,
            aesKey,
            16,
            nil, 0, 0,
            CCModeOptions(kCCModeOptionCTR_BE),
            &cryptor
        )
        guard createStatus == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        var outData = Data(count: inData.count)
        var moved = 0
        let updateStatus = inData.withUnsafeBytes { inPtr in
            outData.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, inData.count,
                                outPtr.baseAddress, inData.count, &moved)
            }
        }
        guard updateStatus == kCCSuccess, moved == inData.count else { return nil }
        return outData
    }
}
