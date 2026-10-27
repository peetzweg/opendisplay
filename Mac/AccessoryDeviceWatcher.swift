// AccessoryDeviceWatcher — finds Android devices on the USB cable that can
// connect through accessory mode (USBAccessory.swift), no adb needed.
//
// An Android device is only proven by answering AOA's GET_PROTOCOL, a vendor
// request that other devices may act on (#419: a dock's Ethernet chip drops
// into a mode macOS has no driver for). So nothing is asked at device
// attach. IOKit reports every USB interface that could be an Android
// function (AndroidUSBFunction), and only that interface's device is asked,
// once. Interfaces appear after the device is configured, so it is settled
// by then. Devices join the controller's wired list as `aoa:<USB serial>`.
//
// Device attach still lists, without a request, what is known already: a
// device in accessory mode, and a serial that answered earlier this run.
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
    private static let detachGrace: Duration = .seconds(6)

    private var devices: [String: UsbmuxDevice] = [:]          // by serial
    private var serialByEntry: [UInt64: String] = [:]          // device registry entry id
    private var pendingDetach: [String: Task<Void, Never>] = [:]
    // Serials that answered GET_PROTOCOL this run. Every dial and session
    // end re-enumerates the device: a known device is not asked again.
    private var capable: Set<String> = []
    // Devices asked since they attached: a phone's MTP and adb interfaces
    // arrive separately, and it is asked once. A device unplugged mid-probe
    // drops out here, so a late answer cannot list a device that is gone.
    private var asked: Set<UInt64> = []
    private let onChange: ([UsbmuxDevice]) -> Void
    private let port: IONotificationPortRef
    private var deviceAddedIterator: io_iterator_t = 0
    private var deviceRemovedIterator: io_iterator_t = 0
    private var interfaceIterators: [io_iterator_t] = []

    init(onChange: @escaping ([UsbmuxDevice]) -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let deviceAdded: IOServiceMatchingCallback = { refcon, iterator in
            MainActor.assumeIsolated { AccessoryDeviceWatcher.from(refcon).devicesAttached(iterator) }
        }
        let deviceRemoved: IOServiceMatchingCallback = { refcon, iterator in
            MainActor.assumeIsolated { AccessoryDeviceWatcher.from(refcon).devicesDetached(iterator) }
        }
        let interfaceAdded: IOServiceMatchingCallback = { refcon, iterator in
            MainActor.assumeIsolated { AccessoryDeviceWatcher.from(refcon).interfacesAttached(iterator) }
        }
        // Each call consumes one matching dictionary reference.
        var results: [kern_return_t] = []
        results.append(IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                                        IOServiceMatching("IOUSBHostDevice"),
                                                        deviceAdded, refcon, &deviceAddedIterator))
        results.append(IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                                        IOServiceMatching("IOUSBHostDevice"),
                                                        deviceRemoved, refcon, &deviceRemovedIterator))
        for candidate in AndroidUSBFunction.candidates {
            // IOPropertyMatch, not the USB family's own interface keys: those
            // only match together with a vendor/product id.
            let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
            matching[kIOPropertyMatchKey] = [
                "bInterfaceClass": candidate.interfaceClass,
                "bInterfaceSubClass": candidate.subclass,
                "bInterfaceProtocol": candidate.protocol,
            ]
            var iterator: io_iterator_t = 0
            results.append(IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching,
                                                            interfaceAdded, refcon, &iterator))
            interfaceIterators.append(iterator)
        }
        if results.contains(where: { $0 != KERN_SUCCESS }) {
            Log.info("AOA: USB notification registration failed: \(results)")
        }
        // Draining arms the notifications and picks up what is already plugged in.
        devicesAttached(deviceAddedIterator)
        for iterator in interfaceIterators { interfacesAttached(iterator) }
        devicesDetached(deviceRemovedIterator)
    }

    private static func from(_ refcon: UnsafeMutableRawPointer?) -> AccessoryDeviceWatcher {
        Unmanaged<AccessoryDeviceWatcher>.fromOpaque(refcon!).takeUnretainedValue()
    }

    private func devicesAttached(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let name = AOA.stringProperty(service, "USB Product Name")
            guard let serial = AOA.stringProperty(service, "USB Serial Number"),
                  AOA.isAccessory(service) || capable.contains(serial) else {
                // Asked only if an Android interface follows. This line tells
                // a phone the gate missed from one that never attached.
                let vendor = AOA.intProperty(service, "idVendor")
                if vendor > 0, vendor != AOA.appleVendorID, AOA.intProperty(service, "bDeviceClass") != 9 {
                    let ids = String(format: "%04x:%04x", vendor, AOA.intProperty(service, "idProduct"))
                    Log.info("USB device attached: \(name ?? "unnamed") (\(ids))")
                }
                continue
            }
            attach(serial: serial, name: name, entry: Self.entryID(service))
        }
    }

    private func interfacesAttached(_ iterator: io_iterator_t) {
        while case let interface = IOIteratorNext(iterator), interface != 0 {
            defer { IOObjectRelease(interface) }
            guard let function = AndroidUSBFunction(
                interfaceClass: AOA.intProperty(interface, "bInterfaceClass"),
                subclass: AOA.intProperty(interface, "bInterfaceSubClass"),
                protocol: AOA.intProperty(interface, "bInterfaceProtocol"),
                name: AOA.stringProperty(interface, "kUSBString")) else { continue }
            var device: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(interface, kIOServicePlane, &device) == KERN_SUCCESS else {
                continue
            }
            probe(device, function: function)
        }
    }

    /// Takes ownership of `device`.
    private func probe(_ device: io_service_t, function: AndroidUSBFunction) {
        let entry = Self.entryID(device)
        guard IOObjectConformsTo(device, "IOUSBHostDevice") != 0,
              AOA.intProperty(device, "idVendor") != AOA.appleVendorID,
              let serial = AOA.stringProperty(device, "USB Serial Number"),
              serialByEntry[entry] == nil, !asked.contains(entry) else {
            IOObjectRelease(device)
            return
        }
        let name = AOA.stringProperty(device, "USB Product Name")
        if AOA.isAccessory(device) || capable.contains(serial) {
            IOObjectRelease(device)
            attach(serial: serial, name: name, entry: entry)
            return
        }
        Log.info("AOA: asking \(name ?? serial) for accessory support (\(function.rawValue) interface)")
        asked.insert(entry)
        // The control request blocks for up to a second on a device that
        // ignores it — keep it off the main thread. A refusal is final;
        // silence (busy, slow to answer) gets two more tries.
        Task.detached {
            var answer = AOA.ProtocolAnswer.silent
            for attempt in 0..<3 where answer == .silent {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                answer = AOA.askProtocol(device)
            }
            IOObjectRelease(device)
            await self.probed(serial: serial, name: name, entry: entry, answer: answer)
        }
    }

    private func probed(serial: String, name: String?, entry: UInt64, answer: AOA.ProtocolAnswer) {
        guard asked.contains(entry) else { return }
        guard case .version = answer else {
            Log.info("AOA: \(name ?? serial) has no accessory support (\(answer))")
            return
        }
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

    private func devicesDetached(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            let entry = Self.entryID(service)
            IOObjectRelease(service)
            asked.remove(entry)
            guard let serial = serialByEntry.removeValue(forKey: entry),
                  devices[serial] != nil else { continue }
            pendingDetach[serial]?.cancel()
            pendingDetach[serial] = Task {
                try? await Task.sleep(for: Self.detachGrace)
                guard !Task.isCancelled else { return }
                pendingDetach[serial] = nil
                Log.info("Android device detached: \(serial)")
                devices[serial] = nil
                publish()
            }
        }
    }

    private static func entryID(_ service: io_service_t) -> UInt64 {
        var entry: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entry)
        return entry
    }

    private func publish() {
        onChange(devices.values.sorted { $0.udid < $1.udid })
    }
}
