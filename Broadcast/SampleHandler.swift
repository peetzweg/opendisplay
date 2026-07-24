// SampleHandler — the iPad->Mac sender (issue #122), running inside a
// ReplayKit Broadcast Upload Extension. This is the only public way to
// capture the whole iPadOS screen system-wide; the user starts it from the
// in-app picker (or Control Center) and iOS hands us every screen frame.
//
// Pipeline:  ReplayKit frames -> VideoToolbox (H.264) -> framed TCP
//
// Mirror of MacSender's encode path with the roles reversed: WE dial, the
// Mac listens (ReverseWire.serviceType). Wire format is identical —
// [4-byte big-endian length][Annex B payload], JSON control frames on the
// same channel, telemetry prefix before the first start code (plus "or",
// the frame's CGImagePropertyOrientation, so the Mac can rotate).
//
// Constraints in here: ~50 MB memory ceiling and no UI — every failure must
// go through finishBroadcastWithError so the system picker reports it.

import CoreMedia
import Network
import ReplayKit
import UIKit
import VideoToolbox

final class SampleHandler: RPBroadcastSampleHandler {

    private let queue = DispatchQueue(label: "broadcast.sender")
    private let group = UserDefaults(suiteName: ReverseWire.appGroup)

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var connectionReady = false
    private var discoveredCount = 0
    private var inbound = Data()

    private var encoder: VTCompressionSession?
    private var encoderWidth: Int32 = 0
    private var encoderHeight: Int32 = 0
    private var needsKeyframe = true
    private var pendingSends = 0
    private let maxPendingSends = 3
    private var orientationRaw = 1   // CGImagePropertyOrientation, per frame

    private let startCode: [UInt8] = [0, 0, 0, 1]

    // MARK: - Broadcast lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        setStatus("Looking for your Mac…")
        queue.async { self.startBrowsing() }
        // No Mac within the window → fail loudly instead of recording into
        // the void. One-shot, not a polling chain.
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.connection == nil else { return }
            if self.discoveredCount > 1 {
                self.fail("Several Macs found — open the OpenDisplay app and choose which Mac to send to, then start again.")
            } else {
                self.fail("No Mac found. Enable “Receive from iPad / iPhone” in the OpenDisplay Mac app and make sure both devices are on the same WiFi.")
            }
        }
    }

    override func broadcastFinished() {
        setStatus("Stopped")
        queue.async {
            // The user stopped the broadcast — cancelling the socket now must
            // not read as "the Mac ended the session".
            self.connectionReady = false
            self.browser?.cancel()
            self.connection?.cancel()
            if let encoder = self.encoder {
                VTCompressionSessionInvalidate(encoder)
                self.encoder = nil
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              CMSampleBufferIsValid(sampleBuffer) else { return }
        queue.async { self.handleVideo(sampleBuffer) }
    }

    /// Route every failure through the system UI; also mirrored to the app
    /// group so the in-app screen can explain what happened.
    private func fail(_ message: String) {
        setStatus("Failed: \(message)")
        finishBroadcastWithError(NSError(
            domain: "OpenDisplay", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private func setStatus(_ text: String) {
        group?.set(text, forKey: ReverseWire.statusKey)
    }

    // MARK: - Discovery + connection (we dial, the Mac listens)

    private func startBrowsing() {
        let browser = NWBrowser(
            for: .bonjour(type: ReverseWire.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.pickMac(from: results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    /// Connect to the Mac the app selected; with no selection, a single
    /// discovered Mac is unambiguous — take it.
    private func pickMac(from results: Set<NWBrowser.Result>) {
        guard connection == nil else { return }
        discoveredCount = results.count
        let target = group?.string(forKey: ReverseWire.targetNameKey)
        let match = results.first {
            guard case .service(let name, _, _, _) = $0.endpoint else { return false }
            return name == target
        } ?? (results.count == 1 ? results.first : nil)
        guard let match else { return }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        let conn = NWConnection(to: match.endpoint, using: params)
        connection = conn
        browser?.cancel()
        browser = nil
        setStatus("Connecting…")

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connectionReady = true
                self.needsKeyframe = true
                self.sendHello()
                self.setStatus("Streaming to your Mac")
            case .failed(let error):
                self.connectionReady = false
                self.fail("Connection failed: \(error.localizedDescription)")
            case .cancelled:
                // The Mac closed the window / turned receiving off.
                if self.connectionReady {
                    self.connectionReady = false
                    self.fail("The Mac ended the session.")
                }
            default: break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func sendHello() {
        let name = group?.string(forKey: "deviceName")
            ?? UIDevice.current.name
        sendControl([
            "type": "hello",
            "name": name,
            "device": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            "pv": WireProtocol.version,
        ])
    }

    // MARK: - Control channel (Mac -> us: welcome, kf, ping)

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inbound.append(data)
                self.drainControlFrames()
            }
            if error != nil || isComplete {
                if self.connectionReady {
                    self.connectionReady = false
                    self.fail("The Mac ended the session.")
                }
                return
            }
            self.receive(on: conn)
        }
    }

    private func drainControlFrames() {
        var cursor = inbound.startIndex
        while inbound.distance(from: cursor, to: inbound.endIndex) >= 4 {
            let len = inbound[cursor..<inbound.index(cursor, offsetBy: 4)]
                .withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard inbound.distance(from: cursor, to: inbound.endIndex) >= 4 + len else { break }
            let start = inbound.index(cursor, offsetBy: 4)
            let end = inbound.index(start, offsetBy: len)
            handleControl(Data(inbound[start..<end]))
            cursor = end
        }
        inbound.removeSubrange(inbound.startIndex..<cursor)
    }

    private func handleControl(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case WireMessage.welcome:
            // Compatibility gate, both directions (COMPATIBILITY.md).
            let macPV = obj["pv"] as? Int ?? WireProtocol.assumedWhenAbsent
            let macMin = obj["min"] as? Int ?? 1
            if macPV < WireProtocol.minSupportedPeer {
                fail("The OpenDisplay app on your Mac is too old. Update it to receive this stream.")
            } else if WireProtocol.version < macMin {
                fail("This app is too old for your Mac. Update OpenDisplay from the App Store.")
            }
        case "kf":
            needsKeyframe = true
        case "ping":
            if let t = obj["t"] as? Double {
                sendControl(["type": "pong", "t": t,
                             "mt": Date().timeIntervalSince1970 * 1000])
            }
        case "pong":
            break
        default:
            break
        }
    }

    private func sendControl(_ message: [String: Any]) {
        guard let connection,
              let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - Encode (mirror of MacSender.setupEncoder/encode)

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard connectionReady,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // ReplayKit stamps each frame with how the screen was oriented; the
        // Mac rotates accordingly. Forwarded in the telemetry prefix.
        if let n = CMGetAttachment(sampleBuffer,
                                   key: RPVideoSampleOrientationKey as CFString,
                                   attachmentModeOut: nil) as? NSNumber {
            orientationRaw = n.intValue
        }

        // Socket backed up: skip the frame; the dropped one breaks the
        // P-frame chain, so the next sent frame must be an IDR.
        if pendingSends > maxPendingSends {
            needsKeyframe = true
            return
        }

        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if encoder == nil || width != encoderWidth || height != encoderHeight {
            setupEncoder(width: width, height: height)
        }
        guard let encoder else { return }

        let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        var frameProperties: CFDictionary?
        if needsKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            needsKeyframe = false
        }
        let orientation = orientationRaw
        VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, buffer in
            guard status == noErr, let buffer, let self else { return }
            if let data = self.annexB(from: buffer) {
                let sndMs = Int64(Date().timeIntervalSince1970 * 1000)
                var framed = Data(
                    "{\"cap\":\(capturedAtMs),\"snd\":\(sndMs),\"or\":\(orientation)}".utf8)
                framed.append(data)
                self.queue.async { self.sendFramed(framed) }
            }
        }
    }

    private func setupEncoder(width: Int32, height: Int32) {
        if let encoder {
            VTCompressionSessionInvalidate(encoder)
            self.encoder = nil
        }
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        VTCompressionSessionCreate(
            allocator: nil,
            width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder
        )
        guard let encoder else {
            fail("The video encoder could not be started.")
            return
        }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        // No periodic IDRs — TCP never loses data; keyframes are forced on
        // connect, on drops, and on the Mac's request (same as MacSender).
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: 10_000_000 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(encoder)
        encoderWidth = width
        encoderHeight = height
        needsKeyframe = true
    }

    // MARK: - H.264 -> Annex B (copy of MacSender.annexB)

    private func annexB(from sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &len, totalLengthOut: &total,
                dataPointerOut: &ptr) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 128)
        if isKeyframe(sample), let fmt = CMSampleBufferGetFormatDescription(sample) {
            for i in 0..<2 {           // index 0 = SPS, 1 = PPS
                var psPtr: UnsafePointer<UInt8>?
                var psLen = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let psPtr {
                    out.append(contentsOf: startCode)
                    out.append(Data(bytes: psPtr, count: psLen))
                }
            }
        }
        let raw = UnsafeRawPointer(ptr)
        var offset = 0
        while offset + 4 <= total {
            var nalLen: UInt32 = 0
            memcpy(&nalLen, raw + offset, 4)
            nalLen = CFSwapInt32BigToHost(nalLen)
            offset += 4
            guard offset + Int(nalLen) <= total else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + offset, count: Int(nalLen)))
            offset += Int(nalLen)
        }
        return out
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let dict = (arr as? [[CFString: Any]])?.first else { return true }
        return !(dict[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    // MARK: - Wire framing: [4-byte big-endian length][payload]

    private func sendFramed(_ payload: Data) {
        guard let connection, connectionReady else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        pendingSends += 1
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingSends -= 1
            if error != nil { self.connectionReady = false }
        })
    }
}
