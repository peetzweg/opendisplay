// AOA transport for Android over USB, no adb.
//
// The host puts the device into accessory mode with three vendor control
// transfers; it drops off the bus and comes back with Google's vendor id
// and a bulk IN/OUT pair — a byte stream, which is all this protocol needs.

import Foundation
import IOKit
import IOUSBHost
import os

enum AOA {
    /// Control requests, from the AOA spec.
    static let getProtocol: UInt8 = 51
    static let sendString: UInt8 = 52
    static let start: UInt8 = 53

    /// bmRequestType: vendor request addressed to the device itself.
    static let vendorIn: UInt8 = 0xC0
    static let vendorOut: UInt8 = 0x40

    static let googleVendorID = 0x18D1
    /// 2D00 = accessory only; 2D01 = accessory + adb (USB debugging on).
    static let accessoryProductIDs: Set<Int> = [0x2D00, 0x2D01]

    static let appleVendorID = 0x05AC

    /// Sent as strings 0...5 during the handshake. Must match the Android
    /// app's `res/xml/accessory_filter.xml` byte for byte, or the OS never
    /// offers the app even though the handshake succeeds.
    static let identity = [
        "OpenDisplay",                                          // manufacturer
        "OpenDisplay Receiver",                                 // model
        "Second display over USB",                              // description
        "1.0",                                                  // version
        "https://github.com/josepacelli/opendisplay-android",   // URI
        "0001",                                                 // serial
    ]

    /// Covers slow re-enumeration plus the user reading the accessory dialog
    /// on first plug.
    static let reenumerationTimeout: TimeInterval = 15

    enum Failure: LocalizedError {
        case noCandidate
        case notSupported
        case timedOut
        case noInterface

        var errorDescription: String? {
            switch self {
            case .noCandidate: "No USB device that could be an Android phone or tablet"
            case .notSupported: "This device does not support USB accessory mode"
            case .timedOut: "The device did not come back in accessory mode"
            case .noInterface: "The accessory exposes no bulk endpoints"
            }
        }
    }
}

/// `ByteStream` over bulk endpoints. Reads are packet-oriented, not exact —
/// `pending` accumulates until `receive(exactly:)` has enough.
final class AccessoryByteStream: ByteStream {
    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let packetSize: Int

    // Separate queues: a read parks waiting for data and must not block a
    // pending write.
    private let readQueue = DispatchQueue(label: "opendisplay.aoa.read")
    private let writeQueue = DispatchQueue(label: "opendisplay.aoa.write")

    /// Bytes read but not yet claimed. Touched only on `readQueue`.
    private var pending = Data()

    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(interface: IOUSBHostInterface,
         inPipe: IOUSBHostPipe, outPipe: IOUSBHostPipe, packetSize: Int) {
        self.interface = interface
        self.inPipe = inPipe
        self.outPipe = outPipe
        self.packetSize = max(packetSize, 512)
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        writeQueue.async { [weak self] in
            guard let self, !self.isCancelled else {
                completion(AOA.Failure.timedOut)
                return
            }
            let buffer = NSMutableData(data: data)
            var transferred = 0
            do {
                try self.outPipe.__sendIORequest(with: buffer,
                                                 bytesTransferred: &transferred,
                                                 completionTimeout: 5)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func receive(exactly count: Int, completion: @escaping (Data?) -> Void) {
        readQueue.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            while self.pending.count < count {
                guard !self.isCancelled, self.pullPacket() else {
                    completion(nil)
                    return
                }
            }
            let claimed = self.pending.prefix(count)
            self.pending.removeFirst(count)
            completion(Data(claimed))
        }
    }

    /// One bulk read. False when the pipe is done — cable pulled, accessory
    /// closed, or `cancel()`.
    private func pullPacket() -> Bool {
        let packet = NSMutableData(length: packetSize)!
        var transferred = 0
        do {
            // No timeout: idle is normal. cancel() aborts this read.
            try inPipe.__sendIORequest(with: packet, bytesTransferred: &transferred,
                                       completionTimeout: 0)
        } catch {
            if !isCancelled { Log.info("accessory read ended: \(error)") }
            return false
        }
        guard transferred > 0 else { return true }   // zero-length packet: benign
        pending.append((packet as Data).prefix(transferred))
        return true
    }

    private var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() {
        let alreadyCancelled = cancelled.withLock { state -> Bool in
            defer { state = true }
            return state
        }
        guard !alreadyCancelled else { return }
        // Abort unblocks a parked read; destroy() would otherwise hang on it.
        try? inPipe.__abort(with: .synchronous)
        try? outPipe.__abort(with: .synchronous)
        interface.destroy()
    }
}

/// Finds an Android device, walks it into accessory mode, and waits for it
/// to re-enumerate. Stateful because the device leaves the bus after START —
/// recovery is an IOKit match notification, which may never fire if the
/// user dismisses the accessory dialog.
final class AndroidAccessoryConnector {
    private let queue: DispatchQueue
    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var completion: ((Result<AccessoryByteStream, Error>) -> Void)?
    private var timeout: DispatchWorkItem?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Calls back exactly once, on `queue`.
    func connect(completion: @escaping (Result<AccessoryByteStream, Error>) -> Void) {
        self.completion = completion

        // Already in accessory mode (previous run, or another host) — skip
        // the handshake, it's a no-op on an accessory.
        if let service = firstAccessory() {
            defer { IOObjectRelease(service) }
            finish(openStream(on: service))
            return
        }

        guard let candidate = firstAOACapableDevice() else {
            finish(.failure(AOA.Failure.noCandidate))
            return
        }
        defer { IOObjectRelease(candidate) }

        // Arm before the handshake — re-enumeration can be faster than we'd
        // arm it afterwards.
        watchForAccessory()

        do {
            try performHandshake(on: candidate)
        } catch {
            finish(.failure(error))
        }
    }

    private func matchingDictionary(vendorID: Int? = nil) -> NSMutableDictionary? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else {
            return nil
        }
        // idVendor goes under kIOPropertyMatchKey — at the top level it's
        // silently accepted and never matches anything.
        if let vendorID { matching[kIOPropertyMatchKey] = ["idVendor": vendorID] }
        return matching
    }

    private func services(matching dictionary: NSMutableDictionary) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            found.append(service)
        }
        return found
    }

    private func firstAccessory() -> io_service_t? {
        guard let dictionary = matchingDictionary(vendorID: AOA.googleVendorID) else { return nil }
        let all = services(matching: dictionary)
        var match: io_service_t?
        for service in all {
            if match == nil, AOA.accessoryProductIDs.contains(Self.property(service, "idProduct")) {
                match = service
            } else {
                IOObjectRelease(service)
            }
        }
        return match
    }

    /// GET_PROTOCOL is the only way to know a device speaks AOA. Skips Apple
    /// devices — they never answer.
    private func firstAOACapableDevice() -> io_service_t? {
        guard let dictionary = matchingDictionary() else { return nil }
        var chosen: io_service_t?
        for service in services(matching: dictionary) {
            let vendor = Self.property(service, "idVendor")
            if chosen != nil || vendor == AOA.appleVendorID || vendor <= 0 {
                IOObjectRelease(service)
                continue
            }
            if (try? protocolVersion(of: service)).map({ $0 >= 1 }) == true {
                chosen = service
            } else {
                IOObjectRelease(service)
            }
        }
        return chosen
    }

    private static func property(_ service: io_service_t, _ key: String) -> Int {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else { return -1 }
        return value.intValue
    }

    private static func request(_ type: UInt8, _ code: UInt8,
                                index: UInt16 = 0, length: UInt16 = 0) -> IOUSBDeviceRequest {
        IOUSBDeviceRequest(bmRequestType: type, bRequest: code,
                           wValue: 0, wIndex: index, wLength: length)
    }

    private func protocolVersion(of service: io_service_t) throws -> UInt16 {
        let device = try IOUSBHostDevice(__ioService: service, options: [],
                                         queue: nil, interestHandler: nil)
        defer { device.destroy() }
        let data = NSMutableData(length: 2)!
        var transferred = 0
        try device.__send(Self.request(AOA.vendorIn, AOA.getProtocol, length: 2),
                          data: data, bytesTransferred: &transferred, completionTimeout: 1)
        return data.bytes.load(as: UInt16.self)
    }

    private func performHandshake(on service: io_service_t) throws {
        let device = try IOUSBHostDevice(__ioService: service, options: [],
                                         queue: nil, interestHandler: nil)
        defer { device.destroy() }

        for (index, value) in AOA.identity.enumerated() {
            let bytes = NSMutableData(data: Data(value.utf8) + [0])   // null-terminated
            var transferred = 0
            try device.__send(
                Self.request(AOA.vendorOut, AOA.sendString,
                             index: UInt16(index), length: UInt16(bytes.length)),
                data: bytes, bytesTransferred: &transferred, completionTimeout: 1)
        }
        Log.info("AOA: identity sent, requesting accessory mode")
        // The device disappears from the bus on this one.
        try device.__send(Self.request(AOA.vendorOut, AOA.start),
                          data: nil as NSMutableData?,
                          bytesTransferred: nil as UnsafeMutablePointer<Int>?,
                          completionTimeout: 1)
    }

    private func watchForAccessory() {
        guard let dictionary = matchingDictionary(vendorID: AOA.googleVendorID) else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, queue)
        notifyPort = port

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Log.info("AOA: match callback fired")
            Unmanaged<AndroidAccessoryConnector>.fromOpaque(refcon)
                .takeUnretainedValue()
                .accessoryAppeared(iterator)
        }
        // IOServiceAddMatchingNotification consumes the dictionary reference;
        // Swift's bridge hands it a +0 one, so passRetained is required or
        // the notification silently never fires.
        let retained = Unmanaged.passRetained(dictionary as CFDictionary).takeUnretainedValue()
        let armed = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                                     retained, callback, context, &matchIterator)
        Log.info("AOA: watching for 18D1 devices (arm=\(armed), iterator=\(matchIterator))")
        // Draining the iterator is what arms the notification, and catches a
        // device that showed up between the check above and here.
        accessoryAppeared(matchIterator)

        let deadline = DispatchWorkItem { [weak self] in
            self?.finish(.failure(AOA.Failure.timedOut))
        }
        timeout = deadline
        queue.asyncAfter(deadline: .now() + AOA.reenumerationTimeout, execute: deadline)
    }

    private func accessoryAppeared(_ iterator: io_iterator_t) {
        var claimed: io_service_t?
        var seen: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let pid = Self.property(service, "idProduct")
            seen.append(String(format: "%04X", pid))
            if claimed == nil, AOA.accessoryProductIDs.contains(pid) {
                claimed = service
            } else {
                IOObjectRelease(service)
            }
        }
        if !seen.isEmpty {
            Log.info("AOA: match notification saw \(seen.joined(separator: ", "))")
        }
        guard let service = claimed else { return }
        guard completion != nil else {            // already finished
            IOObjectRelease(service)
            return
        }
        Log.info("AOA: accessory re-enumerated")
        openWhenInterfaceAppears(on: service, attemptsLeft: Self.interfaceAttempts)
    }

    /// The device's `IOUSBHostInterface` child is published a moment after
    /// the device itself — retry briefly rather than fail, since a real
    /// absence and not-yet-published look identical.
    private func openWhenInterfaceAppears(on service: io_service_t, attemptsLeft: Int) {
        let probe = Self.firstInterface(under: service)
        if let probe { IOObjectRelease(probe) }
        if probe == nil, attemptsLeft > 0 {
            queue.asyncAfter(deadline: .now() + Self.interfaceRetryDelay) { [weak self] in
                guard let self, self.completion != nil else {
                    IOObjectRelease(service)
                    return
                }
                self.openWhenInterfaceAppears(on: service, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        defer { IOObjectRelease(service) }
        finish(openStream(on: service))
    }

    private static let interfaceAttempts = 20
    private static let interfaceRetryDelay: TimeInterval = 0.1

    private func openStream(on service: io_service_t) -> Result<AccessoryByteStream, Error> {
        do {
            // Open only the interface, not the device — opening both fights
            // for the same exclusive claim and fails intermittently.
            guard let interfaceService = Self.firstInterface(under: service) else {
                return .failure(AOA.Failure.noInterface)
            }
            defer { IOObjectRelease(interfaceService) }

            let interface = try IOUSBHostInterface(__ioService: interfaceService, options: [],
                                                   queue: nil, interestHandler: nil)
            // Accessory mode's one bulk IN/OUT pair, at the standard addresses.
            let inPipe = try interface.copyPipe(withAddress: 0x81)
            let outPipe = try interface.copyPipe(withAddress: 0x01)
            Log.info("AOA: bulk pipes open — accessory transport ready")
            return .success(AccessoryByteStream(interface: interface,
                                                inPipe: inPipe, outPipe: outPipe,
                                                packetSize: 512))
        } catch {
            return .failure(error)
        }
    }

    private static func firstInterface(under device: io_service_t) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 { return child }
            IOObjectRelease(child)
        }
        return nil
    }

    /// Delivers the result once and tears down the watch — every exit path
    /// goes through here so a late notification can't call back twice.
    private func finish(_ result: Result<AccessoryByteStream, Error>) {
        guard let handler = completion else { return }
        completion = nil
        timeout?.cancel()
        timeout = nil
        if matchIterator != 0 {
            IOObjectRelease(matchIterator)
            matchIterator = 0
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
        handler(result)
    }

    deinit {
        if matchIterator != 0 { IOObjectRelease(matchIterator) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
    }
}
