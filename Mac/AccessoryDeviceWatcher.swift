// AccessoryDeviceWatcher — finds Android devices on the USB cable that can
// connect through accessory mode (USBAccessory.swift), no adb needed.
//
// IOKit notifies every USB device attach and detach. An Android device is
// only recognizable by answering AOA's GET_PROTOCOL, so each new non-Apple
// device is asked once; asking changes nothing on the device. Devices join
// the controller's wired list as `aoa:<USB serial>`.
//
// Dialing resets the device and walks it into accessory mode, and closing a
// session resets it back, so a phone in use drops off the bus and returns
// within a few seconds. A detach is therefore only reported once the device
// has stayed away for `detachGrace`: a dial's own re-enumeration must not
// look like an unplug (WiFi failover, a new auto-connect).

import Foundation
import IOKit

@MainActor
final class AccessoryDeviceWatcher {
    private static let detachGrace: UInt64 = 6_000_000_000   // 6 s, in nanoseconds

    private var devices: [String: UsbmuxDevice] = [:]          // by serial
    private var serialByEntry: [UInt64: String] = [:]          // registry entry id
    private var pendingDetach: [String: Task<Void, Never>] = [:]
    // Serials that answered GET_PROTOCOL this run. Every dial and session
    // end re-enumerates the device, and a probe right after enumeration can
    // go unanswered: a known device is not asked again.
    private var capable: Set<String> = []
    // Entries whose probe is still running. A device unplugged mid-probe
    // drops out here, so a late answer cannot list a device that is gone.
    private var probing: Set<UInt64> = []
    private let onChange: ([UsbmuxDevice]) -> Void
    private let port: IONotificationPortRef
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    init(onChange: @escaping ([UsbmuxDevice]) -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let added: IOServiceMatchingCallback = { refcon, iterator in
            assumeMainActor {
                Unmanaged<AccessoryDeviceWatcher>.fromOpaque(refcon!).takeUnretainedValue()
                    .attached(iterator)
            }
        }
        let removed: IOServiceMatchingCallback = { refcon, iterator in
            assumeMainActor {
                Unmanaged<AccessoryDeviceWatcher>.fromOpaque(refcon!).takeUnretainedValue()
                    .detached(iterator)
            }
        }
        // Each call consumes one matching dictionary reference.
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                         IOServiceMatching("IOUSBHostDevice"),
                                         added, refcon, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                         IOServiceMatching("IOUSBHostDevice"),
                                         removed, refcon, &removedIterator)
        // Draining arms the notifications and picks up what is already plugged in.
        attached(addedIterator)
        detached(removedIterator)
    }

    private func attached(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            let vendor = AOA.intProperty(service, "idVendor")
            guard vendor > 0, vendor != AOA.appleVendorID,
                  AOA.intProperty(service, "bDeviceClass") != 9,   // hubs
                  let serial = AOA.stringProperty(service, "USB Serial Number") else {
                IOObjectRelease(service)
                continue
            }
            var entry: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entry)
            let name = AOA.stringProperty(service, "USB Product Name")
            if AOA.isAccessory(service) || capable.contains(serial) {
                IOObjectRelease(service)
                attach(serial: serial, name: name, entry: entry)
                continue
            }
            // The control request blocks for up to a second on a device
            // that ignores it — keep it off the main thread. A device still
            // settling after enumeration gets two more tries.
            probing.insert(entry)
            Task.detached { [entry] in
                var version: Int?
                for attempt in 0..<3 where version == nil {
                    if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
                    version = AOA.protocolVersion(of: service)
                }
                IOObjectRelease(service)
                await self.probed(serial: serial, name: name, entry: entry, capable: version != nil)
            }
        }
    }

    private func probed(serial: String, name: String?, entry: UInt64, capable: Bool) {
        guard probing.remove(entry) != nil, capable else { return }
        attach(serial: serial, name: name, entry: entry)
    }

    private func attach(serial: String, name: String?, entry: UInt64) {
        serialByEntry[entry] = serial
        capable.insert(serial)
        pendingDetach.removeValue(forKey: serial)?.cancel()
        guard devices[serial] == nil else { return }
        Log.info("Android device attached (accessory capable): \(name ?? serial)")
        devices[serial] = UsbmuxDevice(deviceID: -1, udid: AOA.udid(serial: serial), name: name)
        publish()
    }

    private func detached(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            var entry: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entry)
            IOObjectRelease(service)
            probing.remove(entry)
            guard let serial = serialByEntry.removeValue(forKey: entry),
                  devices[serial] != nil else { continue }
            pendingDetach[serial]?.cancel()
            pendingDetach[serial] = Task {
                try? await Task.sleep(nanoseconds: Self.detachGrace)
                guard !Task.isCancelled else { return }
                pendingDetach[serial] = nil
                Log.info("Android device detached: \(serial)")
                devices[serial] = nil
                publish()
            }
        }
    }

    private func publish() {
        onChange(devices.values.sorted { $0.udid < $1.udid })
    }
}
