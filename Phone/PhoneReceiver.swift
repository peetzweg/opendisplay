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

final class PhoneReceiver: ObservableObject {

    @Published var status = "Starting…"
    @Published var fps = 0
    @Published var connected = false
    @Published var videoSize = CGSize.zero   // for touch coordinate mapping

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "receiver.video")
    private var buffer = Data()
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private var framesThisWindow = 0
    private var fpsWindowStart = Date()

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
    var serviceName = "OpenSidecar"

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
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            setStatus("Listener failed: \(error.localizedDescription)")
            return
        }
        // Advertise on the local network so the Mac can discover us for WiFi
        // mode (USB/usbmux connects straight to the port and ignores this).
        listener?.service = NWListener.Service(name: serviceName, type: "_opensidecar._tcp")
        listener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Log.info("new connection from \(String(describing: conn.endpoint))")
            // Replace any existing connection and reset decoder state.
            self.connection?.cancel()
            self.connection = conn
            self.resetStreamState()
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
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
            switch state {
            case .ready: self?.setStatus("Listening on :\(port)")
            case .failed(let error): self?.setStatus("Listener failed: \(error.localizedDescription)")
            default: break
            }
        }
        listener?.start(queue: queue)
    }

    private func resetStreamState() {
        buffer.removeAll(keepingCapacity: true)
        formatDesc = nil
        sps = nil
        pps = nil
        displayLayer.flush()
    }

    // MARK: - Control messages (phone -> Mac)

    private func sendHello(on conn: NWConnection) {
        sendControl([
            "type": "hello",
            "pixelsWide": devicePixelsWide,
            "pixelsHigh": devicePixelsHigh,
            "scale": deviceScale,
        ], on: conn)
        Log.info("hello sent")
    }

    /// Touch events: x/y normalized [0,1] in video space, origin top-left.
    func sendTouch(phase: String, x: Double, y: Double) {
        sendControl(["type": "touch", "phase": phase, "x": x, "y": y])
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
        // Split on 4-byte start codes (our sender only emits 00 00 00 01).
        var nalus: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var naluStart: Int? = nil
            var i = 0
            while i + 4 <= bytes.count {
                if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 {
                    if let s = naluStart, s < i { nalus.append(Data(bytes[s..<i])) }
                    naluStart = i + 4
                    i += 4
                } else {
                    i += 1
                }
            }
            if let s = naluStart, s < bytes.count { nalus.append(Data(bytes[s...])) }
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

    private func enqueueFrame(_ nalus: [Data]) {
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
            displayLayer.flush()
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

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        Log.info("status: \(text)")
        DispatchQueue.main.async { self.status = text }
    }

    private func setConnected(_ value: Bool) {
        DispatchQueue.main.async { self.connected = value }
        if !value { setStatus("Listening on :9000") }
        else { setStatus("Connected") }
    }
}
