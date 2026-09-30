// Compiled into the Mac sender, the Mac receiver and iOS (Shared/).

import Foundation
import Network

/// Whether a connection rides the direct host-to-host cable (USB-C or
/// Thunderbolt between two Macs). That link hands out nothing but
/// link-local addresses and never touches WiFi. Address shape alone is not
/// proof (a DHCP-less switch hands 169.254 to everyone), so callers pair it
/// with what they know about the peer.
enum DirectCable {
    /// The path is wired and the far end is link-local. Judged from this
    /// side of the connection only: nothing the peer says can change it.
    static func carries(_ conn: NWConnection) -> Bool {
        guard let path = conn.currentPath else { return false }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.cellular)
            || path.usesInterfaceType(.loopback) { return false }
        return isLinkLocal(path.remoteEndpoint ?? conn.endpoint)
    }

    /// fe80::/10 or 169.254/16.
    static func isLinkLocal(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let addr): return addr.isLinkLocal
        case .ipv6(let addr): return addr.isLinkLocal
        case .name(let name, _):
            let bare = name.lowercased()
            return bare.hasPrefix("169.254.") || bare.hasPrefix("fe80:")
        @unknown default: return false
        }
    }
}
