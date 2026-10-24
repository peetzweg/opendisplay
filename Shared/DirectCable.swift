// Compiled into the Mac sender, the Mac receiver and iOS (Shared/).

import Foundation
import Network

/// Whether a connection rides the direct host-to-host cable (USB-C or
/// Thunderbolt between two Macs). That link hands out nothing but
/// link-local addresses and never touches WiFi. A link-local peer alone is
/// not proof: every Ethernet segment has fe80 addresses too. What sets the
/// cable apart is that the local interface has no routable address at all.
/// Remaining gap: a switch with no DHCP server and no IPv6 router looks
/// exactly like the cable.
enum DirectCable {
    /// The path is wired, the far end is link-local, and the local interface
    /// carrying it holds only link-local addresses. Judged from this side of
    /// the connection only: nothing the peer says can change it.
    static func carries(_ conn: NWConnection) -> Bool {
        guard let path = conn.currentPath,
              let interface = path.availableInterfaces.first else { return false }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.cellular)
            || path.usesInterfaceType(.loopback) { return false }
        return isLinkLocal(path.remoteEndpoint ?? conn.endpoint)
            && onlyLinkLocal(addresses(of: interface.name))
    }

    /// A local interface is the host-to-host link: wired and holding only
    /// link-local addresses. Used to spot a Bonjour record seen over the
    /// cable (NWBrowser.Result.interfaces).
    static func isDirectLink(_ interface: NWInterface) -> Bool {
        // anpi* is Apple's internal peripheral link: link-local and wired,
        // and a Mac receiver's record shows up on it too, but it completes
        // TCP handshakes without carrying the stream (see the matching
        // exclusion in StreamReceiver). The real cable is a plain en/bridge.
        interface.type == .wiredEthernet && !interface.name.hasPrefix("anpi")
            && onlyLinkLocal(addresses(of: interface.name))
    }

    /// True for a non-empty list of nothing but link-local addresses; one
    /// routable address (DHCP lease, IPv6 prefix) means an ordinary network.
    static func onlyLinkLocal(_ addresses: [String]) -> Bool {
        !addresses.isEmpty && addresses.allSatisfy { addr in
            if let v4 = IPv4Address(addr) { return v4.isLinkLocal }
            if let v6 = IPv6Address(addr) { return v6.isLinkLocal }
            return false
        }
    }

    /// Every IPv4/IPv6 address on the named interface, scope ids stripped.
    private static func addresses(of name: String) -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard String(cString: ifa.ifa_name) == name, let sa = ifa.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = family == UInt8(AF_INET)
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addr = String(cString: host)
            result.append(String(addr.split(separator: "%").first ?? Substring(addr)))
        }
        return result
    }

    /// fe80::/10 or 169.254/16.
    static func isLinkLocal(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let addr): return addr.isLinkLocal
        case .ipv6(let addr): return addr.isLinkLocal
        case .name(let name, _):
            // Literal probe targets dial as names ("fe80::1%en5").
            let bare = name.lowercased()
            return bare.hasPrefix("169.254.") || bare.hasPrefix("fe80:")
        @unknown default: return false
        }
    }
}
