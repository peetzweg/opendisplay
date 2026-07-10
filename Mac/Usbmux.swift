// Usbmux — native client for the usbmuxd daemon that ships on every macOS
// install (Finder sync, Xcode, and Sidecar all ride on it). It multiplexes
// TCP connections over the USB cable to iOS devices and speaks a plist
// protocol on a Unix socket:
//
//   [UInt32 LE total length][UInt32 LE version=1][UInt32 LE type=8 (plist)]
//   [UInt32 LE tag][XML plist payload]
//
// Three requests matter here: ListDevices, Listen (subscribe to attach/
// detach events), and Connect(DeviceID, PortNumber) — after an OK result the
// same socket becomes a transparent byte pipe to that TCP port on the
// device. That pipe is exactly what `iproxy` (libimobiledevice) provides as
// an external tool; speaking the protocol directly drops that dependency.

import Foundation
import Network

struct UsbmuxDevice: Hashable, Identifiable {
    let deviceID: Int     // usbmuxd's handle — changes on every replug
    let udid: String      // stable hardware identifier
    var name: String?     // lockdown DeviceName ("Philip's iPhone"), best-effort

    var id: String { udid }
    var label: String { "\(name ?? "iPhone / iPad") (USB)" }
}

private final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ body: () -> Void) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        body()
    }
}

enum Usbmux {
    static let socketPath = "/var/run/usbmuxd"
    // lockdownd, the device-side service that answers GetValue queries.
    static let lockdownPort: UInt16 = 62078

    enum Failure: Error, LocalizedError {
        case noDevice          // nothing attached (or the chosen udid is gone)
        case refused           // device present, nothing listening on the port
        case result(Int)       // other usbmuxd result code
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .noDevice: return "未连接 USB 设备"
            case .refused: return "设备端尚未监听该端口"
            case .result(let code): return "usbmuxd 返回结果 \(code)"
            case .protocolError(let detail): return "usbmuxd 协议错误：\(detail)"
            }
        }
    }

    // MARK: - Requests

    static func listDevices(queue: DispatchQueue) async throws -> [UsbmuxDevice] {
        let conn = try await open(queue: queue)
        defer { conn.cancel() }
        try await send(["MessageType": "ListDevices"], on: conn)
        let reply = try await readMessage(on: conn)
        let entries = reply["DeviceList"] as? [[String: Any]] ?? []
        return entries.compactMap {
            device(fromProperties: $0["Properties"] as? [String: Any] ?? [:])
        }
    }

    /// Open a TCP connection to `port` on the device. On success the returned
    /// connection is a transparent pipe — usbmuxd is out of the picture.
    static func connect(deviceID: Int, port: UInt16,
                        queue: DispatchQueue) async throws -> NWConnection {
        let conn = try await open(queue: queue)
        do {
            try await send([
                "MessageType": "Connect",
                "DeviceID": deviceID,
                // usbmuxd expects the port in network byte order.
                "PortNumber": Int((port << 8) | (port >> 8)),
            ], on: conn)
            let reply = try await readMessage(on: conn)
            guard reply["MessageType"] as? String == "Result" else {
                throw Failure.protocolError("unexpected reply to Connect")
            }
            switch reply["Number"] as? Int ?? -1 {
            case 0: break
            case 2: throw Failure.noDevice    // BadDevice — unplugged mid-dial
            case 3: throw Failure.refused     // nothing listening on the port
            case let code: throw Failure.result(code)
            }
            conn.stateUpdateHandler = nil   // the adopter installs its own
            return conn
        } catch {
            conn.cancel()
            throw error
        }
    }

    /// Resolve a device (specific udid, or the first wired one) and connect
    /// to `port` on it. One-shot — callers own the retry loop.
    static func dial(udid: String?, port: UInt16,
                     queue: DispatchQueue) async throws -> NWConnection {
        let devices = try await listDevices(queue: queue)
        let device = udid.map { u in devices.first { $0.udid == u } } ?? devices.first
        guard let device else { throw Failure.noDevice }
        return try await connect(deviceID: device.deviceID, port: port, queue: queue)
    }

    /// Best-effort friendly name ("Philip's iPhone") from lockdownd, which
    /// answers DeviceName without a pairing session. Note lockdown framing
    /// differs from usbmuxd framing: [UInt32 BE length][XML plist].
    static func deviceName(deviceID: Int, queue: DispatchQueue) async throws -> String {
        let conn = try await connect(deviceID: deviceID, port: lockdownPort, queue: queue)
        defer { conn.cancel() }
        let request = try PropertyListSerialization.data(fromPropertyList: [
            "Request": "GetValue", "Key": "DeviceName", "Label": "OpenDisplay",
        ] as [String: Any], format: .xml, options: 0)
        var packet = withUnsafeBytes(of: UInt32(request.count).bigEndian) { Data($0) }
        packet.append(request)
        try await send(raw: packet, on: conn)
        let header = try await receive(exactly: 4, on: conn)
        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard length > 0, length < 1 << 16 else {
            throw Failure.protocolError("bad lockdown reply length \(length)")
        }
        let body = try await receive(exactly: length, on: conn)
        guard let plist = try? PropertyListSerialization.propertyList(from: body, format: nil)
                as? [String: Any],
              let name = plist["Value"] as? String, !name.isEmpty else {
            throw Failure.protocolError("lockdown GetValue(DeviceName) not answered")
        }
        return name
    }

    static func device(fromProperties props: [String: Any]) -> UsbmuxDevice? {
        // usbmuxd also lists WiFi-paired devices (ConnectionType "Network");
        // those are served by the app's Bonjour path — wired only here.
        guard props["ConnectionType"] as? String == "USB",
              let deviceID = props["DeviceID"] as? Int,
              let udid = props["SerialNumber"] as? String else { return nil }
        return UsbmuxDevice(deviceID: deviceID, udid: udid, name: nil)
    }

    // MARK: - Socket plumbing

    static func open(queue: DispatchQueue) async throws -> NWConnection {
        let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = OneShotResume()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume {
                        cont.resume()
                    }
                case .failed(let error), .waiting(let error):
                    // No path updates on a Unix socket — .waiting would hang
                    // forever, so treat it as failure and let callers retry.
                    gate.resume {
                        conn.cancel()
                        cont.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        conn.stateUpdateHandler = nil
        return conn
    }

    static func send(_ message: [String: Any], on conn: NWConnection) async throws {
        var message = message
        message["ProgName"] = "OpenDisplay"
        message["ClientVersionString"] = "OpenDisplay"
        let body = try PropertyListSerialization.data(
            fromPropertyList: message, format: .xml, options: 0)
        var packet = Data(capacity: 16 + body.count)
        for field in [UInt32(16 + body.count), 1, 8, 1] {   // length, version, plist, tag
            withUnsafeBytes(of: field.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(body)
        try await send(raw: packet, on: conn)
    }

    static func readMessage(on conn: NWConnection) async throws -> [String: Any] {
        let header = try await receive(exactly: 16, on: conn)
        let total = Int(UInt32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard total >= 16, total < 1 << 20 else {
            throw Failure.protocolError("bad message length \(total)")
        }
        guard total > 16 else { return [:] }
        let body = try await receive(exactly: total - 16, on: conn)
        guard let plist = try? PropertyListSerialization.propertyList(from: body, format: nil)
                as? [String: Any] else {
            throw Failure.protocolError("non-dictionary message")
        }
        return plist
    }

    private static func send(raw data: Data, on conn: NWConnection) async throws {
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
}

/// Long-lived Listen subscription: keeps the wired device list current for
/// the connection picker (attach/detach events, names resolved best-effort
/// via lockdown) and re-subscribes if the daemon connection drops.
@MainActor
final class UsbmuxDeviceWatcher {
    private let queue = DispatchQueue(label: "usbmux.watcher")
    private var devices: [Int: UsbmuxDevice] = [:]
    private let onChange: ([UsbmuxDevice]) -> Void

    init(onChange: @escaping ([UsbmuxDevice]) -> Void) {
        self.onChange = onChange
        Task { await listenLoop() }
    }

    private func listenLoop() async {
        while true {
            do {
                let conn = try await Usbmux.open(queue: queue)
                defer { conn.cancel() }
                try await Usbmux.send(["MessageType": "Listen"], on: conn)
                while true {
                    // First reply is the Result for Listen itself; it has no
                    // Properties so handle() ignores it.
                    handle(try await Usbmux.readMessage(on: conn))
                }
            } catch {
                Log.info("usbmux watcher: \(error) — retrying in 3s")
                if !devices.isEmpty {
                    devices = [:]
                    publish()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let deviceID = message["DeviceID"] as? Int else { return }
        switch message["MessageType"] as? String {
        case "Attached":
            guard let device = Usbmux.device(
                fromProperties: message["Properties"] as? [String: Any] ?? [:]) else { return }
            Log.info("usbmux attached: \(device.udid)")
            devices[deviceID] = device
            publish()
            resolveName(deviceID: deviceID)
        case "Detached":
            if let device = devices.removeValue(forKey: deviceID) {
                Log.info("usbmux detached: \(device.udid)")
                publish()
            }
        default:
            break
        }
    }

    private func resolveName(deviceID: Int) {
        Task {
            guard let name = try? await Usbmux.deviceName(deviceID: deviceID, queue: queue),
                  devices[deviceID] != nil else { return }
            devices[deviceID]?.name = name
            publish()
        }
    }

    private func publish() {
        onChange(devices.values.sorted { $0.udid < $1.udid })
    }
}
