import Foundation

/// Logs to NSLog (visible via `log stream` / simctl) and to a file in the
/// app's Documents directory.
///
/// The file exists so a WiFi or USB failure can be diagnosed from a bug report
/// instead of guessed at: nobody filing an issue is going to attach a Mac to
/// their phone and run `log stream`. `snapshot(context:completion:)` turns it
/// into something shareable from Settings & Help.
enum Log {
    private static let queue = DispatchQueue(label: "log")
    private static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("opensidecar-phone.log")
    }()

    /// Cap on the live file, and what survives a trim.
    ///
    /// Entries are event-driven, but the ones that repeat (a decoder failing,
    /// a listener restarting) can repeat for as long as the app is open, and
    /// nothing ever cleared this file: an install that has seen a broken
    /// session grows forever. Keeping the newest half means the trim discards
    /// history rather than the recent past, which is the half a report needs.
    /// The floor stays comfortably above `LogSnapshot.maxBytes` so a snapshot
    /// taken right after a trim still has a full window in it.
    private static let maxBytes: UInt64 = 1024 * 1024
    private static let keepBytes = 512 * 1024

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        NSLog("[opensidecar] %@", message)
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { append(data) }
    }

    /// Writes the shareable snapshot to a temp file and hands back its URL
    /// plus the snapshot text, or nil if it could not be written. The text
    /// rides along so the caller never re-reads the file it was just handed.
    ///
    /// Runs on `queue`, so anything logged a moment ago is already on disk when
    /// the file is read: the interesting line is usually the last one, and a
    /// snapshot that races the write that motivated it is worthless. The
    /// completion lands on the main queue for the caller's UI.
    static func snapshot(context: LogSnapshot.Context,
                         completion: @escaping ((url: URL, text: String)?) -> Void) {
        queue.async {
            let log = (try? Data(contentsOf: fileURL)) ?? Data()
            let now = Date()
            let text = LogSnapshot.compose(context: context, generatedAt: now, log: log)
            let url = write(text, named: LogSnapshot.fileName(deviceName: context.deviceName,
                                                             date: now))
            DispatchQueue.main.async { completion(url.map { ($0, text) }) }
        }
    }

    // MARK: - File

    /// Serialized by `queue`: this opens and closes a handle per line rather
    /// than holding one open, because a trim replaces the file and any handle
    /// held across it would keep writing to the old, unlinked inode.
    private static func append(_ data: Data) {
        trimIfNeeded()
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func trimIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = (attributes?[.size] as? NSNumber)?.uint64Value, size > maxBytes,
              let existing = try? Data(contentsOf: fileURL) else { return }
        let kept = LogSnapshot.tail(of: existing, maxBytes: keepBytes)
        try? kept.write(to: fileURL, options: .atomic)
    }

    private static func write(_ text: String, named name: String) -> URL? {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("Diagnostics", isDirectory: true)
        // Each share writes a fresh, timestamped file. Clearing the directory
        // first keeps temp space from accumulating one snapshot per support
        // request forever; nothing is presenting an older one at this point,
        // since the share sheet only opens once this returns.
        try? manager.removeItem(at: directory)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("[opensidecar] could not write the log snapshot: %@", error.localizedDescription)
            return nil
        }
    }
}
