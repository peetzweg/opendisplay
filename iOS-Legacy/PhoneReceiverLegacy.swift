// PhoneReceiverLegacy — iOS 12 compatible port of the modern target's
// PhoneReceiver. Same wire protocol: TCP :9000, [4-byte big-endian length]
// [Annex B payload], plus an in-band JSON control channel (hello, ping/pong,
// cursor, keyframe requests). Rewritten without Combine (ObservableObject /
// @Published require iOS 13+): state changes are pushed through
// PhoneReceiverLegacyDelegate, always on the main thread, instead.
//
// Dropped versus the modern PhoneReceiver (MVP scope, see design spec):
// PerfStats / frame-timing telemetry / the periodic "stats" report to the
// Mac, and the Metal decode path. Kept: listener lifecycle, watchdog,
// Annex B parsing, clock-offset sync (still used to timestamp touch
// events), cursor echo — none of that is overlay-only.

import Foundation
import Network
import AVFoundation
import CoreMedia
import UIKit

protocol PhoneReceiverLegacyDelegate: AnyObject {
    func phoneReceiver(_ receiver: PhoneReceiverLegacy, didUpdateStatus status: String)
    func phoneReceiver(_ receiver: PhoneReceiverLegacy, didChangeConnected connected: Bool)
    func phoneReceiver(_ receiver: PhoneReceiverLegacy, didUpdateVideoSize size: CGSize)
}

final class PhoneReceiverLegacy {

    weak var delegate: PhoneReceiverLegacyDelegate?

    private(set) var status = "Starting…"
    private(set) var connected = false
    private(set) var videoSize = CGSize.zero

    private var listener: NWListener?
    private var listenerHealthy = false
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "receiver.video")
    private var buffer = Data()
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private var lastDataReceived = Date()
    private var port: UInt16 = 9000
    private var monitorsStarted = false

    private var offsetSamples: [(rtt: Double, offset: Double)] = []
    private var clockOffsetMs: Double?

    private var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    var onCursor: ((_ x: Double, _ y: Double, _ visible: Bool) -> Void)?
    var onCursorImage: ((_ image: UIImage, _ anchor: CGPoint, _ normSize: CGSize) -> Void)?

    let displayLayer: AVSampleBufferDisplayLayer

    private var nativeLong = 0
    private var nativeShort = 0
    private(set) var devicePixelsWide = 0
    private(set) var devicePixelsHigh = 0
    var deviceScale: Double = 2
    var serviceName = "OpenDisplay Legacy"

    static let installID: String = {
        if let existing = UserDefaults.standard.string(forKey: "installID") {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "installID")
        return fresh
    }()

    private var advertisedService: NWListener.Service {
        // NWTXTRecord (and the Service initializer overload that takes one)
        // are iOS 13+. NWListener.Service has always had a Data-based
        // txtRecord overload though (same class, no @available on it), so
        // we hand-encode the one "id" entry as a raw DNS-SD TXT record:
        // a single length-prefixed "key=value" byte string.
        let entry = Array("id=\(Self.installID)".utf8)
        var txtData = Data([UInt8(entry.count)])
        txtData.append(contentsOf: entry)
        return NWListener.Service(name: serviceName, type: "_opensidecar._tcp", domain: nil, txtRecord: txtData)
    }

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
        if devicePixelsWide == 0 {
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

    /// Recreate the listener if it isn't healthy — call when the app
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
        listener?.service = advertisedService
        listener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Log.info("new connection from \(String(describing: conn.endpoint))")
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
        case "ping":
            break // Mac-side telemetry piggyback — no overlay to feed here.
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
        displayLayer.flush()
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

    func sendTouch(phase: String, x: Double, y: Double) {
        var msg: [String: Any] = ["type": "touch", "phase": phase, "x": x, "y": y]
        if let offset = clockOffsetMs { msg["t"] = nowMs + offset }
        sendControl(msg)
    }

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
        if data.count < 32_768, data.first == UInt8(ascii: "{"), !data.contains(0x00) {
            handleVideoChannelJSON(data)
            return
        }

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
            case 7:
                if sps != nalu {
                    sps = nalu
                    formatDesc = nil
                }
            case 8:
                if pps != nalu {
                    pps = nalu
                    formatDesc = nil
                }
            case 6: break
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
                    Log.info("format description built: \(dims.width)x\(dims.height)")
                    let size = CGSize(width: Int(dims.width), height: Int(dims.height))
                    DispatchQueue.main.async {
                        self.videoSize = size
                        self.delegate?.phoneReceiver(self, didUpdateVideoSize: size)
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

        var avcc = Data(capacity: nalus.reduce(0) { $0 + $1.count + 4 })
        for nalu in nalus {
            var len = UInt32(nalu.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nalu)
        }

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
    }

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        Log.info("status: \(text)")
        DispatchQueue.main.async {
            self.status = text
            self.delegate?.phoneReceiver(self, didUpdateStatus: text)
        }
    }

    private func setConnected(_ value: Bool) {
        DispatchQueue.main.async {
            self.connected = value
            self.delegate?.phoneReceiver(self, didChangeConnected: value)
        }
        if !value { setStatus("Listening on :\(port)") }
        else { setStatus("Connected") }
    }
}
