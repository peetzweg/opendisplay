import Foundation

/// Owns the virtual-monitor serial independently of the current transport.
///
/// macOS keys saved display state — arrangement, resolution, the hostile
/// "never come online again" state `MacSender.setupExtend` probes around —
/// on vendor/product/serial. Deriving that serial from the connection's
/// session id therefore hands one physical device two unrelated identities,
/// one for USB and one for WiFi. New receivers report a stable per-install
/// id in `PhoneInfo.id`, which `DisplayArrangement` already trusts as the
/// device key; using it here puts both transports on one identity.
enum DisplayIdentity {
    /// FNV-1a over the install id. Namespaced so the value cannot collide
    /// with the session-derived serials older receivers still get.
    static func serial(for deviceID: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in "device:\(deviceID)".utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }
}
