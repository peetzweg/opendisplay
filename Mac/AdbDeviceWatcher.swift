// AdbDeviceWatcher — finds Android devices on the USB cable and dials their
// receiver through an adb forward, so a cabled Android device connects like
// a cabled iPhone does: no `adb forward` by hand, no -host/-port override.
//
// Android has no usbmuxd. What a developer-mode Android device has instead
// is adb: with USB debugging on, the adb server (127.0.0.1:5037) tracks
// attached devices and can forward a local TCP port to a port on the device.
// Like Usbmux.swift, this speaks the server's socket protocol directly
// instead of spawning the `adb` client:
//
//   request: [4 hex digits: length][service, e.g. "host:track-devices-l"]
//   reply:   "OKAY" | "FAIL" [4 hex length][message]
//
// Not spawning the client matters: an `adb` binary whose version differs
// from the running server's kills and replaces that server, and a Mac with
// both Homebrew's and Android Studio's adb would have the two fight forever.
// The binary is only used to start a server when none is running.
//
// Android devices join the controller's wired device list under the udid
// `adb:<serial>` (AdbParsing), so cable upgrade, WiFi failover, per-device
// opt-out and the device list rows all work exactly as for usbmuxd devices.

import Foundation
import IOKit
import Network

enum Adb {
    static let serverPort: UInt16 = 5037

    enum Failure: Error, LocalizedError {
        case noServer          // nothing listening on 5037
        case noDevice          // the serial is not attached (or not authorized)
        case refused           // forward up, but no receiver app behind it
        case server(String)    // FAIL reply
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .noServer: return "adb server not running"
            case .noDevice: return "Android device not attached"
            case .refused: return "receiver not listening"
            case .server(let message): return "adb: \(message)"
            case .protocolError(let detail): return "adb protocol error: \(detail)"
            }
        }
    }

    /// Forward a local port to `port` on the device and connect through it.
    /// adb accepts the local connection even when nothing listens on the
    /// device and then closes it at once, so "connected" only means "reached
    /// the receiver" once the first message arrives: the receiver always
    /// opens with hello (PROTOCOL.md). That message is returned for the
    /// caller to handle; the connection's next read starts after it.
    static func dial(serial: String, port: UInt16,
                     queue: DispatchQueue) async throws -> (NWConnection, Data) {
        let localPort = try await forwardedPort(serial: serial, remotePort: port, queue: queue)
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: localPort)!,
                                using: NWParameters(tls: nil, tcp: options))
        // A receiver that accepts but never says hello must not hang the
        // dial: cancelling fails whichever step is pending.
        let deadline = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + 3, execute: deadline)
        defer { deadline.cancel() }
        do {
            try await start(conn, queue: queue)
            let header = try await receive(exactly: 4, on: conn)
            let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard length > 0, length < 1 << 20 else {
                throw Failure.protocolError("bad first message length \(length)")
            }
            return (conn, try await receive(exactly: length, on: conn))
        } catch {
            conn.cancel()
            throw Failure.refused
        }
    }

    /// Reuse this device's forward to `remotePort` if one exists, else let
    /// adb pick a free local port (`tcp:0`): a fixed 9000 would collide
    /// with the Mac Receiver, a second Android device, or any local server.
    /// adb drops the rule itself when the device detaches.
    static func forwardedPort(serial: String, remotePort: UInt16,
                              queue: DispatchQueue) async throws -> UInt16 {
        let listing = try await query("host:list-forward", queue: queue)
        if let port = AdbParsing.forwardedPort(in: listing, serial: serial, remotePort: remotePort) {
            return port
        }
        let conn = try await open(queue: queue)
        defer { conn.cancel() }
        do {
            try await request("host-serial:\(serial):forward:tcp:0;tcp:\(remotePort)", on: conn)
            try await expectOkay(on: conn)   // the forward itself, after the host's OKAY
        } catch Failure.server(let message) where message.contains("not found") {
            throw Failure.noDevice
        }
        guard let port = UInt16(try await readBlock(on: conn)) else {
            throw Failure.protocolError("forward returned no port")
        }
        Log.info("adb forward \(serial) tcp:\(port) → tcp:\(remotePort)")
        return port
    }

    /// The device's user-visible name: the same default the receiver
    /// advertises over Bonjour, so the WiFi twin is matched before the first
    /// hello pins the install id.
    static func deviceName(serial: String, queue: DispatchQueue) async -> String? {
        guard let conn = try? await open(queue: queue) else { return nil }
        defer { conn.cancel() }
        do {
            try await request("host:transport:\(serial)", on: conn)
            try await request("shell:settings get global device_name; getprop ro.product.model", on: conn)
            return AdbParsing.deviceName(fromShellOutput: try await readToEnd(on: conn))
        } catch {
            return nil
        }
    }

    // MARK: - Socket plumbing

    /// Connect to the adb server. One-shot requests get a deadline: a
    /// server that accepts but never answers (wedged mid version fight)
    /// must fail the dial so the session's retry loop keeps running. Only
    /// the long-lived track-devices subscription passes nil.
    static func open(queue: DispatchQueue, deadline: TimeInterval? = 5) async throws -> NWConnection {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: serverPort)!,
                                using: .tcp)
        if let deadline {
            queue.asyncAfter(deadline: .now() + deadline) { conn.cancel() }
        }
        do {
            try await start(conn, queue: queue)
        } catch {
            throw Failure.noServer
        }
        return conn
    }

    /// Send a service request and consume its OKAY.
    static func request(_ service: String, on conn: NWConnection) async throws {
        let body = Data(service.utf8)
        try await send(Data(String(format: "%04x", body.count).utf8) + body, on: conn)
        try await expectOkay(on: conn)
    }

    /// One length-prefixed reply block (track-devices snapshots, list-forward).
    static func readBlock(on conn: NWConnection) async throws -> String {
        let header = try await receive(exactly: 4, on: conn)
        guard let length = Int(String(decoding: header, as: UTF8.self), radix: 16) else {
            throw Failure.protocolError("bad block length")
        }
        guard length > 0 else { return "" }
        return String(decoding: try await receive(exactly: length, on: conn), as: UTF8.self)
    }

    private static func query(_ service: String, queue: DispatchQueue) async throws -> String {
        let conn = try await open(queue: queue)
        defer { conn.cancel() }
        try await request(service, on: conn)
        return try await readBlock(on: conn)
    }

    private static func expectOkay(on conn: NWConnection) async throws {
        let status = String(decoding: try await receive(exactly: 4, on: conn), as: UTF8.self)
        switch status {
        case "OKAY": return
        case "FAIL": throw Failure.server((try? await readBlock(on: conn)) ?? "unknown")
        default: throw Failure.protocolError("unexpected status \(status)")
        }
    }

    private static func start(_ conn: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false   // the handler fires on `queue` (serial)
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed(let error), .waiting(let error):
                    // Loopback has no path changes to wait for.
                    resumed = true
                    conn.cancel()
                    cont.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: Failure.protocolError("cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        conn.stateUpdateHandler = nil
    }

    private static func send(_ data: Data, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private static func receive(exactly count: Int, on conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: error ?? Failure.protocolError("socket closed"))
                }
            }
        }
    }

    private static func readToEnd(on conn: NWConnection) async throws -> String {
        var output = Data()
        while true {
            // An error after partial output (the deadline, a reset) keeps
            // what arrived: the name is usually complete by then.
            let keepPartial = !output.isEmpty
            let (data, done): (Data?, Bool) = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let error, data == nil, !keepPartial {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: (data, isComplete))
                    }
                }
            }
            if let data { output.append(data) }
            if done || data == nil { return String(decoding: output, as: UTF8.self) }
        }
    }

    // MARK: - Starting the server

    /// `adb start-server`, bounded: a wedged binary must not hold the watcher.
    static func startServer(adbPath: String) async -> Bool {
        await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = ["start-server"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(returning: false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// macOS ships no adb. Apps launched from Finder get a minimal PATH, so
    /// the usual install locations are checked explicitly.
    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        let candidates = pathDirs.map { "\($0)/adb" } + [
            "/opt/homebrew/bin/adb",                          // Homebrew, Apple silicon
            "/usr/local/bin/adb",                             // Homebrew, Intel
            "\(home)/Library/Android/sdk/platform-tools/adb", // Android Studio
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Long-lived `host:track-devices-l` subscription: the server pushes a full
/// snapshot on every change, so attach and detach arrive without polling.
/// Reports USB-attached, authorized devices as wired devices.
///
/// Dormant until a USB interface with adb's signature appears: most users
/// never plug in an Android device with USB debugging on, and for them
/// nothing here runs, no adb server gets started, no socket is touched.
@MainActor
final class AdbDeviceWatcher {
    private let queue = DispatchQueue(label: "adb.watcher")
    private var devices: [String: UsbmuxDevice] = [:]   // by serial
    private var unauthorizedLogged: Set<String> = []
    private let onChange: ([UsbmuxDevice]) -> Void
    private var interfaces: AdbInterfaceMonitor?
    private var trackTask: Task<Void, Never>?
    private var trackConnection: NWConnection?
    // A server is started at most once a minute: someone who ran
    // `adb kill-server` must not see it come straight back every retry.
    private var lastServerStart: Date?
    private var adbPath: String??   // last lookup, for logging changes only

    init(onChange: @escaping ([UsbmuxDevice]) -> Void) {
        self.onChange = onChange
        interfaces = AdbInterfaceMonitor { [weak self] present in
            self?.interfacesChanged(present: present)
        }
    }

    private func interfacesChanged(present: Bool) {
        if present, trackTask == nil {
            Log.info("adb USB interface attached — tracking adb devices")
            trackTask = Task { await trackLoop() }
        } else if !present, let task = trackTask {
            Log.info("no adb USB interface left — adb tracking stopped")
            task.cancel()
            trackTask = nil
            trackConnection?.cancel()
            trackConnection = nil
            if !devices.isEmpty { update([]) }
        }
    }

    private func trackLoop() async {
        while !Task.isCancelled {
            do {
                let conn = try await Adb.open(queue: queue, deadline: nil)
                defer { conn.cancel() }
                guard !Task.isCancelled else { return }
                trackConnection = conn
                try await Adb.request("host:track-devices-l", on: conn)
                while true {
                    let snapshot = AdbParsing.devices(try await Adb.readBlock(on: conn))
                    guard !Task.isCancelled else { return }
                    update(snapshot)
                }
            } catch Adb.Failure.noServer {
                if !devices.isEmpty { update([]) }
                guard let path = locateAdb() else {
                    // Debugging is on but this Mac has no adb. Look again
                    // now and then, so installing it needs no replug.
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                if await startServerIfDue(adbPath: path) { continue }
            } catch {
                guard !Task.isCancelled else { return }
                Log.info("adb watcher: \(error.localizedDescription) — retrying in 3s")
                if !devices.isEmpty { update([]) }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func locateAdb() -> String? {
        let path = Adb.locate()
        if adbPath != .some(path) {
            Log.info(path.map { "adb found at \($0)" } ?? "adb not found — Android over USB unavailable")
            adbPath = .some(path)
        }
        return path
    }

    private func startServerIfDue(adbPath: String) async -> Bool {
        guard lastServerStart.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return false }
        lastServerStart = Date()
        Log.info("adb server not running — starting it")
        return await Adb.startServer(adbPath: adbPath)
    }

    private func update(_ snapshot: [AdbParsing.Device]) {
        unauthorizedLogged.formIntersection(snapshot.map(\.serial))
        var next: [String: UsbmuxDevice] = [:]
        for device in snapshot where device.usb {
            guard device.state == "device" else {
                if device.state == "unauthorized", unauthorizedLogged.insert(device.serial).inserted {
                    Log.info("adb: \(device.serial) unauthorized — allow USB debugging on the device")
                }
                continue
            }
            next[device.serial] = devices[device.serial]
                ?? UsbmuxDevice(deviceID: -1, udid: AdbParsing.udid(serial: device.serial),
                                name: device.model)
        }
        guard Set(next.keys) != Set(devices.keys) else { return }
        let attached = Set(next.keys).subtracting(devices.keys)
        for serial in Set(devices.keys).subtracting(next.keys) {
            Log.info("adb detached: \(serial)")
        }
        for serial in attached {
            Log.info("adb attached: \(serial)")
            unauthorizedLogged.remove(serial)
        }
        devices = next
        publish()
        attached.forEach(resolveName)
    }

    private func resolveName(serial: String) {
        Task {
            guard let name = await Adb.deviceName(serial: serial, queue: queue),
                  devices[serial] != nil, devices[serial]?.name != name else { return }
            devices[serial]?.name = name
            publish()
        }
    }

    private func publish() {
        onChange(devices.values.sorted { $0.udid < $1.udid })
    }
}

/// Watches IOKit for USB interfaces with adb's class triple (vendor-specific
/// 0xFF, subclass 0x42, protocol 1). An Android device exposes one exactly
/// while USB debugging is on, whatever USB mode it is in, so this is the
/// cheap trigger for everything above: notifications, no polling.
@MainActor
private final class AdbInterfaceMonitor {
    private let port: IONotificationPortRef
    private var count = 0
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let added: IOServiceMatchingCallback = { refcon, iterator in
            MainActor.assumeIsolated {
                Unmanaged<AdbInterfaceMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                    .drain(iterator, delta: 1)
            }
        }
        let removed: IOServiceMatchingCallback = { refcon, iterator in
            MainActor.assumeIsolated {
                Unmanaged<AdbInterfaceMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                    .drain(iterator, delta: -1)
            }
        }
        for (type, callback, delta) in [(kIOFirstMatchNotification, added, 1),
                                         (kIOTerminatedNotification, removed, -1)] {
            // IOPropertyMatch, not the USB family's own interface keys: those
            // only match together with a vendor/product id.
            let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
            matching[kIOPropertyMatchKey] = [
                "bInterfaceClass": 0xFF, "bInterfaceSubClass": 0x42, "bInterfaceProtocol": 1,
            ]
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, type, matching, callback, refcon,
                                                   &iterator) == KERN_SUCCESS else {
                Log.info("adb interface monitor: IOKit registration failed")
                continue
            }
            // Draining arms the notification; for first-match it also counts
            // devices already plugged in at launch.
            drain(iterator, delta: delta)
        }
    }

    private func drain(_ iterator: io_iterator_t, delta: Int) {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            count = max(0, count + delta)
            changed = true
        }
        if changed { onChange(count > 0) }
    }
}
