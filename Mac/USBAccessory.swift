// USBAccessory — Android over the USB cable with no adb and no developer
// mode, through Android Open Accessory (AOA).
//
// Any Android device answers three vendor control requests: GET_PROTOCOL,
// SEND_STRING (our identity) and START. On START it drops off the bus and
// comes back as an "accessory" (Google's vendor id, product 0x2D00, or
// 0x2D01 with USB debugging on) with one bulk IN/OUT pair, and Android
// launches the app whose accessory_filter.xml matches the identity, asking
// the user once ("Always open").
//
// The bulk pair is a byte stream, which is all the protocol needs, so the
// sender keeps its NWConnection pipeline unchanged: a relay accepts one
// loopback TCP connection and pumps it to and from the pipes. One accessory attachment is one session. The relay ends
// it by resetting the device, which drops the phone back to its normal USB
// mode (file transfer works again) and tells the receiver the session is
// over; the next dial starts with a fresh handshake.
//
// The phone's kernel keeps one 16 KB OUT request in flight, so a write that
// ends on a packet boundary but not on a request boundary would wait for
// more data: every such write is followed by a zero-length packet
// (measurements in research/wired-android-aoa.md).

import Foundation
import IOKit
import IOUSBHost
import Network
import os

enum AOA {
    static let googleVendorID = 0x18D1
    static let appleVendorID = 0x05AC
    /// 0x2D00 = accessory only; 0x2D01 = accessory + adb (USB debugging on).
    static let accessoryProductIDs: Set<Int> = [0x2D00, 0x2D01]

    /// Control requests, from the AOA spec.
    static let getProtocol: UInt8 = 51
    static let sendString: UInt8 = 52
    static let start: UInt8 = 53

    /// Sent as strings 0...5 during the handshake. Manufacturer and model
    /// must match the receiver's accessory_filter.xml; the URI is what
    /// Android offers when no installed app matches.
    static let identity = [
        "OpenDisplay",                  // manufacturer
        "OpenDisplay Receiver",         // model
        "Second display over USB",      // description
        "1",                            // version
        "https://opendisplay.app",      // URI
        "1",                            // serial
    ]

    static let udidPrefix = "aoa:"
    static func udid(serial: String) -> String { udidPrefix + serial }
    static func serial(fromUDID udid: String) -> String? {
        udid.hasPrefix(udidPrefix) ? String(udid.dropFirst(udidPrefix.count)) : nil
    }

    enum Failure: Error, LocalizedError {
        case noDevice          // the serial is not attached
        case notSupported      // the device does not speak AOA
        case notAccessory      // START sent, but it never came back as an accessory (locked?)
        case noApp             // accessory up, but the receiver never said hello
        case noInterface

        var errorDescription: String? {
            switch self {
            case .noDevice: return String(localized: "Android device not attached")
            case .notSupported: return "device does not support USB accessory mode"
            case .notAccessory: return "device did not switch to accessory mode"
            case .noApp: return String(localized: "OpenDisplay did not open on the device")
            case .noInterface: return "accessory exposes no bulk endpoints"
            }
        }
    }

    /// Re-enumeration after START or a reset takes 1-3 s on a Pixel.
    private static let reenumerationTimeout: Duration = .seconds(10)
    /// Covers a cold app launch, and the consent dialog on first plug.
    private static let helloTimeout: TimeInterval = 30

    /// Dials are serialized per device: each one resets and re-handshakes
    /// it, and a superseded dial must not reset a newer session's device.
    private static let dialLock = SerialLock()

    /// Walk the device into accessory mode and connect to its receiver
    /// through a loopback relay. Returns the receiver's first message
    /// (hello): only that proves the app is up behind the pipes.
    static func dial(serial: String, queue: DispatchQueue) async throws -> (NWConnection, Data) {
        await dialLock.acquire(serial)
        defer { Task { await dialLock.release(serial) } }
        // Superseded while queued behind another dial: closing the relay
        // below would end the newer session.
        try Task.checkCancellation()

        AccessoryRelay.close(serial: serial)
        guard var device = try await waitForDevice(serial: serial, timeout: .seconds(5)) else {
            throw Failure.noDevice
        }
        // Already an accessory: left over from an earlier session (the
        // relay just closed, a crashed sender, the app restarted on the
        // phone). Its stream state is stale and the receiver only starts
        // clean on a fresh attach, so reset it back to normal mode first.
        if device.isAccessory {
            reset(device.service)
            device.release()
            guard let normal = try await waitForDevice(serial: serial, accessory: false,
                                                       timeout: reenumerationTimeout) else {
                throw Failure.notAccessory
            }
            device = normal
        }
        device.release()
        // A locked Pixel ignores START until it is unlocked, so the handshake
        // repeats every 2 s until the device re-enumerates or time runs out:
        // unlocking then connects within seconds instead of after a timeout.
        var found: Device?
        let deadline = ContinuousClock.now + reenumerationTimeout
        while found == nil, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let current = findDevice(serial: serial) {
                if current.isAccessory {
                    found = current
                    break
                }
                // A device mid re-enumeration may not answer; the next round asks again.
                try? handshake(current.service)
                current.release()
            }
            found = try await waitForDevice(serial: serial, accessory: true, timeout: .seconds(2))
        }
        guard let accessory = found else { throw Failure.notAccessory }
        defer { accessory.release() }
        let relay: AccessoryRelay
        do {
            relay = try await AccessoryRelay.open(device: accessory.service, serial: serial)
        } catch {
            reset(accessory.service)
            throw error
        }
        do {
            return try await relay.connect(queue: queue, helloTimeout: helloTimeout)
        } catch {
            relay.close()
            throw error
        }
    }

    // MARK: - Device discovery

    struct Device {
        let service: io_service_t
        let isAccessory: Bool
        func release() { IOObjectRelease(service) }
    }

    /// The attached device with this USB serial number. The serial survives
    /// the switch into accessory mode, so it names the phone across both.
    static func findDevice(serial: String) -> Device? {
        var found: Device?
        forEachDevice { service in
            guard found == nil, stringProperty(service, "USB Serial Number") == serial else {
                return false
            }
            found = Device(service: service, isAccessory: isAccessory(service))
            return true
        }
        return found
    }

    static func isAccessory(_ service: io_service_t) -> Bool {
        intProperty(service, "idVendor") == googleVendorID
            && accessoryProductIDs.contains(intProperty(service, "idProduct"))
    }

    private static func waitForDevice(serial: String, accessory: Bool? = nil,
                                      timeout: Duration) async throws -> Device? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let device = findDevice(serial: serial) {
                if accessory == nil || device.isAccessory == accessory { return device }
                device.release()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Calls `body` with every USB device; it returns true to keep (own)
    /// the service, false to have it released.
    static func forEachDevice(_ body: (io_service_t) -> Bool) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            if !body(service) { IOObjectRelease(service) }
        }
    }

    static func intProperty(_ service: io_service_t, _ key: String) -> Int {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue ?? -1
    }

    static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    // MARK: - Control requests

    private static func request(_ type: UInt8, _ code: UInt8,
                                index: UInt16 = 0, length: UInt16 = 0) -> IOUSBDeviceRequest {
        IOUSBDeviceRequest(bmRequestType: type, bRequest: code, wValue: 0, wIndex: index, wLength: length)
    }

    enum ProtocolAnswer: Equatable {
        case version(Int)   // AOA 1 or 2
        case refused        // stalled, or answered 0: not an Android device
        case silent         // could not be opened, or no reply in time
    }

    /// kUSBHostReturnPipeStalled: the device rejected the request.
    private static let pipeStalled: UInt32 = 0xE000_5000

    /// GET_PROTOCOL, the only way to tell an Android device from any other.
    /// It is a vendor request, which some devices act on (#419): only send it
    /// to a device that shows an AndroidUSBFunction.
    static func askProtocol(_ service: io_service_t) -> ProtocolAnswer {
        guard let device = try? IOUSBHostDevice(__ioService: service, options: [],
                                                queue: nil, interestHandler: nil) else { return .silent }
        defer { device.destroy() }
        let data = NSMutableData(length: 2)!
        var transferred = 0
        do {
            try device.__send(request(0xC0, getProtocol, length: 2), data: data,
                              bytesTransferred: &transferred, completionTimeout: 1)
        } catch {
            return UInt32(truncatingIfNeeded: (error as NSError).code) == pipeStalled ? .refused : .silent
        }
        guard transferred == 2 else { return .refused }
        let version = Int(UInt16(littleEndian: data.bytes.loadUnaligned(as: UInt16.self)))
        return version >= 1 ? .version(version) : .refused
    }

    private static func handshake(_ service: io_service_t) throws {
        guard case .version = askProtocol(service) else { throw Failure.notSupported }
        let device = try IOUSBHostDevice(__ioService: service, options: [],
                                         queue: nil, interestHandler: nil)
        defer { device.destroy() }
        var transferred = 0
        for (index, value) in identity.enumerated() {
            let bytes = NSMutableData(data: Data(value.utf8) + [0])   // null-terminated
            try device.__send(request(0x40, sendString, index: UInt16(index),
                                      length: UInt16(bytes.length)),
                              data: bytes, bytesTransferred: &transferred, completionTimeout: 1)
        }
        // The device leaves the bus on this one, sometimes before the status
        // stage completes: the caller's wait for the accessory is the verdict.
        try? device.__send(request(0x40, start), data: nil as NSMutableData?,
                           bytesTransferred: nil as UnsafeMutablePointer<Int>?, completionTimeout: 1)
        Log.info("AOA: accessory mode requested")
    }

    /// Reset the device: an accessory drops back to its normal USB mode.
    /// IOUSBHost reports an error even when it worked (the device is gone
    /// before the reply), so the result is not checked.
    static func reset(_ service: io_service_t) {
        guard let device = try? IOUSBHostDevice(__ioService: service, options: [],
                                                queue: nil, interestHandler: nil) else { return }
        try? device.reset()
        device.destroy()
    }
}

/// Bridges one loopback TCP connection to the accessory's bulk pipes.
final class AccessoryRelay {
    private static let live = OSAllocatedUnfairLock(initialState: [String: AccessoryRelay]())

    /// End the relay serving this device, if any, resetting the device.
    static func close(serial: String) {
        live.withLock { $0[serial] }?.close()
    }

    private let serial: String
    private let service: io_service_t
    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let maxPacket: Int
    private let listener: NWListener
    private var accepted: NWConnection?   // networkQueue

    // Blocking pipe I/O, one thread per direction: a parked read must not
    // hold up writes.
    private let readQueue = DispatchQueue(label: "aoa.relay.read")
    private let writeQueue = DispatchQueue(label: "aoa.relay.write")
    private let networkQueue = DispatchQueue(label: "aoa.relay.net")
    private let closed = OSAllocatedUnfairLock(initialState: false)

    private init(serial: String, service: io_service_t, interface: IOUSBHostInterface,
                 inPipe: IOUSBHostPipe, outPipe: IOUSBHostPipe, maxPacket: Int,
                 listener: NWListener) {
        self.serial = serial
        self.service = service
        self.interface = interface
        self.inPipe = inPipe
        self.outPipe = outPipe
        self.maxPacket = maxPacket
        self.listener = listener
        IOObjectRetain(service)
    }

    /// Claim the accessory interface. Its IOUSBHostInterface is published a
    /// moment after the device, so absence is retried briefly.
    static func open(device: io_service_t, serial: String) async throws -> AccessoryRelay {
        for _ in 0..<20 {
            if let relay = try claim(device: device, serial: serial) {
                live.withLock { $0[serial] = relay }
                return relay
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AOA.Failure.noInterface
    }

    private static func claim(device: io_service_t, serial: String) throws -> AccessoryRelay? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            // The accessory interface is vendor class 0xFF/0xFF; with USB
            // debugging on, adb's 0xFF/0x42 sits next to it.
            guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
                  AOA.intProperty(child, "bInterfaceClass") == 0xFF,
                  AOA.intProperty(child, "bInterfaceSubClass") == 0xFF else { continue }
            let interface = try IOUSBHostInterface(__ioService: child, options: [],
                                                   queue: nil, interestHandler: nil)
            var inPipe: IOUSBHostPipe?, outPipe: IOUSBHostPipe?
            for address in 1...15 {
                if inPipe == nil { inPipe = try? interface.copyPipe(withAddress: 0x80 | address) }
                if outPipe == nil { outPipe = try? interface.copyPipe(withAddress: address) }
            }
            guard let inPipe, let outPipe else {
                interface.destroy()
                throw AOA.Failure.noInterface
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            return AccessoryRelay(
                serial: serial, service: device, interface: interface,
                inPipe: inPipe, outPipe: outPipe,
                maxPacket: Int(outPipe.descriptors.pointee.descriptor.wMaxPacketSize),
                listener: listener)
        }
        return nil
    }

    /// Start relaying and dial it. The receiver opens with hello; waiting
    /// for it tells a launched app from a dismissed consent dialog.
    func connect(queue: DispatchQueue, helloTimeout: TimeInterval) async throws -> (NWConnection, Data) {
        let port = try await listen()
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        let conn = NWConnection(host: .ipv4(.loopback), port: port,
                                using: NWParameters(tls: nil, tcp: options))
        let deadline = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + helloTimeout, execute: deadline)
        defer { deadline.cancel() }
        do {
            // A superseded dial (the session stopped or moved on) gives up
            // at once instead of holding the device until the deadline.
            return try await withTaskCancellationHandler {
                try await Self.start(conn, queue: queue)
                let header = try await Self.receive(exactly: 4, on: conn)
                let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                guard length > 0, length < 1 << 20 else { throw AOA.Failure.noApp }
                return (conn, try await Self.receive(exactly: length, on: conn))
            } onCancel: {
                conn.cancel()
            }
        } catch {
            conn.cancel()
            throw Task.isCancelled ? CancellationError() : AOA.Failure.noApp
        }
    }

    private static func start(_ conn: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false   // the handler fires on `queue` (serial)
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed(let error), .waiting(let error):
                    // Loopback has no path changes to wait for.
                    resumed = true
                    conn.cancel()
                    cont.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        conn.stateUpdateHandler = nil
    }

    private static func receive(exactly count: Int, on conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: error ?? AOA.Failure.noApp)
                }
            }
        }
    }

    private func listen() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resume: (Result<NWEndpoint.Port, Error>) -> Void = { result in
                guard !resumed.withLock({ done in let was = done; done = true; return was }) else { return }
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port { resume(.success(port)) }
                case .failed(let error):
                    resume(.failure(error))
                    self?.close()
                case .cancelled:
                    resume(.failure(AOA.Failure.noApp))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self, self.accepted == nil else {
                    conn.cancel()
                    return
                }
                self.accepted = conn
                self.listener.cancel()   // one connection per attachment
                conn.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.pumpToDevice(conn)
                        self?.readQueue.async { self?.pumpFromDevice(conn) }
                    case .failed, .cancelled:
                        self?.close()
                    default:
                        break
                    }
                }
                conn.start(queue: self.networkQueue)
            }
            listener.start(queue: networkQueue)
        }
    }

    /// Sender → phone. The next receive waits for the write, so a phone
    /// that stops reading backs the sender's socket up as TCP would.
    private func pumpToDevice(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, !data.isEmpty else {
                if isComplete || error != nil { self.close() } else { self.pumpToDevice(conn) }
                return
            }
            self.writeQueue.async {
                guard self.write(data) else { return self.close() }
                if isComplete { self.close() } else { self.pumpToDevice(conn) }
            }
        }
    }

    private func write(_ data: Data) -> Bool {
        var transferred = 0
        do {
            // No timeout: a phone that stops reading is the session
            // watchdog's call, and close() aborts a parked write.
            try outPipe.__sendIORequest(with: NSMutableData(data: data), bytesTransferred: &transferred,
                                        completionTimeout: 0)
            if data.count % maxPacket == 0 {
                try outPipe.__sendIORequest(with: NSMutableData(), bytesTransferred: &transferred,
                                            completionTimeout: 0)
            }
            return true
        } catch {
            if !isClosed { Log.info("AOA: write failed: \(error.localizedDescription)") }
            return false
        }
    }

    /// Phone → sender, until the pipe ends (reset, unplug, close()).
    private func pumpFromDevice(_ conn: NWConnection) {
        let buffer = NSMutableData(length: 16 * 1024)!
        while !isClosed {
            var transferred = 0
            do {
                try inPipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: 0)
            } catch {
                if !isClosed { Log.info("AOA: read ended: \(error.localizedDescription)") }
                break
            }
            guard transferred > 0 else { continue }   // zero-length packet
            conn.send(content: Data(bytes: buffer.bytes, count: transferred),
                      completion: .contentProcessed { _ in })
        }
        close()
    }

    private var isClosed: Bool { closed.withLock { $0 } }

    /// End the session: drop the socket, release the pipes and reset the
    /// device so the phone leaves accessory mode. Idempotent.
    func close() {
        guard !closed.withLock({ done in let was = done; done = true; return was }) else { return }
        AccessoryRelay.live.withLock { live in
            if live[serial] === self { live[serial] = nil }
        }
        listener.cancel()
        networkQueue.async { self.accepted?.cancel() }
        try? inPipe.__abort(with: .synchronous)
        try? outPipe.__abort(with: .synchronous)
        interface.destroy()
        AOA.reset(service)
        IOObjectRelease(service)
        Log.info("AOA: session with \(serial) closed")
    }
}

/// Async mutual exclusion per key, with no reentrancy across awaits
/// (an actor alone would interleave two dials at their first await).
private actor SerialLock {
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: String) async {
        guard held.contains(key) else {
            held.insert(key)
            return
        }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()   // ownership passes straight to the next dial
        } else {
            held.remove(key)
        }
    }
}
