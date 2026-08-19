import Foundation
import Network
import SystemConfiguration

/// Why WiFi mode can't see a device.
///
/// These need telling apart because the remedies have nothing in common, and
/// until now every empty device list was blamed on missing Local Network
/// permission (issue #125) — including on networks where no permission grant
/// could ever have helped.
///
/// The case worth detecting is `.blocked`. Guest WiFi, hotel and conference
/// APs, and many corporate networks run *client isolation* (a.k.a. AP
/// isolation): each client's traffic is forwarded upstream, and everything
/// sideways to another client on the same subnet is dropped. The internet keeps
/// working perfectly, so nothing looks wrong, while Bonjour advertisements never
/// arrive and a direct dial to the device can never land. Apple's own Continuity
/// features (Handoff, Universal Clipboard) break on the same networks, which is
/// usually the tell a user has already noticed without connecting it to this.
enum LocalNetworkVerdict: Equatable {
    /// Not probed yet, or the answer wouldn't be trustworthy. See
    /// `LocalNetworkProbe.gateway` for the cases we decline to judge.
    case unknown
    /// The router answers us, so client-to-client traffic is plausible. A device
    /// that still doesn't appear is missing permission, on another network, or
    /// not running the app.
    case ok
    /// No usable network at all — nothing to diagnose beyond "join a WiFi".
    case offline
    /// The internet works but our own subnet is silent: not one packet reaches
    /// the router, let alone a peer. Named for the observation rather than a
    /// cause, because two causes produce it — see `advice`.
    case blocked

    /// One line for the Devices section while WiFi discovery is coming up empty.
    ///
    /// Short on purpose: the point is to stop someone hunting for a setting that
    /// cannot help and put them on a cable. The hedge this line drops (we prove
    /// the app reaches nothing on this subnet, but cannot prove *why* without a
    /// peer to dial, and macOS 15's Local Network gate produces the same
    /// silence) lives on the Local Network row right below it, and in full in
    /// the README.
    var advice: String? {
        switch self {
        case .unknown, .ok:
            return nil
        case .offline:
            return "This Mac isn't on a WiFi network."
        // "Won't work", not "degraded": under client isolation WiFi mode does
        // not work slowly, it does not work at all, and hedging that only keeps
        // someone retrying. No USB hint either — the empty-list row directly
        // above already says to plug one in.
        case .blocked:
            return "Locked-down WiFi detected — wireless connectivity won't work."
        }
    }
}

/// What a single reachability question came back with. `inconclusive` exists so
/// "we were not allowed to ask" never gets read as "nobody answered".
enum ProbeOutcome: Equatable {
    /// Something replied — a pong, a connect, or a refusal. All prove reach.
    case answered
    /// The probe went out and nothing came back inside the window.
    case silent
    /// The probe never left this Mac: no socket, no route, or the OS refused.
    case inconclusive
}

/// The raw observations behind a verdict. Kept apart from the verdict so the
/// decision is a pure function over them, and so the log line says *why*.
struct LocalNetworkProbe: Equatable {
    /// Reachability of this link's own router. `nil` when there is no router we
    /// are willing to judge by: no IPv4 default route, a default route belonging
    /// to a VPN tunnel rather than the LAN we'd reach a device over, or probes
    /// that never made it off the machine.
    var gateway: Bool?
    var internet: Bool

    /// Claiming the network drops peer traffic is only supportable when traffic
    /// clearly leaves this Mac and comes back — otherwise a plain outage looks
    /// identical.
    ///
    /// Deliberately conservative: anything short of "internet fine, router mute"
    /// reports `.ok` or `.unknown` rather than accusing the network, because a
    /// false "your WiFi is locked down" sends people hunting for a router
    /// setting that was never the problem.
    var verdict: LocalNetworkVerdict {
        switch (gateway, internet) {
        case (true, _):       return .ok       // the LAN answers; internet is beside the point
        case (false, true):   return .blocked
        case (false, false):  return .offline
        case (nil, false):    return .offline
        case (nil, true):     return .unknown  // routed somewhere we can't reason about
        }
    }
}

/// Probes whether this Mac can reach anything on its own subnet, so the UI can
/// say "this network blocks it" instead of leaving the user to guess.
///
/// Runs at launch, on network changes, and when the panel opens. No polling
/// timer: the answer cannot change without an `NWPathMonitor` update or a user
/// action, and probes cost packets.
@MainActor
final class NetworkDiagnostics: ObservableObject {
    /// One instance for the app: `ContentView` is built twice (menu bar popover
    /// and control window), and two probers would double the traffic while
    /// disagreeing with each other in the two places the answer is shown.
    static let shared = NetworkDiagnostics()

    @Published private(set) var verdict: LocalNetworkVerdict = .unknown

    private let monitor = NWPathMonitor()
    /// A cancellable handle rather than a self-rescheduling chain, so a network
    /// flap landing mid-probe replaces the in-flight probe instead of racing it.
    private var probeTask: Task<Void, Never>?
    private var lastProbe: Date?
    /// A path change arrived while a probe was in flight. Coalesced into one
    /// re-run rather than a restart, see `probe(force:)`.
    private var rerunRequested = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.probe(force: true) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    deinit {
        monitor.cancel()
        probeTask?.cancel()
    }

    /// Re-probe unless a fresh answer is already in hand. `force` is for events
    /// that invalidate the answer (a path change), not for UI refreshes.
    func probe(force: Bool = false) {
        if !force, verdict != .unknown, let lastProbe,
           Date().timeIntervalSince(lastProbe) < 30 { return }
        // Never restart a probe that is already running. A probe takes seconds
        // on the very networks this exists to detect (every dial has to time
        // out), and `NWPathMonitor` fires on any route change, VPN churn
        // included. Cancelling and restarting on each one would let a flapping
        // path outrun the probe forever, so it would never reach a verdict at
        // all. Let it finish and repeat once afterwards instead.
        guard probeTask == nil else {
            if force { rerunRequested = true }
            return
        }
        probeTask = Task { [weak self] in
            let probe = await LocalNetworkProber.run()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.probeTask = nil
                self.lastProbe = Date()
                let verdict = probe.verdict
                // Logged on change only, which still means once at launch (the
                // first probe leaves `.unknown`): an attached log should answer
                // "was this one of those networks?" without a reproduction.
                if verdict != self.verdict {
                    let gateway = probe.gateway.map { $0 ? "reachable" : "silent" } ?? "not judged"
                    Log.info("network: \(verdict) — gateway \(gateway), internet \(probe.internet ? "up" : "down")")
                }
                self.verdict = verdict
                if self.rerunRequested {
                    self.rerunRequested = false
                    self.probe(force: true)
                }
            }
        }
    }
}

/// The probing itself: off the main actor, free of UI state, and driven only by
/// its inputs so it can be exercised on its own.
enum LocalNetworkProber {
    /// Public anycast resolvers, used only to tell "the network is broken" from
    /// "the network works but won't carry traffic sideways".
    private static let internetHosts = ["1.1.1.1", "9.9.9.9"]
    /// Ports a router is most likely to answer on. A refusal (RST) proves
    /// reachability as well as a successful connect does.
    private static let gatewayPorts: [UInt16] = [80, 443, 53]

    static func run() async -> LocalNetworkProbe {
        async let internet = reach(internetHosts, ports: [443])
        guard let gateway = lanGateway() else {
            return LocalNetworkProbe(gateway: nil, internet: await internet == .answered)
        }
        async let reachable = reach([gateway], ports: gatewayPorts)
        return LocalNetworkProbe(
            gateway: await reachable.reachability,
            internet: await internet == .answered)
    }

    /// Ping first (cheapest, and the thing a router is likeliest to answer),
    /// then TCP as the backup for routers configured to drop ICMP. Stops at the
    /// first probe that gets an answer.
    private static func reach(_ hosts: [String], ports: [UInt16]) async -> ProbeOutcome {
        var outcome = ProbeOutcome.inconclusive
        for host in hosts {
            for probe in [ICMPProbe.echo(host)] + ports.map({ TCPProbe.answers(host, port: $0) }) {
                switch await probe() {
                case .answered: return .answered
                case .silent: outcome = .silent      // sticky: one real timeout is enough
                case .inconclusive: break
                }
            }
        }
        return outcome
    }

    /// The default router, but only when it sits on a subnet we share with a
    /// physical interface.
    ///
    /// The subnet check is what keeps a VPN honest: with a full-tunnel VPN up
    /// (Tailscale's "route all traffic", any corporate client) the default route
    /// points into a `utun`, and probing that says nothing about whether the
    /// WiFi we'd reach an iPad over carries client-to-client traffic. Better to
    /// return nil and stay quiet than to guess.
    static func lanGateway() -> String? {
        guard let router = defaultRouter() else { return nil }
        return physicalSubnets().contains(where: { $0.contains(router) }) ? router : nil
    }

    private static func defaultRouter() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "OpenDisplay" as CFString, nil, nil),
              let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any]
        else { return nil }
        return ipv4["Router"] as? String
    }

    /// IPv4 subnets of the physical interfaces (`en*`, `bridge*`). Tunnels and
    /// loopback are excluded on purpose — see `lanGateway()`.
    private static func physicalSubnets() -> [IPv4Subnet] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var subnets: [IPv4Subnet] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.ifa_netmask,
                  let name = ifa.ifa_name.map({ String(cString: $0) }),
                  name.hasPrefix("en") || name.hasPrefix("bridge")
            else { continue }
            subnets.append(IPv4Subnet(address: addr.pointee.ipv4, mask: mask.pointee.ipv4))
        }
        return subnets
    }
}

extension ProbeOutcome {
    /// As `LocalNetworkProbe.gateway` wants it: nil when we never got to ask.
    var reachability: Bool? {
        switch self {
        case .answered: return true
        case .silent: return false
        case .inconclusive: return nil
        }
    }
}

/// An IPv4 address plus mask, for asking "is this router on my link?".
struct IPv4Subnet: Equatable {
    let address: UInt32
    let mask: UInt32

    func contains(_ host: String) -> Bool {
        guard let host = IPv4Subnet.parse(host) else { return false }
        return host & mask == address & mask
    }

    static func parse(_ text: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }
}

private extension sockaddr {
    /// Host-order IPv4 address of a `sockaddr` already known to be `AF_INET`.
    var ipv4: UInt32 {
        withUnsafePointer(to: self) { ptr in
            ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
        }
    }
}

/// Minimal ICMP echo. `SOCK_DGRAM`/`IPPROTO_ICMP` needs no privileges and no
/// entitlement (the Mac app is not sandboxed), which is why this is the primary
/// probe: a router that answers nothing else usually still answers a ping.
enum ICMPProbe {
    /// Returns the probe as a thunk so callers can line ICMP and TCP attempts up
    /// in one list and run them until something answers.
    static func echo(_ host: String, timeout: TimeInterval = 1.2) -> () async -> ProbeOutcome {
        {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: send(host, timeout: timeout))
                }
            }
        }
    }

    private static func send(_ host: String, timeout: TimeInterval) -> ProbeOutcome {
        guard let target = IPv4Subnet.parse(host) else { return .inconclusive }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return .inconclusive }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout),
                         tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // The token identifies our reply. On a DGRAM ICMP socket the kernel
        // rewrites the echo identifier, so matching on the id would never work.
        let token = "OpenDisplay-\(UInt32.random(in: .min ... .max))"
        let packet = echoRequest(payload: Array(token.utf8))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = target.bigEndian
        let addrLength = socklen_t(MemoryLayout<sockaddr_in>.size)

        let sent = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                packet.withUnsafeBytes {
                    sendto(fd, $0.baseAddress, packet.count, 0, sa, addrLength)
                }
            }
        }
        // A refused send is this machine's own doing — no route, or macOS 15's
        // Local Network gate — and says nothing about the network. Reporting it
        // as silence would let a denied permission masquerade as a hostile AP.
        guard sent == packet.count else { return .inconclusive }

        // One read is enough: unrelated ICMP on this socket is rare, and a miss
        // only costs us the TCP fallback.
        var buffer = [UInt8](repeating: 0, count: 1500)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else { return .silent }
        return isEchoReply(Array(buffer[0 ..< received]), token: token) ? .answered : .silent
    }

    /// An echo request (type 8) with its checksum filled in.
    static func echoRequest(payload: [UInt8], sequence: UInt16 = 1) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0, 0, 0]
        packet += [UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        packet += payload
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    /// macOS hands back the whole datagram *including* the IP header, unlike a
    /// raw socket on some other platforms — so step over it before reading the
    /// ICMP type.
    static func isEchoReply(_ datagram: [UInt8], token: String) -> Bool {
        guard let first = datagram.first, first >> 4 == 4 else { return false }
        let headerLength = Int(first & 0x0F) * 4
        guard datagram.count > headerLength, datagram[headerLength] == 0 else { return false }
        return datagram.suffix(from: headerLength).contains(subsequence: Array(token.utf8))
    }

    /// Standard internet checksum: one's complement of the one's-complement sum
    /// of the 16-bit words.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return UInt16(truncatingIfNeeded: ~sum)
    }
}

/// A TCP dial used only as a reachability question, never to move data: a
/// refusal answers it as well as a connect does. Backs up the ping for routers
/// configured to drop ICMP.
enum TCPProbe {
    private static let queue = DispatchQueue(label: "network-probe", qos: .utility)

    /// Errors meaning the dial never reached the wire, so the network is not on
    /// trial for them.
    private static let localFailures: [POSIXErrorCode] =
        [.EPERM, .EACCES, .ENETDOWN, .ENETUNREACH, .EADDRNOTAVAIL]

    static func answers(_ host: String, port: UInt16,
                        timeout: TimeInterval = 1.2) -> () async -> ProbeOutcome {
        {
            guard let port = NWEndpoint.Port(rawValue: port) else { return .inconclusive }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            return await withCheckedContinuation { continuation in
                // Whichever comes first — a conclusive state or the deadline —
                // wins and tears the connection down. Racing this as two child
                // tasks would strand the continuation instead:
                // `withCheckedContinuation` does not resume on cancellation, so
                // cancelling the loser leaks it and the probe never returns.
                let once = OnceBox(continuation) {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.resume(.answered)
                    // A RST means the host is there and said no, which answers
                    // the question. NWConnection surfaces it as `.waiting` and
                    // would keep retrying, so settle here rather than waiting
                    // for `.failed`.
                    case .waiting(let error), .failed(let error):
                        if error == .posix(.ECONNREFUSED) {
                            once.resume(.answered)
                        } else if case .posix(let code) = error, localFailures.contains(code) {
                            once.resume(.inconclusive)
                        } else {
                            once.resume(.silent)
                        }
                    case .cancelled:
                        once.resume(.inconclusive)
                    case .setup, .preparing:
                        break
                    @unknown default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { once.resume(.silent) }
            }
        }
    }
}

/// Guards a continuation several callbacks could otherwise resume twice, and
/// runs its cleanup exactly once alongside the winning resume.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProbeOutcome, Never>?
    private let cleanup: () -> Void

    init(_ continuation: CheckedContinuation<ProbeOutcome, Never>,
         cleanup: @escaping () -> Void) {
        self.continuation = continuation
        self.cleanup = cleanup
    }

    func resume(_ value: ProbeOutcome) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        pending.resume(returning: value)
        cleanup()
    }
}

private extension Collection where Element: Equatable {
    /// Substring search over bytes, for spotting our token in an ICMP payload.
    func contains(subsequence needle: [Element]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        var start = startIndex
        while let match = self[start...].firstIndex(of: needle[0]) {
            if self[match...].starts(with: needle) { return true }
            guard match < endIndex else { break }
            start = index(after: match)
        }
        return false
    }
}
