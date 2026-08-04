import Foundation

/// Appends timestamped lines to /tmp/opensidecar-receiver.log (and stdout) so
/// the stream can be debugged without a debugger attached.
enum Log {
    private static let path = "/tmp/opensidecar-receiver.log"
    private static let queue = DispatchQueue(label: "log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        print(line, terminator: "")
        queue.async {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
