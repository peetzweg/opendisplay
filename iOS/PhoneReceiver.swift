// PhoneReceiver — Milestone 1: receive H.264 over TCP and display it.
//
// Pipeline:  TCP socket -> deframe -> Annex B parse -> CMSampleBuffer
//            -> AVSampleBufferDisplayLayer (decodes + renders)
//
// The phone LISTENS; the Mac connects (required for usbmux/USB).
// Wire protocol: [4-byte big-endian length][Annex B payload].

import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox
import UIKit

/// One-second window of pipeline health, plus per-frame timing samples for
/// the performance overlay graph.
struct PerfStats: Equatable {
    var fps = 0
    var mbps = 0.0
    var avgFrameMs = 0.0
    var maxFrameMs = 0.0
    var stalls = 0               // frames that arrived >50ms late (this window)
    var decodeFlushes = 0        // display layer failures since connect
    var samples: [Double] = []   // last ~120 inter-frame intervals, ms
    // True end-to-end latency (Mac capture → phone display handoff), using
    // the clock offset estimated from timestamped ping/pong.
    var e2eP50 = 0.0
    var e2eP95 = 0.0
    var encodeP50 = 0.0          // Mac-side capture→socket (encode + queue)
    var rttMs = 0.0              // control-channel round trip
    var e2eSamples: [Double] = []  // last ~120 per-frame e2e latencies, ms
    var transport = "—"          // USB (loopback via usbmux) or WiFi
    var macDrops = 0             // frames the Mac dropped (backpressure), total
    var macPending = 0           // Mac send queue depth right now
    var inputP50 = 0.0           // touch sent → CGEvent injected on the Mac, ms
    var inputP95 = 0.0
    var capFps = 0               // frames ScreenCaptureKit delivered on the Mac
    // Metal renderer path only:
    var decodeP50 = 0.0          // VTDecompressionSession decode, ms
    var photonP50 = 0.0          // Mac capture → frame actually on glass, ms
    var photonP95 = 0.0
}

final class PhoneReceiver: ObservableObject {

    @Published var status = "Starting…"
    @Published var fps = 0
    @Published var connected = false
    @Published var videoSize = CGSize.zero   // for touch coordinate mapping
    @Published var perf = PerfStats()

    private var listener: NWListener?
    private var listenerHealthy = false
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "receiver.video")
    private var buffer = Data()
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    // Liveness: the Mac streams video and pings every 2s; if nothing arrives
    // for 5s the connection is half-open (Mac killed, tunnel died) — drop it
    // so the listener can accept a fresh one.
    private var lastDataReceived = Date()
    private var port: UInt16 = 9000
    private var monitorsStarted = false

    private var framesThisWindow = 0
    private var fpsWindowStart = Date()
    private var bytesThisWindow = 0
    private var stallsThisWindow = 0
    private var decodeFlushes = 0
    private var lastFrameAt: Date?
    private var frameIntervals: [Double] = []   // ring buffer, ms
    private let maxSamples = 120

    // Clock sync (NTP-style): offset = macClock − phoneClock, taken from the
    // ping/pong sample with the lowest RTT (least asymmetric).
    private var offsetSamples: [(rtt: Double, offset: Double)] = []
    private var clockOffsetMs: Double?
    private var lastRttMs = 0.0
    private var e2eWindow: [Double] = []        // capture→display, ms
    private var encodeWindow: [Double] = []     // capture→socket on the Mac, ms
    private var e2eRing: [Double] = []          // per-frame, for the overlay graph
    private var statsReportCounter = 0
    private var transport = "—"
    private var macDrops = 0
    private var macPending = 0
    private var macInputP50 = 0.0
    private var macInputP95 = 0.0
    private var macCapFps = 0

    private var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    // Local cursor echo (both called on the main thread): position is
    // normalized [0,1] in video space; the sprite arrives as a PNG with its
    // hotspot anchor and size normalized against the Mac display.
    var onCursor: ((_ x: Double, _ y: Double, _ visible: Bool) -> Void)?
    var onCursorImage: ((_ image: UIImage, _ anchor: CGPoint, _ normSize: CGSize) -> Void)?

    // Metal renderer path (experimental, "metalRenderer" setting): we decode
    // explicitly and hand BGRA buffers out; called on the receiver queue.
    var onDecodedFrame: ((_ pixelBuffer: CVPixelBuffer, _ captureMs: Double?) -> Void)?
    private var decompressionSession: VTDecompressionSession?
    private var decodeWindow: [Double] = []
    private var photonWindow: [Double] = []
    private var loggedDisplayPath = false
    private var decodeErrorCount = 0
    // Default OFF: A/B measurement showed the system video layer reaches
    // glass faster than our CAMetalLayer path (iOS gives AVSBDL a dedicated
    // compositor plane). Kept as an experimental toggle + for its metrics.
    private var useMetalPath: Bool { UserDefaults.standard.bool(forKey: "metalRenderer") }

    /// Called by the renderer's presented handler: maps the CACurrentMediaTime-
    /// based glass timestamp into wall-clock ms and computes true photon e2e.
    func recordPresented(presentedTime: CFTimeInterval, captureMs: Double?) {
        guard let captureMs, presentedTime > 0 else { return }
        let presentedWallMs = nowMs - (CACurrentMediaTime() - presentedTime) * 1000
        queue.async {
            guard let offset = self.clockOffsetMs else { return }
            let photon = (presentedWallMs + offset) - captureMs
            if photon > -50, photon < 5000 {
                self.photonWindow.append(max(photon, 0))
            }
        }
    }

    let displayLayer: AVSampleBufferDisplayLayer

    /// Native panel size in pixels + scale, announced to the Mac in a "hello"
    /// message so it can size the virtual display. Orientation-dependent:
    /// rotating the phone re-announces with swapped dimensions and the Mac
    /// rebuilds the virtual display as a portrait/landscape monitor.
    private var nativeLong = 0
    private var nativeShort = 0
    private(set) var devicePixelsWide = 0
    private(set) var devicePixelsHigh = 0
    var deviceScale: Double = 2
    // Name advertised over Bonjour for the Mac's WiFi picker. iOS 16+ returns
    // a generic "iPhone" from UIDevice.current.name (the user-assigned name
    // needs an entitlement Apple gates behind approval and personal teams
    // can't get), so this is user-editable in Settings. The USB picker gets
    // the real name host-side via lockdownd regardless.
    var serviceName = "OpenSidecar"

    // Stable per-install identity, advertised in the Bonjour TXT record and
    // sent in every hello. The Mac uses it to recognize "same device, other
    // transport" — the service name can't serve that role since it's
    // user-editable, and iOS offers no public API for the hardware UDID
    // that usbmuxd reports.
    static let installID: String = {
        if let existing = UserDefaults.standard.string(forKey: "installID") {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "installID")
        return fresh
    }()

    private var advertisedService: NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = Self.installID
        return NWListener.Service(name: serviceName, type: "_opensidecar._tcp",
                                  domain: nil, txtRecord: txt)
    }

    /// Update the advertised name and re-publish if already listening.
    func setServiceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? UIDevice.current.name : trimmed
        queue.async {
            guard resolved != self.serviceName else { return }
            self.serviceName = resolved
            if self.listener != nil {
                self.listener?.service = self.advertisedService
                Log.info("re-advertising as \"\(resolved)\"")
            }
        }
    }

    func setNativePanel(long: Int, short: Int, scale: Double) {
        nativeLong = long
        nativeShort = short
        deviceScale = scale
        if devicePixelsWide == 0 {   // default landscape until the view reports
            devicePixelsWide = long
            devicePixelsHigh = short
        }
    }

    func setOrientation(portrait: Bool) {
        let w = portrait ? nativeShort : nativeLong
        let h = portrait ? nativeLong : nativeShort
        guard w > 0, w != devicePixelsWide else { return }
        devicePixelsWide = w
        devicePixelsHigh = h
        Log.info("orientation changed -> \(portrait ? "portrait" : "landscape") \(w)x\(h)")
        if let connection { sendHello(on: connection) }
    }

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
    }

    func start(port: UInt16 = 9000) {
        self.port = port
        queue.async { self.startListener() }
        if !monitorsStarted {
            monitorsStarted = true
            schedulePing()
            scheduleWatchdog()
        }
    }

    /// Recreate the listener if it isn't healthy — called when the app
    /// returns to the foreground (iOS may have torn it down while suspended).
    func ensureListening() {
        queue.async {
            guard !self.listenerHealthy else { return }
            Log.info("listener not healthy — restarting")
            self.restartListener()
        }
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        listenerHealthy = false
        startListener()
    }

    private func startListener() {
        do {
            // noDelay matters most in THIS direction: touch events are tiny
            // packets, and Nagle would hold each one until the previous is
            // ACKed — batched, late drags read as input lag.
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.serviceClass = .interactiveVideo
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            setStatus("Listener failed: \(error.localizedDescription)")
            return
        }
        // Advertise on the local network so the Mac can discover us for WiFi
        // mode (USB/usbmux connects straight to the port and ignores this).
        listener?.service = advertisedService
        listener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Log.info("new connection from \(String(describing: conn.endpoint))")
            // usbmux-forwarded (cable) connections arrive from loopback;
            // anything else came over the network.
            let peer = String(describing: conn.endpoint)
            self.transport = (peer.hasPrefix("127.0.0.1") || peer.hasPrefix("::1")
                              || peer.hasPrefix("localhost")) ? "USB" : "WiFi"
            // Replace any existing connection and reset decoder state.
            self.connection?.cancel()
            self.connection = conn
            self.resetStreamState()
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.lastDataReceived = Date()
                    self?.setConnected(true)
                    self?.sendHello(on: conn)
                case .failed, .cancelled:
                    self?.setConnected(false)
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.receive(on: conn)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.listenerHealthy = true
                self.setStatus("Listening on :\(self.port)")
            case .failed(let error):
                Log.info("listener failed: \(error) — restarting in 1s")
                self.listenerHealthy = false
                self.setStatus("Listener failed — restarting…")
                self.queue.asyncAfter(deadline: .now() + 1) { self.restartListener() }
            case .cancelled:
                self.listenerHealthy = false
            default: break
            }
        }
        listener?.start(queue: queue)
    }

    // MARK: - Liveness (ping + watchdog)

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if self.connection?.state == .ready {
                self.sendControl(["type": "ping", "t": self.nowMs])
            }
            self.schedulePing()
        }
    }

    /// JSON on the video channel (pong, ping liveness) — payloads starting '{'.
    private func handleVideoChannelJSON(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "pong":
            guard let t1 = obj["t"] as? Double, let mt = obj["mt"] as? Double else { return }
            let t2 = nowMs
            let rtt = t2 - t1
            guard rtt >= 0, rtt < 2000 else { return }
            let offset = mt - (t1 + t2) / 2
            offsetSamples.append((rtt, offset))
            if offsetSamples.count > 15 { offsetSamples.removeFirst() }
            if let best = offsetSamples.min(by: { $0.rtt < $1.rtt }) {
                clockOffsetMs = best.offset
            }
            lastRttMs = rtt
        case "ping":
            // The Mac piggybacks its send-side health on liveness pings.
            macDrops = obj["drops"] as? Int ?? macDrops
            macPending = obj["pending"] as? Int ?? macPending
            macInputP50 = obj["inp50"] as? Double ?? macInputP50
            macInputP95 = obj["inp95"] as? Double ?? macInputP95
            macCapFps = obj["capFps"] as? Int ?? macCapFps
        case "cursor":
            let visible = (obj["v"] as? Int ?? 0) == 1
            let x = obj["x"] as? Double ?? 0
            let y = obj["y"] as? Double ?? 0
            DispatchQueue.main.async { self.onCursor?(x, y, visible) }
        case "cursorImg":
            guard let b64 = obj["png"] as? String,
                  let png = Data(base64Encoded: b64),
                  let image = UIImage(data: png),
                  let nw = obj["nw"] as? Double, let nh = obj["nh"] as? Double else { return }
            let anchor = CGPoint(x: obj["ax"] as? Double ?? 0, y: obj["ay"] as? Double ?? 0)
            let normSize = CGSize(width: nw, height: nh)
            DispatchQueue.main.async { self.onCursorImage?(image, anchor, normSize) }
        default:
            break
        }
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if let conn = self.connection, conn.state == .ready,
               Date().timeIntervalSince(self.lastDataReceived) > 5 {
                Log.info("watchdog: nothing from the Mac for >5s — dropping connection")
                conn.cancel()
                self.connection = nil
                self.setConnected(false)
            }
            self.scheduleWatchdog()
        }
    }

    private func resetStreamState() {
        buffer.removeAll(keepingCapacity: true)
        formatDesc = nil
        sps = nil
        pps = nil
        lastFrameAt = nil
        frameIntervals.removeAll()
        decodeFlushes = 0
        displayLayer.flush()
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        decodeWindow.removeAll(keepingCapacity: true)
        photonWindow.removeAll(keepingCapacity: true)
    }

    // MARK: - Control messages (phone -> Mac)

    private func sendHello(on conn: NWConnection) {
        sendControl([
            "type": "hello",
            "pixelsWide": devicePixelsWide,
            "pixelsHigh": devicePixelsHigh,
            "scale": deviceScale,
            "device": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            "id": Self.installID,
        ], on: conn)
        Log.info("hello sent")
    }

    /// Touch events: x/y normalized [0,1] in video space, origin top-left.
    /// Stamped in *Mac* clock time (our clock + sync offset) so the Mac can
    /// measure touch→injection latency without doing its own clock sync.
    func sendTouch(phase: String, x: Double, y: Double) {
        var msg: [String: Any] = ["type": "touch", "phase": phase, "x": x, "y": y]
        if let offset = clockOffsetMs { msg["t"] = nowMs + offset }
        sendControl(msg)
    }

    /// Two-finger scroll: dx/dy in video pixels (natural-scrolling sign).
    func sendScroll(dx: Double, dy: Double) {
        sendControl(["type": "scroll", "dx": dx, "dy": dy])
    }

    private func sendControl(_ message: [String: Any], on conn: NWConnection? = nil) {
        guard let conn = conn ?? connection,
              let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { error in
            if let error { Log.info("control send error: \(error)") }
        })
    }

    // MARK: - Socket read + length-prefixed deframing

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastDataReceived = Date()
                self.bytesThisWindow += data.count
                self.buffer.append(data)
                self.drainFrames()
            }
            if let error {
                Log.info("receive error: \(error)")
                return
            }
            if isComplete {
                Log.info("peer closed connection")
                self.setConnected(false)
                return
            }
            self.receive(on: conn)
        }
    }

    private func drainFrames() {
        // Cursor-based drain so we only compact the buffer once per batch.
        var cursor = buffer.startIndex
        while buffer.distance(from: cursor, to: buffer.endIndex) >= 4 {
            let len = buffer[cursor..<buffer.index(cursor, offsetBy: 4)]
                .withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard buffer.distance(from: cursor, to: buffer.endIndex) >= 4 + len else { break }
            let start = buffer.index(cursor, offsetBy: 4)
            let end = buffer.index(start, offsetBy: len)
            handleAnnexB(Data(buffer[start..<end]))
            cursor = end
        }
        buffer.removeSubrange(buffer.startIndex..<cursor)
    }

    // MARK: - Annex B -> CMSampleBuffer

    private func handleAnnexB(_ data: Data) {
        // Pure JSON payload = control message (pong, cursor sprite etc.).
        // Video frames also begin with '{' (telemetry prefix) but always
        // contain start codes — the null bytes make them unambiguous even
        // against multi-KB JSON (cursor sprites are base64, NUL-free).
        if data.count < 32_768, data.first == UInt8(ascii: "{"), !data.contains(0x00) {
            handleVideoChannelJSON(data)
            return
        }

        // Split on 4-byte start codes (our sender only emits 00 00 00 01).
        // Bytes before the FIRST start code are the telemetry prefix
        // ({"cap":…,"snd":…} stamped by the Mac).
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

        var captureMs: Double?
        var sendMs: Double?
        if let metaPrefix,
           let meta = try? JSONSerialization.jsonObject(with: metaPrefix) as? [String: Any] {
            captureMs = meta["cap"] as? Double
            sendMs = meta["snd"] as? Double
        }

        var vclNALUs: [Data] = []
        for nalu in nalus {
            guard let first = nalu.first else { continue }
            switch first & 0x1F {
            case 7:                                  // SPS (stream may change
                if sps != nalu {                     //  size on rotation)
                    sps = nalu
                    formatDesc = nil
                }
            case 8:                                  // PPS
                if pps != nalu {
                    pps = nalu
                    formatDesc = nil
                }
            case 6: break                            // SEI — skip
            default: vclNALUs.append(nalu)           // slice data
            }
        }
        if formatDesc == nil, let sps, let pps {
            displayLayer.flush()   // drop any frames from the previous format
            buildFormatDescription(sps: sps, pps: pps)
        }
        guard !vclNALUs.isEmpty else { return }
        // All slices of one wire frame go into ONE sample buffer.
        enqueueFrame(vclNALUs, captureMs: captureMs, sendMs: sendMs)
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
                    Log.info("format description built: \(dims.width)x\(dims.height)")
                    DispatchQueue.main.async {
                        self.videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
                    }
                    setStatus("Receiving \(dims.width)×\(dims.height)")
                } else {
                    Log.info("format description FAILED: \(status)")
                }
            }
        }
    }

    private func enqueueFrame(_ nalus: [Data], captureMs: Double? = nil, sendMs: Double? = nil) {
        guard let formatDesc else { return }

        // Build one AVCC buffer: each NALU prefixed with 4-byte big-endian length.
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
                memoryBlock: nil,                   // let CoreMedia allocate
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

        if loggedDisplayPath != (useMetalPath && onDecodedFrame != nil) {
            loggedDisplayPath = useMetalPath && onDecodedFrame != nil
            Log.info("display path: metal=\(useMetalPath) sink=\(onDecodedFrame != nil)")
        }
        if useMetalPath, onDecodedFrame != nil {
            decodeAndRender(sample, captureMs: captureMs)
        } else {
            // Display immediately: low latency, no PTS scheduling.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }

            if displayLayer.status == .failed {
                Log.info("display layer failed (\(String(describing: displayLayer.error))) — flushing")
                decodeFlushes += 1
                displayLayer.flush()
            }
            displayLayer.enqueue(sample)
        }

        // Per-frame timing for the performance overlay.
        let now = Date()
        if let last = lastFrameAt {
            let ms = now.timeIntervalSince(last) * 1000
            frameIntervals.append(ms)
            if frameIntervals.count > maxSamples { frameIntervals.removeFirst() }
            if ms > 50 { stallsThisWindow += 1 }
        }
        lastFrameAt = now

        // True end-to-end latency: Mac capture timestamp vs our clock mapped
        // onto the Mac's via the ping/pong offset.
        if let captureMs, let sendMs {
            encodeWindow.append(sendMs - captureMs)
            if let offset = clockOffsetMs {
                let e2e = (nowMs + offset) - captureMs
                if e2e > -50, e2e < 5000 {
                    e2eWindow.append(e2e)
                    e2eRing.append(max(e2e, 0))
                    if e2eRing.count > maxSamples { e2eRing.removeFirst() }
                }
            }
        }

        framesThisWindow += 1
        let elapsed = now.timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            let fps = Int(Double(framesThisWindow) / elapsed)
            var stats = PerfStats()
            stats.fps = fps
            stats.mbps = Double(bytesThisWindow) * 8 / elapsed / 1_000_000
            stats.samples = frameIntervals
            if !frameIntervals.isEmpty {
                stats.avgFrameMs = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
                stats.maxFrameMs = frameIntervals.max() ?? 0
            }
            stats.stalls = stallsThisWindow
            stats.decodeFlushes = decodeFlushes
            stats.e2eP50 = percentile(e2eWindow, 0.5)
            stats.e2eP95 = percentile(e2eWindow, 0.95)
            stats.encodeP50 = percentile(encodeWindow, 0.5)
            stats.rttMs = lastRttMs
            stats.e2eSamples = e2eRing
            stats.transport = transport
            stats.macDrops = macDrops
            stats.macPending = macPending
            stats.inputP50 = macInputP50
            stats.inputP95 = macInputP95
            stats.capFps = macCapFps
            stats.decodeP50 = percentile(decodeWindow, 0.5)
            stats.photonP50 = percentile(photonWindow, 0.5)
            stats.photonP95 = percentile(photonWindow, 0.95)
            framesThisWindow = 0
            bytesThisWindow = 0
            stallsThisWindow = 0
            fpsWindowStart = now

            // Every 5s, report the aggregate to the Mac so its log holds the
            // full pipeline picture for offline analysis.
            statsReportCounter += 1
            if statsReportCounter >= 5 {
                statsReportCounter = 0
                sendControl([
                    "type": "stats",
                    "transport": transport,
                    "fps": fps,
                    "mbps": (stats.mbps * 10).rounded() / 10,
                    "e2e50": stats.e2eP50.rounded(),
                    "e2e95": stats.e2eP95.rounded(),
                    "enc50": stats.encodeP50.rounded(),
                    "rtt": lastRttMs.rounded(),
                    "stalls": stats.stalls,
                    "inp50": macInputP50.rounded(),
                    "capFps": macCapFps,
                    "dec50": stats.decodeP50.rounded(),
                    "ph50": stats.photonP50.rounded(),
                    "ph95": stats.photonP95.rounded(),
                    "offsetKnown": clockOffsetMs != nil,
                ])
                e2eWindow.removeAll(keepingCapacity: true)
                encodeWindow.removeAll(keepingCapacity: true)
                decodeWindow.removeAll(keepingCapacity: true)
                photonWindow.removeAll(keepingCapacity: true)
            }

            DispatchQueue.main.async {
                self.fps = fps
                self.perf = stats
            }
        }
    }

    // MARK: - Explicit decode (Metal renderer path)

    private func ensureDecompressionSession() {
        guard let formatDesc else { return }
        if let session = decompressionSession {
            if VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: formatDesc) {
                return
            }
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        // NV12: the decoder's native output — BGRA would add a conversion
        // pass inside VideoToolbox (measured ~7ms); the YUV→RGB happens in
        // the renderer's fragment shader instead (~free).
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: formatDesc, decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &session)
        if status != noErr { Log.info("VTDecompressionSessionCreate failed: \(status)") }
        decompressionSession = session
    }

    /// Synchronous hardware decode — the handler runs before this returns,
    /// so blocking in the renderer (nextDrawable) is our frame pacing.
    private func decodeAndRender(_ sample: CMSampleBuffer, captureMs: Double?) {
        ensureDecompressionSession()
        guard let session = decompressionSession else { return }
        let t0 = nowMs
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            if status == noErr, let imageBuffer {
                self.decodeWindow.append(self.nowMs - t0)
                self.onDecodedFrame?(imageBuffer, captureMs)
            } else {
                if self.decodeErrorCount % 60 == 0 {
                    Log.info("decode output error: \(status) imageBuffer=\(imageBuffer != nil)")
                }
                self.decodeErrorCount += 1
                // Joined mid-GOP (e.g. the renderer attached after the
                // connect-time IDR, and periodic keyframes are off) — ask
                // the Mac for a fresh sync point.
                self.requestKeyframeIfNeeded()
            }
        }
        if status != noErr {
            decodeFlushes += 1
            decodeErrorCount += 1
            if decodeErrorCount % 60 == 1 {
                Log.info("decode call error: \(status) (\(decodeErrorCount) total)")
            }
            requestKeyframeIfNeeded()
        }
    }

    private var lastKeyframeRequest = Date.distantPast
    private func requestKeyframeIfNeeded() {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 1 else { return }
        lastKeyframeRequest = Date()
        Log.info("requesting keyframe (decoder needs sync)")
        sendControl(["type": "kf"])
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[idx]
    }

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        Log.info("status: \(text)")
        DispatchQueue.main.async { self.status = text }
    }

    private func setConnected(_ value: Bool) {
        DispatchQueue.main.async { self.connected = value }
        if !value { setStatus("Listening on :9000") }
        else {
            setStatus("Connected")
            // Remember the first ever successful connection to a Mac so the
            // first-run onboarding hint never reappears (issue #49).
            if !UserDefaults.standard.bool(forKey: "hasConnectedBefore") {
                UserDefaults.standard.set(true, forKey: "hasConnectedBefore")
            }
        }
    }
}
