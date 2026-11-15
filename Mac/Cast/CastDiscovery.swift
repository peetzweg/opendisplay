import Foundation
import Network
import Combine
import AppKit

/// Video-capable Google Cast receiver discovered on the local network.
struct CastDevice: Identifiable, Hashable, Equatable {
    let id: String              // unique device ID from TXT ("id")
    let name: String            // friendly name ("fn"), e.g. "Living Room TV"
    let model: String           // model ("md"), e.g. "Chromecast", "Google TV Streamer"
    let endpoint: NWEndpoint    // TLS control endpoint (typically :8009)
    let host: String            // resolved IPv4 or service hostname
    let port: UInt16            // TLS control port (default 8009)
    let supportsVideo: Bool     // capability bit 0 ("ca" & 0x01)

    var displayLabel: String {
        if !model.isEmpty && model != "Chromecast" {
            return "\(name) (\(model))"
        }
        return name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CastDevice, rhs: CastDevice) -> Bool {
        lhs.id == rhs.id
    }
}

/// Discovers video-capable Google Cast receivers (`_googlecast._tcp`) via Bonjour
/// and unicast mDNS probes for receivers whose Wi-Fi stack filters idle multicast.
@MainActor
final class CastDiscovery: ObservableObject {
    static let shared = CastDiscovery()

    @Published private(set) var devices: [CastDevice] = []
    @Published private(set) var isSearching = false

    private var browser: NWBrowser?
    private var browserRestart: Task<Void, Never>?
    private var browserRestartDelay: Duration = .seconds(2)
    private let queue = DispatchQueue(label: "cast.discovery")
    private var cachedDevices: [String: (device: CastDevice, lastSeen: Date)] = [:]
    private var pruneTimer: Timer?
    private let deviceTTL: TimeInterval = 600   // 10 min keeps idle living-room TVs listed
    private var isScreenLocked = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var lastRestartTime = Date()

    private var knownIPs: Set<String> = []
    private let knownIPsKey = "castKnownIPs"
    static let mDNSQueryData = Data([
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x0b, 0x5f, 0x67, 0x6f, 0x6f, 0x67, 0x6c, 0x65, 0x63, 0x61, 0x73, 0x74, // _googlecast
        0x04, 0x5f, 0x74, 0x63, 0x70,                                           // _tcp
        0x05, 0x6c, 0x6f, 0x63, 0x61, 0x6c, 0x00,                               // local
        0x00, 0x0c,                                                             // PTR (12)
        0x80, 0x01                                                              // IN + QU unicast response
    ])

    init() {
        loadKnownIPs()
    }

    func start() {
        guard !isSearching else { return }
        isSearching = true
        setupSleepWakeObservers()
        startBrowser()
        probeKnownDevices()

        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneOldDevices()
                self?.probeKnownDevices()
            }
        }
    }

    private func startBrowser() {
        guard browser == nil else { return }
        lastRestartTime = Date()

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil)
        let params = NWParameters.tcp
        params.preferNoProxies = true
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            DispatchQueue.main.async {
                guard let self, let browser, self.browser === browser else { return }
                self.handleBrowseResults(results)
            }
        }

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            DispatchQueue.main.async {
                guard let self, let browser, self.browser === browser else { return }
                self.browserStateChanged(state)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            browserRestartDelay = .seconds(2)
            Log.info("cast discovery: browsing for _googlecast._tcp")
        case .waiting(let error):
            Log.info("cast discovery: waiting (\(error))")
        case .failed(let error):
            let delay = browserRestartDelay
            browserRestartDelay = min(delay * 2, .seconds(60))
            browser?.cancel()
            browser = nil
            browserRestart?.cancel()
            browserRestart = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, self.isSearching else { return }
                self.startBrowser()
            }
            Log.info("cast discovery: failed (\(error)), restarting in \(delay.components.seconds)s")
        default:
            break
        }
    }

    func restartBrowser() {
        guard isSearching else { return }
        browserRestart?.cancel()
        browserRestart = nil
        browser?.cancel()
        browser = nil
        startBrowser()
        probeKnownDevices()
    }

    private func setupSleepWakeObservers() {
        guard workspaceObservers.isEmpty else { return }

        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isScreenLocked = true }
        })
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isScreenLocked = true }
        })
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWakeOrUnlock() }
        })
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWakeOrUnlock() }
        })

        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isScreenLocked = true }
        })
        distributedObservers.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWakeOrUnlock() }
        })
    }

    private func handleWakeOrUnlock() {
        isScreenLocked = false
        let now = Date()
        for (id, val) in cachedDevices {
            cachedDevices[id] = (val.device, now)
        }
        pruneOldDevices()
        restartBrowser()
    }

    func stop() {
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()

        for obs in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        distributedObservers.removeAll()

        browserRestart?.cancel()
        browserRestart = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
        browser?.cancel()
        browser = nil
        isSearching = false
        cachedDevices.removeAll()
        devices.removeAll()
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var parsedDevices: [CastDevice] = []

        for result in results {
            var txtRecord: NWTXTRecord?
            if case .bonjour(let txt) = result.metadata {
                txtRecord = txt
            }

            let friendlyName = txtRecord?["fn"] ?? {
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return "Cast TV"
            }()
            let modelName = txtRecord?["md"] ?? "Chromecast"
            let deviceId = txtRecord?["id"] ?? {
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return UUID().uuidString
            }()

            // Capability bitmask ("ca"): bit 0 (0x01) = video output; audio-only speakers clear bit 0.
            var supportsVideo = true
            if let caStr = txtRecord?["ca"], let ca = UInt32(caStr) {
                supportsVideo = (ca & 0x01) != 0
            }
            guard supportsVideo else { continue }

            var hostStr = ""
            var portNum: UInt16 = 8009

            switch result.endpoint {
            case .hostPort(let host, let port):
                switch host {
                case .ipv4(let ipv4): hostStr = "\(ipv4)"
                case .ipv6(let ipv6): hostStr = "\(ipv6)"
                case .name(let name, _): hostStr = name
                @unknown default: hostStr = "cast-device.local"
                }
                portNum = port.rawValue
            case .service(let name, let type, let domain, _):
                hostStr = "\(name).\(type).\(domain)"
            default:
                break
            }

            parsedDevices.append(CastDevice(
                id: deviceId,
                name: friendlyName,
                model: modelName,
                endpoint: result.endpoint,
                host: hostStr,
                port: portNum,
                supportsVideo: supportsVideo
            ))
        }

        let now = Date()
        for device in parsedDevices {
            // Preserve a resolved LAN IPv4 if Bonjour re-advertises a service name for the same ID.
            var merged = device
            if Self.sanitizeIPv4(device.host) == nil,
               let existing = cachedDevices[device.id]?.device,
               let validIP = Self.sanitizeIPv4(existing.host) {
                merged = CastDevice(
                    id: device.id,
                    name: device.name,
                    model: device.model,
                    endpoint: device.endpoint,
                    host: validIP,
                    port: device.port,
                    supportsVideo: device.supportsVideo
                )
            }
            cachedDevices[device.id] = (merged, now)
            recordDeviceIP(merged.host)
        }

        pruneOldDevices()
    }

    private func pruneOldDevices() {
        guard !isScreenLocked else { return }

        let now = Date()
        cachedDevices = cachedDevices.filter { now.timeIntervalSince($0.value.lastSeen) < deviceTTL }

        let uniqueDevices = cachedDevices.values.map(\.device)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if devices != uniqueDevices {
            devices = uniqueDevices
            let labels = uniqueDevices.map(\.displayLabel).joined(separator: ", ")
            Log.info("cast discovery: \(uniqueDevices.count) receiver(s) [\(labels)]")
        }

        if uniqueDevices.isEmpty && isSearching && now.timeIntervalSince(lastRestartTime) >= 45 {
            restartBrowser()
        }
    }

    // MARK: - Unicast mDNS Prober

    /// Validates and canonicalizes a LAN IPv4 address string, stripping any `%interface` scope
    /// suffix and rejecting loopback, unspecified, broadcast, or multicast addresses.
    nonisolated static func sanitizeIPv4(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hostOnly = trimmed.split(separator: "%", maxSplits: 1).first.map(String.init) ?? trimmed
        guard let addr = IPv4Address(hostOnly) else { return nil }
        let b = addr.rawValue
        guard b.count == 4 else { return nil }
        if b[0] == 0 || b[0] == 127 || b[0] >= 224 { return nil }
        return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
    }

    private func loadKnownIPs() {
        guard let saved = UserDefaults.standard.stringArray(forKey: knownIPsKey) else { return }
        for raw in saved {
            if let ip = Self.sanitizeIPv4(raw) {
                knownIPs.insert(ip)
            }
        }
    }

    func recordDeviceIP(_ raw: String) {
        guard let ip = Self.sanitizeIPv4(raw) else { return }
        if knownIPs.insert(ip).inserted {
            UserDefaults.standard.set(Array(knownIPs).sorted(), forKey: knownIPsKey)
        }
    }

    func probeKnownDevices() {
        for ip in knownIPs {
            probeDevice(ip: ip)
        }
    }

    private func probeDevice(ip: String) {
        let nwHost = NWEndpoint.Host(ip)
        guard let nwPort = NWEndpoint.Port(rawValue: 5353) else { return }
        let udpParams = NWParameters.udp
        CastWire.configureLocalParameters(udpParams)
        let conn = NWConnection(host: nwHost, port: nwPort, using: udpParams)
        let query = Self.mDNSQueryData

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .ready:
                conn?.send(content: query, completion: .contentProcessed { _ in })
                conn?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    conn?.cancel()
                    guard let data, let self else { return }
                    guard let (id, name, model, port, ca) = Self.parseDNSResponse(data),
                          (ca & 0x01) != 0 else { return }
                    let endpoint = NWEndpoint.hostPort(
                        host: nwHost,
                        port: NWEndpoint.Port(rawValue: port) ?? 8009
                    )
                    let device = CastDevice(
                        id: id,
                        name: name,
                        model: model,
                        endpoint: endpoint,
                        host: ip,
                        port: port,
                        supportsVideo: true
                    )
                    DispatchQueue.main.async {
                        self.addOrUpdateDevice(device)
                    }
                }
            case .failed, .cancelled:
                conn?.cancel()
            default:
                break
            }
        }

        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2.5) { [weak conn] in
            conn?.cancel()
        }
    }

    private func addOrUpdateDevice(_ device: CastDevice) {
        cachedDevices[device.id] = (device, Date())
        recordDeviceIP(device.host)
        pruneOldDevices()
    }

    nonisolated static func parseDNSResponse(
        _ data: Data
    ) -> (id: String, name: String, model: String, port: UInt16, ca: UInt32)? {
        let count = data.count
        guard count >= 12 else { return nil }
        let base = data.startIndex

        var offset = 12
        let qdcount = (Int(data[base + 4]) << 8) | Int(data[base + 5])
        let ancount = (Int(data[base + 6]) << 8) | Int(data[base + 7])
        let nscount = (Int(data[base + 8]) << 8) | Int(data[base + 9])
        let arcount = (Int(data[base + 10]) << 8) | Int(data[base + 11])
        let totalRecords = ancount + nscount + arcount

        func skipName(_ offset: inout Int) -> Bool {
            var steps = 0
            while offset < count, steps < 128 {
                steps += 1
                let b = data[base + offset]
                if b == 0 {
                    offset += 1
                    return true
                }
                if (b & 0xC0) == 0xC0 {
                    guard offset + 2 <= count else { return false }
                    offset += 2
                    return true
                }
                let labelLen = Int(b)
                guard labelLen < 64, offset + 1 + labelLen <= count else { return false }
                offset += 1 + labelLen
            }
            return false
        }

        for _ in 0..<qdcount {
            guard skipName(&offset), offset + 4 <= count else { return nil }
            offset += 4
        }

        var txtDict: [String: String] = [:]
        var port: UInt16 = 8009

        for _ in 0..<totalRecords {
            guard offset < count else { break }
            guard skipName(&offset), offset + 10 <= count else { break }
            let type = (UInt16(data[base + offset]) << 8) | UInt16(data[base + offset + 1])
            let rdlength = (Int(data[base + offset + 8]) << 8) | Int(data[base + offset + 9])
            offset += 10
            let rdataEnd = offset + rdlength
            guard rdlength >= 0, rdataEnd <= count else { break }

            if type == 16 {   // TXT
                var cur = offset
                while cur < rdataEnd {
                    let len = Int(data[base + cur])
                    cur += 1
                    guard cur + len <= rdataEnd else { break }
                    let sub = data[(base + cur)..<(base + cur + len)]
                    if let s = String(data: sub, encoding: .utf8), let eq = s.firstIndex(of: "=") {
                        txtDict[String(s[..<eq])] = String(s[s.index(after: eq)...])
                    }
                    cur += len
                }
            } else if type == 33, rdlength >= 6 {   // SRV
                port = (UInt16(data[base + offset + 4]) << 8) | UInt16(data[base + offset + 5])
            }
            offset = rdataEnd
        }

        guard let id = txtDict["id"], !id.isEmpty,
              let fn = txtDict["fn"], !fn.isEmpty else { return nil }
        let md = txtDict["md"] ?? "Chromecast"
        let ca = UInt32(txtDict["ca"] ?? "0") ?? 0
        return (id, fn, md, port, ca)
    }
}
