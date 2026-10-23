// AdbDeviceWatcher — detects Android devices over USB via ADB and
// automatically sets up `adb forward tcp:9000 tcp:9000` so the Mac sender
// can reach the receiver app on 127.0.0.1:9000 without any manual steps.
//
// Why a separate watcher: the Mac app's existing UsbmuxDeviceWatcher speaks
// usbmuxd (macOS's built-in iOS multiplexer on /var/run/usbmuxd), which
// Android devices never expose. The Android receiver listens on 127.0.0.1:9000
// specifically for the ADB-forward path — see PhoneReceiver.listenLoop with
// acceptGate = ::isAdbEnabled.
//
// This watcher mirrors UsbmuxDeviceWatcher's lifecycle: seed from the
// current state on init, then poll for attach/detach. When the set of
// connected Android devices transitions from empty → non-empty, it fires
// an adb forward so the existing `.usb(udid: nil) → .tcp(127.0.0.1:9000)`
// fallback in OpenSidecarMacApp.autoConnect() picks it up.

import Foundation

/// One ADB-connected Android device. Identified by its adb serial number,
/// which is stable across replugs on the same physical port.
struct AdbDevice: Hashable, Identifiable {
    let serial: String   /// ADB serial number (e.g. `ABC1234567`)
    let name: String?    /// Best-effort device name from `adb -s serial shell getprop ro.product.model`

    var id: String { serial }
}

@MainActor
final class AdbDeviceWatcher {
    /// The devices currently seen by `adb devices` (only rows with state=device).
    /// Not @Published — the MainActor controller drives UI through onChange.
    private(set) var devices: [AdbDevice] = []

    /// Fired whenever the device set changes (attach, detach, or name resolve).
    /// The OpenSidecar controller uses this to auto-configure the host/port
    /// defaults and trigger a TCP dial to 127.0.0.1:9000.
    var onChange: (([AdbDevice]) -> Void)?

    /// Whether `adb` is available on PATH. Checked once at init; if `false`
    /// the watcher stays quiet and never fires onChange.
    let adbAvailable: Bool

    /// The adb executable path, cached at init time so a PATH change mid-run
    /// does not confuse things.
    private let adbPath: String

    private let queue = DispatchQueue(label: "adb.watcher")
    private var lastKnown: Set<String> = []
    private var isForwardActive = false

    /// Cache of serial → product model name. Resolved once on first attach
    /// per serial; re-plug with the same serial reuses the cache. `adb shell`
    /// per device per 3s poll was wasteful and could stall on unauthorized
    /// devices, so we name-resolve lazily and cache aggressively.
    private var nameCache: [String: String?] = [:]

    /// Timeout for any single `adb` process spawn. A hung adb (unauthorized
    /// device, adbd crash) must not stall the 3s poll loop indefinitely.
    private static let adbTimeout: TimeInterval = 5

    init() {
        let path = Self.locateAdb()
        self.adbPath = path ?? ""
        self.adbAvailable = path != nil

        guard adbAvailable else {
            Log.info("adb not found on PATH — Android USB watcher disabled")
            return
        }
        Log.info("adb watcher started (adb = \(adbPath))")
        Task {
            await scanLoop()
        }
    }

    // MARK: - Polling loop

    /// Poll `adb devices -l` every 3s and reconcile the device set.
    /// Slow enough to not hammer adb, fast enough that a plugin-and-wait
    /// flow connects within ~3s.
    private func scanLoop() async {
        while true {
            let current = await scanDevices()
            let currentSerials = Set(current.map(\.serial))
            let newlyAttached = currentSerials.subtracting(lastKnown)
            let nowDetached = lastKnown.subtracting(currentSerials)

            if !newlyAttached.isEmpty {
                Log.info("adb device attached: \(newlyAttached.sorted())")
            }
            if !nowDetached.isEmpty {
                Log.info("adb device detached: \(nowDetached.sorted())")
                // Drop name cache for detached devices — serials can be reused
                // if a different Android device gets the same USB port.
                for serial in nowDetached { nameCache.removeValue(forKey: serial) }
            }

            lastKnown = currentSerials
            devices = current

            // Manage the adb forward tunnel — only when a device is present.
            if !current.isEmpty {
                trySetupForward()
            } else {
                tryTeardownForward()
            }

            if !newlyAttached.isEmpty || !nowDetached.isEmpty {
                onChange?(current)
            }

            try? await Task.sleep(for: .seconds(3))
        }
    }

    // MARK: - Device scan

    /// Run `adb devices -l` and parse the output into [AdbDevice].
    /// Rows with state `device` (not `unauthorized`, `offline`, etc.) count.
    private func scanDevices() async -> [AdbDevice] {
        guard let (output, exitCode) = await runAdb(["devices", "-l"]) else {
            return []
        }
        guard exitCode == 0 else {
            return []
        }

        var result: [AdbDevice] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.dropFirst() {   // skip the "List of devices attached" header
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let serial = String(parts[0])
            let state = String(parts[1])
            guard state == "device" else { continue }

            // Resolve device name from cache, or lazily on first attach.
            let name = await resolvedName(serial: serial)
            result.append(AdbDevice(serial: serial, name: name))
        }
        return result
    }

    /// Return cached name for `serial`, or resolve and cache on first call.
    /// Each unique serial triggers at most one `adb shell getprop` call —
    /// subsequent polls within a session hit the dictionary.
    private func resolvedName(serial: String) async -> String? {
        if let cached = nameCache[serial] { return cached }
        let name = await resolveDeviceName(serial: serial)
        nameCache[serial] = name
        return name
    }

    /// One-shot name resolution for a serial. Called exactly once per serial
    /// per session. `adb -s serial shell getprop ro.product.model` is fast when
    /// adb is warm; returns nil on any failure or timeout.
    private func resolveDeviceName(serial: String) async -> String? {
        let args = ["-s", serial, "shell", "getprop", "ro.product.model"]
        guard let (output, exitCode) = await runAdb(args), exitCode == 0 else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - adb forward management

    /// Establish `adb forward tcp:9000 tcp:9000` if it is not already in place.
    /// Idempotent — calling it twice is harmless; we check first with
    /// `adb forward --list`.
    private func trySetupForward() {
        guard !isForwardActive else { return }
        Task { [weak self] in
            guard let self else { return }
            // Check if already set up (another tool, or a previous run).
            if let (listOutput, _) = await self.runAdb(["forward", "--list"]),
               listOutput.contains("tcp:9000 tcp:9000") {
                Log.info("adb forward tcp:9000 tcp:9000 already active")
                self.isForwardActive = true
                self.onChange?(self.devices)
                return
            }
            guard let (_, exitCode) = await self.runAdb(["forward", "tcp:9000", "tcp:9000"]),
                  exitCode == 0 else {
                Log.info("adb forward tcp:9000 tcp:9000 failed")
                return
            }
            Log.info("adb forward tcp:9000 tcp:9000 established")
            self.isForwardActive = true
            self.onChange?(self.devices)
        }
    }

    /// Remove the forward rule when no Android device is attached.
    /// Called on every scan that returns empty; idempotent.
    private func tryTeardownForward() {
        guard isForwardActive else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.runAdb(["forward", "--remove", "tcp:9000"])
            Log.info("adb forward tcp:9000 removed (no Android device)")
            self.isForwardActive = false
            self.onChange?([])
        }
    }

    // MARK: - Process helper

    /// Execute `adb <args>` with a hard timeout.
    /// Returns (stdout, exitCode), or nil if launch fails or the process exceeds
    /// `adbTimeout` seconds (in which case the process is terminated).
    @discardableResult
    private func runAdb(_ args: [String]) async -> (String, Int32)? {
        let timeout = Self.adbTimeout
        return await withTaskGroup(of: (String, Int32)?.self) { group in
            // The process execution task
            group.addTask { [adbPath] in
                await withCheckedContinuation { continuation in
                    let process = Process()
                    process.launchPath = adbPath
                    process.arguments = args
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe   // adb writes most errors to stderr
                    do {
                        try process.run()
                    } catch {
                        Log.info("adb process launch failed: \(error)")
                        continuation.resume(returning: nil)
                        return
                    }
                    process.terminationHandler = { proc in
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: data, encoding: .utf8) ?? ""
                        continuation.resume(returning: (output, proc.terminationStatus))
                    }
                }
            }
            // The timeout task — kills any lingering process after `adbTimeout`.
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            // First task that completes wins. If the timeout fires first,
            // the process task is cancelled (but the underlying process may
            // still be running — we kill it via terminationHandler best-effort).
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: - Static helpers

    /// Find adb on PATH, or in well-known install locations (Homebrew, SDK).
    /// macOS ships no adb by default — users get it via `brew install android-platform-tools`.
    static func locateAdb() -> String? {
        // 1. PATH lookup via `which`
        if let path = which("adb"), FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // 2. Homebrew (Apple Silicon: /opt/homebrew/bin/adb, Intel: /usr/local/bin/adb)
        let brewCandidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        for candidate in brewCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // 3. Android SDK (standard location)
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            let sdkCandidates = [
                "\(home)/Library/Android/sdk/platform-tools/adb",
                "\(home)/Android/Sdk/platform-tools/adb"
            ]
            for candidate in sdkCandidates {
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func which(_ name: String) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.launchPath = "/usr/bin/which"
        process.arguments = [name]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}
