import Foundation

@MainActor
final class AndroidAdbWatcher {
    private static let pollInterval: TimeInterval = 3
    private static let port: UInt16 = 9000

    private let adbPath: String
    private let onChange: (Bool) -> Void
    private var timer: Timer?
    private var attachedSerial: String?

    init?(onChange: @escaping (Bool) -> Void) {
        guard let adbPath = Self.findAdb() else { return nil }
        self.adbPath = adbPath
        self.onChange = onChange
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let serial = Self.firstDeviceSerial(adbPath: adbPath)
        guard serial != attachedSerial else { return }
        attachedSerial = serial
        guard let serial else {
            Log.info("adb device detached")
            onChange(false)
            return
        }
        guard Self.forward(adbPath: adbPath, serial: serial, port: Self.port) else {
            Log.info("adb forward tcp:\(Self.port) failed for \(serial)")
            attachedSerial = nil
            return
        }
        Log.info("adb device attached: \(serial), forwarded tcp:\(Self.port)")
        onChange(true)
    }

    private static func findAdb() -> String? {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func firstDeviceSerial(adbPath: String) -> String? {
        guard let output = run(adbPath, ["devices", "-l"]),
              let header = output.range(of: "List of devices attached") else { return nil }
        for line in output[header.upperBound...].split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 2, fields[1] == "device",
                  fields.contains(where: { $0.hasPrefix("usb:") }) else { continue }
            return String(fields[0])
        }
        return nil
    }

    private static func forward(adbPath: String, serial: String, port: UInt16) -> Bool {
        run(adbPath, ["-s", serial, "forward", "tcp:\(port)", "tcp:\(port)"]) != nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Log.info("adb \(arguments.joined(separator: " ")) failed to launch: \(error)")
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
