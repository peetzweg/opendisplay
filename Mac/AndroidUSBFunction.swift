import Foundation

/// The USB interfaces that make a device look like Android, and so worth
/// asking for accessory mode (#419).
///
/// Only an answer to AOA's GET_PROTOCOL proves Android, but that is a vendor
/// request, and a vendor request means whatever the device's firmware makes
/// of it: an ASIX AX88179A (USB Ethernet in many USB-C docks) stalls it and
/// then re-enumerates in a vendor mode macOS has no driver for, taking the
/// network down until it is unplugged. So a device is only asked when one of
/// its interfaces is an everyday Android function. Measured on a Pixel 10a:
///
///     USB debugging on            FF/42/01  "ADB Interface"
///     file transfer               06/01/01  "MTP"
///     PTP                         06/01/01  (no name)
///     MIDI                        01/01/00  "MIDI function", 01/03/00
///
/// Older kernels (f_mtp) put MTP in the vendor class: FF/FF/00 "MTP". PTP
/// is exactly what a camera looks like, so it does not count; neither do
/// MIDI and tethering. Android drops back to its default mode on the next
/// plug, which shows MTP or adb.
enum AndroidUSBFunction: String {
    case adb
    case mtp

    /// Class/subclass/protocol triples to watch for; `init` has the final say.
    static let candidates: [(interfaceClass: Int, subclass: Int, protocol: Int)] = [
        (0xFF, 0x42, 0x01),
        (0x06, 0x01, 0x01),
        (0xFF, 0xFF, 0x00),
    ]

    init?(interfaceClass: Int, subclass: Int, protocol: Int, name: String?) {
        let mtpName = name?.uppercased().contains("MTP") ?? false   // libmtp's test
        switch (interfaceClass, subclass, `protocol`) {
        case (0xFF, 0x42, 0x01):
            self = .adb
        case (0x06, 0x01, 0x01) where mtpName, (0xFF, 0xFF, 0x00) where mtpName:
            self = .mtp
        default:
            return nil
        }
    }
}
