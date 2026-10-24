import AppKit
import Darwin
import Foundation

/// Appends timestamped lines to a log file (and stdout) so the stream can be
/// debugged without a debugger attached.
///
/// The file is size-capped and rotated rather than unbounded. Any per-frame or
/// per-message code path that starts logging (an encoder failing every frame, a
/// peer sending message types this build predates) would otherwise fill the
/// disk. At most `maxBytes` x 2 survives.
///
/// Note this rotates rather than stopping at a ceiling. A hard cap would keep
/// the *oldest* bytes and discard everything recent, which is backwards: when a
/// report comes in, the useful window is what happened just before the problem.
enum Log {
    /// `~/Library/Logs/OpenDisplay`. The platform convention, and deliberately
    /// not /tmp: macOS clears /tmp on reboot, and rebooting is the first thing
    /// someone tries before filing a bug, so a log there is gone exactly when
    /// it's wanted. Living here also means Console.app lists it under Log
    /// Reports without us doing anything.
    ///
    /// The folder is named after the app: the sender logs to `OpenDisplay`,
    /// the receiver app (a separate bundle sharing this file) to
    /// `OpenDisplay Receiver`, so running both on one Mac keeps two logs.
    private static let directory: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let product = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
        let folder = product.hasPrefix("OpenDisplay") ? product : "OpenDisplay"
        return library.appendingPathComponent("Logs/\(folder)", isDirectory: true)
    }()

    /// Sized from the steady-state rate: an active session logs one aggregated
    /// PHONE-STATS line (~256 bytes) every 5s, so ~180 KB per streaming hour.
    /// 8MB is therefore ~45 hours of active streaming in the live file alone,
    /// and rotation means at least that much always survives. Idle time costs
    /// almost nothing, so in wall-clock terms this is comfortably days.
    private static let maxBytes: UInt64 = 8 * 1024 * 1024

    private static let queue = DispatchQueue(label: "log")
    private static let writer = RotatingLogFile(
        directory: directory,
        baseName: "opendisplay",
        maxBytes: maxBytes
    )
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        print(line, terminator: "")
        guard let data = line.data(using: .utf8) else { return }
        queue.async { writer.append(data) }
    }

    /// Shows the log files in Finder, for "send me your logs" support requests.
    /// Hops through `queue` first so anything already logged is on disk before
    /// the user grabs the file.
    static func revealInFinder() {
        queue.async {
            let existing = writer.existingFiles()
            DispatchQueue.main.async {
                if existing.isEmpty {
                    // The writer could not reach the files. Open the folder
                    // anyway so the menu item never appears to do nothing.
                    NSWorkspace.shared.open(directory)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting(existing)
                }
            }
        }
    }
}

/// Stateful file sink behind `Log`. Calls are serialized by `Log.queue` in the
/// app; keeping the sink synchronous also makes its filesystem behavior
/// directly testable.
final class RotatingLogFile {
    typealias ErrorReporter = (String) -> Void
    private static let processLock = NSLock()

    let directory: URL
    let fileURL: URL
    let rotatedURL: URL
    let maxBytes: UInt64

    private let lockURL: URL
    private let fileManager: FileManager
    private let reportError: ErrorReporter
    private var handle: FileHandle?
    private var lockHandle: FileHandle?

    init(
        directory: URL,
        baseName: String,
        maxBytes: UInt64,
        fileManager: FileManager = .default,
        reportError: @escaping ErrorReporter = RotatingLogFile.reportToStandardError
    ) {
        precondition(maxBytes > 0)
        self.directory = directory
        fileURL = directory.appendingPathComponent("\(baseName).log")
        rotatedURL = directory.appendingPathComponent("\(baseName)-previous.log")
        lockURL = directory.appendingPathComponent(".\(baseName).lock")
        self.maxBytes = maxBytes
        self.fileManager = fileManager
        self.reportError = reportError
    }

    deinit {
        try? handle?.close()
        try? lockHandle?.close()
    }

    // The handle is held open across lines: reopening per line costs ~22us
    // against ~1us for a write to a live handle. Calls on one instance must be
    // serialized; the lock below coordinates separate app processes.
    func append(_ data: Data) {
        let payload: Data
        if UInt64(data.count) > maxBytes {
            payload = Data(data.suffix(Int(maxBytes)))
            reportError("entry exceeded the log cap; only its newest \(maxBytes) bytes were kept")
        } else {
            payload = data
        }

        withExclusiveLock {
            do {
                var opened = try currentHandle()
                let size = try opened.seekToEnd()
                if size > maxBytes - UInt64(payload.count) {
                    try rotate()
                    opened = try currentHandle()
                    _ = try opened.seekToEnd()
                }
                try opened.write(contentsOf: payload)
            } catch {
                closeCurrentHandle()
                reportError("could not append to \(fileURL.path): \(error.localizedDescription)")
            }
        }
    }

    func existingFiles() -> [URL] {
        var existing: [URL] = []
        withExclusiveLock {
            do {
                _ = try currentHandle()
                existing = [fileURL, rotatedURL].filter {
                    fileManager.fileExists(atPath: $0.path)
                }
            } catch {
                reportError("could not prepare logs for Finder: \(error.localizedDescription)")
            }
        }
        return existing
    }

    private func currentHandle() throws -> FileHandle {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle, handlePointsToURL(handle, fileURL) {
            return handle
        }
        closeCurrentHandle()
        if !fileManager.fileExists(atPath: fileURL.path) {
            let created = fileManager.createFile(atPath: fileURL.path, contents: nil)
            guard created || fileManager.fileExists(atPath: fileURL.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let opened = try FileHandle(forWritingTo: fileURL)
        handle = opened
        return opened
    }

    private func rotate() throws {
        closeCurrentHandle()
        do {
            if fileManager.fileExists(atPath: rotatedURL.path) {
                _ = try fileManager.replaceItemAt(rotatedURL, withItemAt: fileURL)
            } else {
                try fileManager.moveItem(at: fileURL, to: rotatedURL)
            }
        } catch {
            reportError("could not rotate \(fileURL.path): \(error.localizedDescription)")
            // Keep the disk bound even when generation replacement fails. If
            // the live file survived, truncate it so the newest entries win.
            let opened = try currentHandle()
            try opened.truncate(atOffset: 0)
        }
        _ = try currentHandle()
    }

    private func withExclusiveLock(_ body: () -> Void) {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let opened: FileHandle
        do {
            opened = try currentLockHandle()
        } catch {
            reportError("could not open the log lock: \(error.localizedDescription)")
            return
        }

        guard ODLockFile(opened.fileDescriptor) == 0 else {
            reportError("could not lock the log: \(Self.currentPOSIXError())")
            return
        }
        defer {
            if ODUnlockFile(opened.fileDescriptor) != 0 {
                reportError("could not unlock the log: \(Self.currentPOSIXError())")
            }
        }
        body()
    }

    private func currentLockHandle() throws -> FileHandle {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let lockHandle, handlePointsToURL(lockHandle, lockURL) {
            return lockHandle
        }
        try? lockHandle?.close()
        lockHandle = nil
        if !fileManager.fileExists(atPath: lockURL.path) {
            let created = fileManager.createFile(atPath: lockURL.path, contents: nil)
            guard created || fileManager.fileExists(atPath: lockURL.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let opened = try FileHandle(forUpdating: lockURL)
        lockHandle = opened
        return opened
    }

    private func handlePointsToURL(_ handle: FileHandle, _ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return ODFileDescriptorPointsToPath(handle.fileDescriptor, path)
        }
    }

    private func closeCurrentHandle() {
        try? handle?.close()
        handle = nil
    }

    private static func currentPOSIXError() -> String {
        String(cString: strerror(errno))
    }

    private static func reportToStandardError(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("OpenDisplay log: \(message)\n".utf8))
    }
}
