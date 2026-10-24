// AdbParsing — the pure half of the adb client: parsing the adb server's
// replies and naming Android devices inside the wired device list. The
// socket half lives in AdbDeviceWatcher.swift; keeping this free of Network
// lets the unit tests compile it alone.

import Foundation

enum AdbParsing {
    /// One row of a `host:track-devices-l` snapshot.
    struct Device: Equatable {
        let serial: String
        let state: String     // "device" once authorized; "unauthorized", "offline", …
        let model: String?    // "Pixel 10a" (adb reports "Pixel_10a")
        let usb: Bool         // false for wireless debugging (`adb connect`, mDNS)
    }

    /// Parse one snapshot. Rows look like
    /// `67071JEA306549   device usb:17825792X product:stallion model:Pixel_10a device:stallion transport_id:7`.
    static func devices(_ payload: String) -> [Device] {
        payload.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { return nil }
            var attributes: [Substring: Substring] = [:]
            for field in fields.dropFirst(2) {
                guard let colon = field.firstIndex(of: ":") else { continue }
                attributes[field[..<colon]] = field[field.index(after: colon)...]
            }
            let model = attributes["model"].map { $0.replacingOccurrences(of: "_", with: " ") }
            return Device(serial: String(fields[0]), state: String(fields[1]),
                          model: model, usb: attributes["usb"] != nil)
        }
    }

    /// The local port of an existing `serial tcp:LOCAL tcp:REMOTE` rule in a
    /// `host:list-forward` reply, so a redial reuses it instead of piling up
    /// a new forward every retry.
    static func forwardedPort(in listing: String, serial: String, remotePort: UInt16) -> UInt16? {
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[0] == serial, fields[2] == "tcp:\(remotePort)",
                  fields[1].hasPrefix("tcp:") else { continue }
            if let port = UInt16(fields[1].dropFirst(4)) { return port }
        }
        return nil
    }

    /// The first usable line of `settings get global device_name` /
    /// `getprop ro.product.model` output. Android before 7.1 prints "null"
    /// for the unset setting.
    static func deviceName(fromShellOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "null" && !$0.contains("Exception") }
    }

    // Android devices share the wired device list (and its session ids,
    // `usb:<udid>`) with usbmuxd's iPhones and iPads. The prefix keeps the
    // two id spaces apart and tells the controller which transport to dial.
    private static let udidPrefix = "adb:"

    static func udid(serial: String) -> String { udidPrefix + serial }

    static func serial(fromUDID udid: String) -> String? {
        udid.hasPrefix(udidPrefix) ? String(udid.dropFirst(udidPrefix.count)) : nil
    }
}
