// MacReceiver — the reverse direction (issue #122, iPad -> Mac).
//
// The Mac LISTENS and renders; the device's broadcast extension dials and
// streams. Same wire format as the forward direction — [4-byte big-endian
// length][Annex B payload], JSON control frames on the same channel — but
// advertised under its own Bonjour type (ReverseWire.serviceType) so the
// forward-direction browser and this listener never confuse their roles.
//
// Pipeline:  NWListener -> deframe -> Annex B parse -> CMSampleBuffer
//            -> AVSampleBufferDisplayLayer in a regular NSWindow
//
// Display-only by design: iPadOS offers no public API to inject touches or
// create virtual displays, so this mirrors the device's screen; it cannot
// extend it or control it.

import AppKit
import AVFoundation
import CoreMedia
import Network
import SwiftUI

/// Owns the listener and one window per streaming device. Enabled from the
/// control panel; off by default so the Mac doesn't advertise a service the
/// user never asked for.
@MainActor
final class MacReceiverController: ObservableObject {
    static let shared = MacReceiverController()

    @Published var enabled = UserDefaults.standard.bool(forKey: "receiverEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "receiverEnabled")
            enabled ? start() : stop()
        }
    }
    @Published var status = "Off"
    @Published var sessions: [MacReceiverSession] = []

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mac.receiver.listener")

    private init() {
        if enabled { start() }
    }

    private var advertisedService: NWListener.Service {
        var txt = NWTXTRecord()
        txt["pv"] = String(WireProtocol.version)
        return NWListener.Service(name: Host.current().localizedName ?? "Mac",
                                  type: ReverseWire.serviceType,
                                  domain: nil, txtRecord: txt)
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.serviceClass = .interactiveVideo
            // No fixed port: Bonjour advertises whatever the system assigns,
            // so we can't collide with the forward direction's :9000.
            listener = try NWListener(using: params)
        } catch {
            status = "Failed: \(error.localizedDescription)"
            return
        }
        listener?.service = advertisedService
        listener?.newConnectionHandler = { [weak self] conn in
            DispatchQueue.main.async { self?.accept(conn) }
        }
        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready: self?.status = "Waiting for a device…"
                case .failed(let error): self?.status = "Failed: \(error)"
                case .cancelled: self?.status = "Off"
                default: break
                }
            }
        }
        listener?.start(queue: queue)
        Log.info("receiver: listening for \(ReverseWire.serviceType)")
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        sessions.forEach { $0.close() }
        sessions.removeAll()
        status = "Off"
    }

    private func accept(_ conn: NWConnection) {
        Log.info("receiver: connection from \(String(describing: conn.endpoint))")
        let session = MacReceiverSession(connection: conn)
        session.onEnded = { [weak self, weak session] in
            guard let self, let session else { return }
            self.sessions.removeAll { $0 === session }
            if self.enabled, self.sessions.isEmpty { self.status = "Waiting for a device…" }
        }
        session.onStreaming = { [weak self, weak session] in
            guard let self, let session else { return }
            self.status = "Receiving from \(session.deviceName)"
        }
        sessions.append(session)
        session.start()
    }
}

/// One inbound stream: socket, decoder state, and its window on screen.
/// Same confinement style as PhoneReceiver: pipeline state lives on `queue`,
/// UI (published properties + the window) on the main thread.
final class MacReceiverSession: ObservableObject, Identifiable {
    @Published var deviceName = "iPad"
    @Published var videoSize = CGSize.zero
    @Published var fps = 0

    // Both invoked on the main thread.
    var onEnded: (() -> Void)?
    var onStreaming: (() -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mac.receiver.session")
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var window: NSWindow?              // main thread only
    private var windowDelegate: WindowDelegate?

    // Deframing + decoder state (owned by `queue`).
    private var buffer = Data()
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var closed = false                 // main thread only

    // The device streams only while pixels change; ping/pong keeps the pair
    // honest through static screens. Cancel-and-replace timers per the repo
    // standard — no self-rescheduling asyncAfter chains.
    private var pingTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var lastDataReceived = Date()
    private var lastKeyframeRequest = Date.distantPast

    // Rotation: ReplayKit stamps each frame with a CGImagePropertyOrientation;
    // the sender forwards it in the telemetry prefix ("or"). Applied as a
    // transform on the display layer. EXIF values: 1 up, 3 down, 6 right
    // (needs 90° CW), 8 left (needs 90° CCW).
    private var orientationRaw = 1

    private var framesThisWindow = 0
    private var fpsWindowStart = Date()

    init(connection: NWConnection) {
        self.connection = connection
        displayLayer.videoGravity = .resizeAspect
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendControl(["type": WireMessage.welcome,
                                  "pv": WireProtocol.version,
                                  "min": WireProtocol.minSupportedPeer])
                self.startTimers()
            case .failed, .cancelled:
                DispatchQueue.main.async { self.close() }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    /// Main thread. Idempotent — reached from the window closing, the socket
    /// dying, and the listener being switched off.
    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        // Read the timer properties on their owning queue; `self` is kept
        // alive by the closure until the cancel lands.
        queue.async {
            self.pingTimer?.cancel()
            self.watchdogTimer?.cancel()
        }
        if let window {
            window.delegate = nil
            window.orderOut(nil)
        }
        window = nil
        Log.info("receiver: session for \(deviceName) ended")
        onEnded?()
    }

    // MARK: - Liveness

    private func startTimers() {
        let ping = DispatchSource.makeTimerSource(queue: queue)
        ping.schedule(deadline: .now() + 2, repeating: 2)
        ping.setEventHandler { [weak self] in
            self?.sendControl(["type": "ping",
                               "t": Date().timeIntervalSince1970 * 1000])
        }
        ping.resume()
        pingTimer = ping

        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 5, repeating: 2)
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastDataReceived) > 5 {
                Log.info("receiver: nothing from the device for >5s — dropping")
                DispatchQueue.main.async { self.close() }
            }
        }
        watchdog.resume()
        watchdogTimer = watchdog
    }

    // MARK: - Socket read + deframing (same wire format as PhoneReceiver)

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastDataReceived = Date()
                self.buffer.append(data)
                self.drainFrames()
            }
            if error != nil || isComplete {
                DispatchQueue.main.async { self.close() }
                return
            }
            self.receive(on: conn)
        }
    }

    private func drainFrames() {
        var cursor = buffer.startIndex
        while buffer.distance(from: cursor, to: buffer.endIndex) >= 4 {
            let len = buffer[cursor..<buffer.index(cursor, offsetBy: 4)]
                .withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard buffer.distance(from: cursor, to: buffer.endIndex) >= 4 + len else { break }
            let start = buffer.index(cursor, offsetBy: 4)
            let end = buffer.index(start, offsetBy: len)
            handlePayload(Data(buffer[start..<end]))
            cursor = end
        }
        buffer.removeSubrange(buffer.startIndex..<cursor)
    }

    private func handlePayload(_ data: Data) {
        // Same disambiguation as the forward direction (COMPATIBILITY.md §6):
        // small, starts with '{', no NUL byte = JSON control frame.
        if data.count < 32_768, data.first == UInt8(ascii: "{"), !data.contains(0x00) {
            handleControl(data)
            return
        }
        handleAnnexB(data)
    }

    private func handleControl(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "hello":
            let name = obj["name"] as? String ?? (obj["device"] as? String ?? "iPad")
            let pv = obj["pv"] as? Int ?? WireProtocol.assumedWhenAbsent
            Log.info("receiver: hello from \(name) pv=\(pv)")
            DispatchQueue.main.async {
                self.deviceName = name
                self.window?.title = name
            }
        case "ping":
            if let t = obj["t"] as? Double {
                sendControl(["type": "pong", "t": t,
                             "mt": Date().timeIntervalSince1970 * 1000])
            }
        case "pong":
            break   // liveness only — receipt already fed the watchdog
        default:
            Log.info("receiver: unknown control message: \(type)")
        }
    }

    private func sendControl(_ message: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - Annex B -> CMSampleBuffer (port of PhoneReceiver.handleAnnexB)

    private func handleAnnexB(_ data: Data) {
        var nalus: [Data] = []
        var metaPrefix: Data?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var naluStart: Int? = nil
            var firstSC: Int? = nil
            var i = 0
            while i + 4 <= bytes.count {
                if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 {
                    if firstSC == nil { firstSC = i }
                    if let s = naluStart, s < i { nalus.append(Data(bytes[s..<i])) }
                    naluStart = i + 4
                    i += 4
                } else {
                    i += 1
                }
            }
            if let s = naluStart, s < bytes.count { nalus.append(Data(bytes[s...])) }
            if let f = firstSC, f > 0 { metaPrefix = Data(bytes[0..<f]) }
        }

        if let metaPrefix,
           let meta = try? JSONSerialization.jsonObject(with: metaPrefix) as? [String: Any],
           let or = meta["or"] as? Int, or != orientationRaw {
            orientationRaw = or
            DispatchQueue.main.async { self.layoutWindow() }
        }

        var vclNALUs: [Data] = []
        for nalu in nalus {
            guard let first = nalu.first else { continue }
            switch first & 0x1F {
            case 7:                                  // SPS (changes on rotation)
                if sps != nalu {
                    sps = nalu
                    formatDesc = nil
                }
            case 8:                                  // PPS
                if pps != nalu {
                    pps = nalu
                    formatDesc = nil
                }
            case 6: break                            // SEI — skip
            default: vclNALUs.append(nalu)
            }
        }
        if formatDesc == nil, let sps, let pps {
            displayLayer.flush()
            buildFormatDescription(sps: sps, pps: pps)
        }
        guard !vclNALUs.isEmpty else { return }
        enqueueFrame(vclNALUs)
    }

    private func buildFormatDescription(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsBuf.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBuf.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                if status == noErr, let formatDesc {
                    let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
                    Log.info("receiver: format \(dims.width)x\(dims.height)")
                    DispatchQueue.main.async {
                        self.videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
                        self.onStreaming?()
                        self.showWindow()
                    }
                } else {
                    Log.info("receiver: format description FAILED: \(status)")
                }
            }
        }
    }

    private func enqueueFrame(_ nalus: [Data]) {
        guard let formatDesc else { return }

        var avcc = Data(capacity: nalus.reduce(0) { $0 + $1.count + 4 })
        for nalu in nalus {
            var len = UInt32(nalu.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nalu)
        }

        // Allocate a block buffer that OWNS its memory and copy the bytes in —
        // referencing a transient Swift buffer here is a use-after-free.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0,
                dataLength: avcc.count, flags: 0,
                blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return }
        let copyStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copyStatus == noErr else { return }

        var sample: CMSampleBuffer?
        var sizeArr = [avcc.count]
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr,
            sampleBufferOut: &sample)
        guard let sample else { return }

        // Display immediately: low latency, no PTS scheduling.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed {
            Log.info("receiver: display layer failed (\(String(describing: displayLayer.error))) — flushing")
            displayLayer.flush()
            requestKeyframeIfNeeded()
        }
        displayLayer.enqueue(sample)

        framesThisWindow += 1
        let elapsed = Date().timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            let fps = Int(Double(framesThisWindow) / elapsed)
            framesThisWindow = 0
            fpsWindowStart = Date()
            DispatchQueue.main.async { self.fps = fps }
        }
    }

    /// Joined mid-GOP or the decoder lost sync — ask the sender for an IDR.
    private func requestKeyframeIfNeeded() {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 1 else { return }
        lastKeyframeRequest = Date()
        sendControl(["type": "kf"])
    }

    // MARK: - Window (main thread)

    private func showWindow() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            let content = ReceiverVideoView(displayLayer: displayLayer)
            w.contentView = content
            // Closing the window is the "stop receiving from this device"
            // gesture — the extension sees the drop and ends its broadcast.
            let delegate = WindowDelegate { [weak self] in self?.close() }
            windowDelegate = delegate
            w.delegate = delegate
            window = w
        }
        window?.title = deviceName
        layoutWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Size the window to the (rotation-aware) video aspect and keep it there.
    private func layoutWindow() {
        guard let window, videoSize != .zero else { return }
        let shown = displayedSize
        window.contentAspectRatio = shown
        // Fit the frame to the new aspect, capped to a comfortable fraction
        // of the screen (rotations re-run this and flip the shape).
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
        let scale = min(1, min(screen.width * 0.6 / shown.width,
                               screen.height * 0.7 / shown.height))
        let size = CGSize(width: shown.width * scale, height: shown.height * scale)
        let wasVisible = window.isVisible
        var frame = window.frame
        frame.size = window.frameRect(forContentRect: CGRect(origin: .zero, size: size)).size
        window.setFrame(frame, display: true)
        if !wasVisible { window.center() }
        (window.contentView as? ReceiverVideoView)?.rotation = rotationAngle
        window.contentView?.needsLayout = true
    }

    /// Video size as shown, after applying the frame orientation.
    private var displayedSize: CGSize {
        quarterTurned ? CGSize(width: videoSize.height, height: videoSize.width) : videoSize
    }

    private var quarterTurned: Bool {
        orientationRaw == 6 || orientationRaw == 8   // .right / .left
    }

    /// CGImagePropertyOrientation -> rotation that displays the frame upright.
    private var rotationAngle: CGFloat {
        switch orientationRaw {
        case 3: return .pi
        case 6: return -.pi / 2
        case 8: return .pi / 2
        default: return 0
        }
    }
}

/// Layer-backed view hosting the display layer, aspect-fit with rotation.
private final class ReceiverVideoView: NSView {
    let displayLayer: AVSampleBufferDisplayLayer
    var rotation: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // For quarter turns the layer's own bounds are the un-rotated shape;
        // the transform spins it into place inside our bounds.
        let quarter = abs(rotation) > 0.1 && abs(abs(rotation) - .pi) > 0.1
        displayLayer.bounds = quarter
            ? CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            : bounds
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: rotation))
        CATransaction.commit()
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
