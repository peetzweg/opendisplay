// ADB-backed Android device discovery and TCP forwarding.
//
// The Android receiver listens on the device at TCP :9000. That port cannot
// be dialed directly over an Android USB connection, so the Mac asks adb to
// allocate a free loopback port (`adb forward tcp:0 tcp:9000`) for each
// connected device. The sender can then use its normal TCP transport against
// 127.0.0.1:<allocated port>; multiple Android devices never contend for the
// same local port.

import Foundation

struct AdbDevice: Hashable, Identifiable {
    let serial: String
    let name: String
    let state: String
    let localPort: UInt16?

    var id: String { serial }
    var ready: Bool { state == "device" && localPort != nil }

    var connectionHint: String {
        switch state {
        case "device" where localPort == nil:
            return "ADB · Unable to forward port \(Adb.receiverPort)"
        case "unauthorized":
            return "ADB · Authorize USB debugging on the device"
        case "offline":
            return "ADB · Device offline"
        default:
            return "ADB"
        }
    }
}

enum Adb {
    static let receiverPort: UInt16 = 9000

    struct ListedDevice: Equatable {
        let serial: String
        let state: String
        let name: String
    }

    struct Forward: Equatable {
        let serial: String
        let localPort: UInt16
        let remotePort: UInt16
    }

    enum Failure: Error, LocalizedError {
        case unavailable
        case command(String)
        case invalidForwardPort(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "adb is not installed"
            case .command(let detail):
                return detail.isEmpty ? "adb command failed" : detail
            case .invalidForwardPort(let output):
                return "adb returned an invalid forwarded port: \(output)"
            }
        }
    }

    /// GUI apps do not inherit the interactive shell's PATH. Search Android
    /// Studio's standard SDK location and the usual Homebrew locations in
    /// addition to the environment supplied at launch.
    static func executableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        var candidates: [URL] = []
        for key in ["ANDROID_SDK_ROOT", "ANDROID_HOME"] {
            if let root = environment[key], !root.isEmpty {
                candidates.append(URL(fileURLWithPath: root)
                    .appendingPathComponent("platform-tools/adb"))
            }
        }
        candidates.append(homeDirectory
            .appendingPathComponent("Library/Android/sdk/platform-tools/adb"))
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory))
                .appendingPathComponent("adb"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/adb"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/adb"))

        var seen = Set<String>()
        return candidates.first { candidate in
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            return FileManager.default.isExecutableFile(atPath: path)
        }
    }

    static func listDevices(using executable: URL) throws -> [ListedDevice] {
        parseDevices(try run(["devices", "-l"], using: executable))
    }

    /// Parse `adb devices -l`. Non-ready rows are intentionally retained so
    /// the UI can tell the user to approve USB debugging instead of looking
    /// as if no Android device was attached.
    static func parseDevices(_ output: String) -> [ListedDevice] {
        output.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let fields = rawLine.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2,
                  fields[0] != "List", fields[0] != "*" else { return nil }
            let serial = String(fields[0])
            let state = String(fields[1])
            var attributes: [String: String] = [:]
            for field in fields.dropFirst(2) {
                guard let colon = field.firstIndex(of: ":") else { continue }
                attributes[String(field[..<colon])] =
                    String(field[field.index(after: colon)...])
            }
            let rawName = attributes["model"] ?? attributes["device"] ?? serial
            let name = rawName.replacingOccurrences(of: "_", with: " ")
            return ListedDevice(serial: serial, state: state, name: name)
        }
    }

    static func listForwards(using executable: URL) throws -> [Forward] {
        parseForwards(try run(["forward", "--list"], using: executable))
    }

    static func parseForwards(_ output: String) -> [Forward] {
        output.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let fields = rawLine.split(whereSeparator: \Character.isWhitespace)
            guard fields.count == 3,
                  let local = tcpPort(String(fields[1])),
                  let remote = tcpPort(String(fields[2])) else { return nil }
            return Forward(serial: String(fields[0]), localPort: local, remotePort: remote)
        }
    }

    /// Prefer the prior local port after a quick detach/reattach so an active
    /// sender can reconnect to the same endpoint. If it has been claimed in
    /// the meantime, ask adb for another free port.
    static func addForward(serial: String, preferredLocalPort: UInt16? = nil,
                           using executable: URL) throws -> UInt16 {
        if let preferredLocalPort {
            do {
                _ = try run(["-s", serial, "forward", "tcp:\(preferredLocalPort)",
                             "tcp:\(receiverPort)"], using: executable)
                return preferredLocalPort
            } catch {
                // tcp:0 below is atomic inside adb and avoids a local
                // check-then-bind race when the old port is no longer free.
            }
        }
        let output = try run(["-s", serial, "forward", "tcp:0",
                              "tcp:\(receiverPort)"], using: executable)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(output), port > 0 else {
            throw Failure.invalidForwardPort(output)
        }
        return port
    }

    static func removeForward(serial: String, localPort: UInt16,
                              using executable: URL) throws {
        _ = try run(["-s", serial, "forward", "--remove", "tcp:\(localPort)"],
                    using: executable)
    }

    private static func tcpPort(_ endpoint: String) -> UInt16? {
        guard endpoint.hasPrefix("tcp:") else { return nil }
        return UInt16(endpoint.dropFirst(4))
    }

    @discardableResult
    private static func run(_ arguments: [String], using executable: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw Failure.command(error.localizedDescription)
        }
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self)
        let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure.command(errorOutput)
        }
        return output
    }
}

/// ADB has no attach notification API intended for desktop clients, so poll
/// its cheap device listing on a private queue. Each ready device receives one
/// stable, app-owned port forward. The forward is removed when OpenDisplay
/// exits; adb itself removes it when the device disconnects.
final class AdbDeviceWatcher {
    private let queue = DispatchQueue(label: "adb.watcher")
    private let onChange: ([AdbDevice], Bool) -> Void
    private var timer: DispatchSourceTimer?
    private var executable: URL?
    // Keep ports across a temporary detach so reconnects can preserve the
    // loopback endpoint used by an existing MacSender.
    private var ownedPorts: [String: UInt16] = [:]
    private var stopped = false

    init(onChange: @escaping ([AdbDevice], Bool) -> Void) {
        self.onChange = onChange
        queue.async { [weak self] in
            guard let self else { return }
            self.refresh()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            timer = nil
            if let executable {
                for (serial, port) in ownedPorts {
                    try? Adb.removeForward(serial: serial, localPort: port,
                                           using: executable)
                }
            }
            ownedPorts.removeAll()
        }
    }

    private func refresh() {
        guard !stopped else { return }
        guard let executable = Adb.executableURL() else {
            self.executable = nil
            publish([], available: false)
            return
        }
        self.executable = executable
        do {
            let listed = try Adb.listDevices(using: executable)
            let forwards = (try? Adb.listForwards(using: executable)) ?? []
            var devices: [AdbDevice] = []
            for item in listed {
                var localPort: UInt16?
                if item.state == "device" {
                    let remembered = ownedPorts[item.serial]
                    let stillForwarded = remembered.map { port in
                        forwards.contains(Adb.Forward(serial: item.serial,
                            localPort: port, remotePort: Adb.receiverPort))
                    } ?? false
                    if stillForwarded {
                        localPort = remembered
                    } else {
                        do {
                            // Do not replace an unrelated forward that took
                            // our remembered port while this device was away.
                            let reusable = remembered.flatMap { port in
                                forwards.contains(where: { $0.localPort == port })
                                    ? nil : port
                            }
                            let port = try Adb.addForward(
                                serial: item.serial, preferredLocalPort: reusable,
                                using: executable)
                            ownedPorts[item.serial] = port
                            localPort = port
                            Log.info("adb forward: \(item.serial) tcp:\(port) -> tcp:\(Adb.receiverPort)")
                        } catch {
                            Log.info("adb forward failed for \(item.serial): \(error)")
                        }
                    }
                }
                devices.append(AdbDevice(serial: item.serial, name: item.name,
                                         state: item.state, localPort: localPort))
            }
            publish(devices.sorted { $0.serial < $1.serial }, available: true)
        } catch {
            Log.info("adb watcher: \(error)")
            publish([], available: true)
        }
    }

    private func publish(_ devices: [AdbDevice], available: Bool) {
        DispatchQueue.main.async { [onChange] in onChange(devices, available) }
    }
}
