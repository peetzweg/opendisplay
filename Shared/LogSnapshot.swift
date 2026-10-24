import Foundation

/// Builds the artifact someone attaches to a bug report: a short header naming
/// the build and the device, then the tail of the log file.
///
/// Deliberately pure and platform-free. The caller supplies the bytes and the
/// facts, so the formatting, the truncation boundary and the file naming are all
/// testable without a device attached.
enum LogSnapshot {
    /// How much log a snapshot carries.
    ///
    /// Sized for the two things that matter: a report needs the window around
    /// the failure, not the install's whole history, and a share sheet that
    /// hands Mail a multi-megabyte attachment gets abandoned instead of sent.
    /// The phone log is event-driven (connections, orientation, decoder
    /// trouble), so 256 KB is thousands of entries.
    static let maxBytes = 256 * 1024

    /// The facts a log line can't carry. Collected by the caller, because
    /// `UIDevice` and `Bundle` are the app's business and not this file's.
    struct Context: Equatable {
        var appVersion: String
        var appBuild: String
        /// Hardware identifier ("iPhone15,3"), not `UIDevice.model` ("iPhone").
        /// The generation is what decides whether a decoder, thermal or
        /// bandwidth theory is even plausible.
        var model: String
        var systemVersion: String
        /// The name the user set for this device, which is also how it shows up
        /// in the Mac's WiFi list, so a report can be tied to a Bonjour name.
        var deviceName: String
    }

    /// The whole artifact: header, then the newest `maxBytes` of `log`.
    static func compose(context: Context,
                        generatedAt: Date,
                        log: Data,
                        maxBytes: Int = maxBytes) -> String {
        let kept = tail(of: log, maxBytes: maxBytes)
        var out = header(context: context, generatedAt: generatedAt)
        if kept.count < log.count {
            // Rounded up: a snapshot that reports "the newest 0 KB" of itself
            // reads like a bug in the snapshot rather than a truncated log.
            let kilobytes = (kept.count + 1023) / 1024
            out += "(older entries dropped, keeping the newest \(kilobytes) KB)\n"
        }
        out += "\n"
        // Lossy decode: the cut can land mid-character, and a snapshot with one
        // replacement glyph in it beats no snapshot at all.
        let text = String(decoding: kept, as: UTF8.self)
        out += text.isEmpty ? "(no entries yet)\n" : text
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    static func header(context: Context, generatedAt: Date) -> String {
        """
        OpenDisplay diagnostics
        Generated: \(timestamp.string(from: generatedAt))
        App: \(context.appVersion) (\(context.appBuild))
        Device: \(context.model), iOS \(context.systemVersion)
        Name: \(context.deviceName)

        """
    }

    /// The newest `maxBytes` of `data`, cut at a line boundary.
    static func tail(of data: Data, maxBytes: Int = maxBytes) -> Data {
        guard maxBytes > 0 else { return Data() }
        guard data.count > maxBytes else { return Data(data) }
        let window = data.suffix(maxBytes)
        // The cut lands mid-line. Drop that partial line so the snapshot opens
        // on a real entry with a real timestamp: a half line reads as
        // corruption and invites the wrong conclusion about the log itself.
        guard let newline = window.firstIndex(of: 0x0A) else { return Data(window) }
        return Data(window[window.index(after: newline)...])
    }

    /// A filename that says what it is once it lands in someone else's inbox.
    ///
    /// `.txt` rather than `.log`: Mail, Messages and Files preview text inline,
    /// while `.log` is routinely treated as an unknown binary, and an attachment
    /// the recipient can't open is one they ask to have resent.
    static func fileName(deviceName: String, date: Date) -> String {
        let name = slug(deviceName)
        let stamp = fileStamp.string(from: date)
        return name.isEmpty ? "OpenDisplay-\(stamp).txt" : "OpenDisplay-\(name)-\(stamp).txt"
    }

    /// Device names carry apostrophes, spaces and emoji. Anything that isn't a
    /// letter or a digit becomes a single dash so the name survives every
    /// filesystem and mail client it passes through.
    private static func slug(_ name: String) -> String {
        let mapped = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f
    }()

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f
    }()
}
