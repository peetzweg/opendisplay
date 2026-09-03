// BroadcastSender — the iPad/iPhone sender half of iPad → iPad (issue #123).
//
// Runs inside the broadcast upload extension: ReplayKit hands us the screen
// as CMSampleBuffers, we H.264-encode them (VideoToolbox) and stream over the
// same framed-TCP wire the Mac sender speaks — so the existing receiver app
// works unchanged and can't tell a Mac from an iPad on the other end.
//
// Mirror-only and view-only by platform constraint: iPadOS has no virtual
// display primitive (no extend) and no event injection (no touch
// back-channel) — the receiver's touch/scroll messages are ignored.
//
// Roles mirror the Mac pairing: the RECEIVER listens, the sender dials. The
// target's Bonjour service name comes from the app via app-group defaults
// (see BroadcastTarget); Network.framework resolves it, so this works for
// any receiver the app's picker could see.
//
// Wire protocol, sender -> receiver: [4-byte big-endian length][Annex B payload]
//   (keyframes prefixed with SPS+PPS, telemetry JSON prefix before the first
//   start code — identical to MacSender)
// Wire protocol, receiver -> sender: [4-byte big-endian length][JSON message]

import Foundation
import Network
import VideoToolbox
import CoreMedia

final class BroadcastSender {

    /// Unrecoverable failure (target gone, never reachable). The sample
    /// handler turns this into finishBroadcastWithError so the user sees why
    /// the recording indicator went away. Called on the sender queue.
    var onFatal: ((String) -> Void)?

    private let queue = DispatchQueue(label: "broadcast.video")
    private let targetService: String
    private let startCode: [UInt8] = [0, 0, 0, 1]

    private var connection: NWConnection?
    private var encoder: VTCompressionSession?
    private var encoderWidth = 0
    private var encoderHeight = 0

    private var connectionReady = false
    private var stopped = false
    private var paused = false
    private var needsKeyframe = true

    // Backpressure: outstanding sends, same budget as the Mac sender — at
    // 60fps each queued send is ~17ms of added latency, so drop and resync
    // with a keyframe instead of queueing.
    private var pendingSends = 0
    private let maxPendingSends = 3
    private var dropsTotal = 0

    // Disconnect detection. Before the first connection we allow a longer
    // window (Bonjour resolution + the user may still be switching devices);
    // once connected, a receiver that stays gone past the grace ends the
    // broadcast — a silent dead "recording" indicator would be worse.
    private var everConnected = false
    private var disconnectedSince: Date?
    private let disconnectGraceSeconds: TimeInterval = 10
    private let initialDialGraceSeconds: TimeInterval = 20
    private var startedAt = Date()

    // Liveness: the receiver pings every 2s; nothing for 5s = half-open link.
    private var lastReceived = Date()
    private var dialGeneration = 0

    // Cancel+replace timers, not self-rescheduling asyncAfter chains (#75/#76).
    private var pingTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?

    // ReplayKit emits frames only while content changes. After a reconnect on
    // a static screen there is nothing to hang the forced keyframe on — keep
    // the last frame around and re-encode it (same trick as the Mac sender).
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastCaptureAt = Date.distantPast

    // Delivery cadence for the receiver's "cap" overlay metric.
    private var capFrames = 0
    private var capWindowStart = Date()

    // WiFi-friendly fixed rate: iPad panels are large (up to 2732×2048) but
    // the balanced Mac preset shows 10 Mbps reads fine at that size.
    private let bitrate = 10_000_000

    init(targetService: String) {
        self.targetService = targetService
    }

    // MARK: - Lifecycle

    func start() {
        queue.async {
            self.startedAt = Date()
            self.connect()
            self.startTimers()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.watchdogTimer?.cancel()
            self.watchdogTimer = nil
            self.connection?.cancel()
            self.connection = nil
            if let encoder = self.encoder { VTCompressionSessionInvalidate(encoder) }
            self.encoder = nil
            self.lastPixelBuffer = nil
        }
    }

    /// Broadcast paused/resumed (device locked, incoming call). Frames stop
    /// arriving on their own; the flag just makes the state explicit and the
    /// resume path resyncs the receiver with a keyframe.
    func setPaused(_ value: Bool) {
        queue.async {
            self.paused = value
            if !value { self.needsKeyframe = true }
        }
    }

    // MARK: - Capture input (called from ReplayKit's delivery thread)

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        queue.async {
            guard !self.stopped, !self.paused else { return }
            self.lastPixelBuffer = pixelBuffer
            self.lastCaptureAt = Date()
            self.capFrames += 1

            guard self.connectionReady else { return }
            if self.pendingSends > self.maxPendingSends {
                self.needsKeyframe = true   // dropped frames break the P-frame chain
                self.dropsTotal += 1
                return
            }
            self.encode(pixelBuffer, pts: pts)
        }
    }

    // MARK: - Connection (with retry)

    private func connect() {
        guard !stopped else { return }
        let endpoint = NWEndpoint.service(name: targetService,
                                          type: "_opensidecar._tcp",
                                          domain: "local.", interface: nil)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true   // latency matters more than throughput here
        let params = NWParameters(tls: nil, tcp: tcp)
        // Two iPads on the same desk may share no infrastructure network —
        // peer-to-peer (AWDL) lets Bonjour resolve and connect regardless.
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("connection ready to \(self.targetService)")
                self.connectionReady = true
                self.everConnected = true
                self.disconnectedSince = nil
                self.needsKeyframe = true   // new peer needs SPS/PPS + IDR
                self.lastReceived = Date()  // fresh grace period for the watchdog
                self.receiveControl(on: conn)
            case .failed(let error):
                Log.info("connection failed: \(error)")
                self.connectionReady = false
                self.scheduleReconnect()
            case .waiting(let error):
                // Bonjour can sit in waiting while the service is gone —
                // treat as failure and poll by redialing, like the Mac does.
                Log.info("connection waiting: \(error) — will retry")
                self.connectionReady = false
                self.scheduleReconnect()
            case .cancelled:
                self.connectionReady = false
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        if everConnected {
            if let since = disconnectedSince {
                if Date().timeIntervalSince(since) > disconnectGraceSeconds {
                    Log.info("receiver gone for >\(Int(disconnectGraceSeconds))s — ending broadcast")
                    onFatal?("Lost the connection to “\(targetService)”.")
                    return
                }
            } else {
                disconnectedSince = Date()
            }
        } else if Date().timeIntervalSince(startedAt) > initialDialGraceSeconds {
            Log.info("never reached \(targetService) — ending broadcast")
            onFatal?("Could not reach “\(targetService)”. Make sure OpenDisplay is open on it and both devices are on the same network.")
            return
        }
        connectionReady = false
        dialGeneration += 1
        let generation = dialGeneration
        connection?.cancel()
        connection = nil
        pendingSends = 0
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            // Generation-guarded so overlapping failure callbacks collapse
            // into one redial instead of racing (#76 pattern).
            guard let self, generation == self.dialGeneration, !self.stopped else { return }
            self.connect()
        }
    }

    // MARK: - Liveness (ping + watchdog)

    private func startTimers() {
        pingTimer?.cancel()
        let ping = DispatchSource.makeTimerSource(queue: queue)
        ping.schedule(deadline: .now() + 2.0, repeating: .seconds(2))
        ping.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.connectionReady else { return }
            // Liveness + send-side health for the receiver's overlay.
            let elapsed = Date().timeIntervalSince(self.capWindowStart)
            let capFps = elapsed > 0 ? Int(Double(self.capFrames) / elapsed) : 0
            self.capFrames = 0
            self.capWindowStart = Date()
            self.sendJSONFrame("{\"type\":\"ping\",\"drops\":\(self.dropsTotal),\"pending\":\(self.pendingSends),\"capFps\":\(capFps)}")
        }
        ping.resume()
        pingTimer = ping

        watchdogTimer?.cancel()
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 2.0, repeating: .seconds(2))
        watchdog.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            if self.connectionReady, Date().timeIntervalSince(self.lastReceived) > 5 {
                Log.info("watchdog: nothing from the receiver for >5s — reconnecting")
                self.scheduleReconnect()
            }
            // A reconnect on a static screen produces no capture frames, so
            // the receiver would stay black — replay the last frame as IDR.
            if self.connectionReady, self.needsKeyframe, !self.paused,
               Date().timeIntervalSince(self.lastCaptureAt) > 1,
               let pixelBuffer = self.lastPixelBuffer {
                Log.info("static screen after reconnect — replaying last frame as keyframe")
                self.encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
        watchdog.resume()
        watchdogTimer = watchdog
    }

    // MARK: - Control messages (receiver -> sender)

    private func receiveControl(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, data.count == 4 else { return }
            let len = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard len > 0, len < 1 << 20 else { return }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] payload, _, _, error in
                guard let self, error == nil, let payload, payload.count == len else { return }
                self.handleControl(payload)
                self.receiveControl(on: conn)
            }
        }
    }

    private func handleControl(_ payload: Data) {
        lastReceived = Date()
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = obj["type"] as? String else {
            Log.info("unparseable control message (\(payload.count) bytes)")
            return
        }
        switch type {
        case "ping":
            // Echo with our clock so the receiver can estimate the offset
            // (NTP-style) and compute true end-to-end frame latency.
            if let t = obj["t"] as? Double {
                let mt = Date().timeIntervalSince1970 * 1000
                sendJSONFrame("{\"type\":\"pong\",\"t\":\(t),\"mt\":\(mt)}")
            }
        case "hello":
            // The receiver announces its panel — a mirror streams the sender's
            // own screen, so the dimensions don't drive anything here. The
            // version handshake reply still applies (issue #132).
            Log.info("receiver hello: \(String(data: payload, encoding: .utf8) ?? "?")")
            sendJSONFrame("{\"type\":\"\(WireMessage.welcome)\",\"pv\":\(WireProtocol.version),\"min\":\(WireProtocol.minSupportedPeer)}")
        case "kf":
            Log.info("receiver requested keyframe")
            needsKeyframe = true
        case "touch", "scroll":
            break   // view-only mirror: iOS offers no event injection
        case "stats":
            break   // receiver-side health report; nothing to log against yet
        default:
            Log.info("unknown control message type: \(type)")
        }
    }

    // MARK: - Encoder

    private func ensureEncoder(width: Int, height: Int) {
        if encoder != nil, width == encoderWidth, height == encoderHeight { return }
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        var session: VTCompressionSession?
        // Low-latency rate control: the hardware encoder emits every frame
        // immediately instead of pipelining (same settings as the Mac sender).
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard let session else {
            Log.info("FATAL: VTCompressionSessionCreate failed")
            return
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        // No periodic IDRs: each one is a bitrate spike → transmit-time hiccup.
        // TCP never loses data, and we force a keyframe on reconnect/drop.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        encoderWidth = width
        encoderHeight = height
        needsKeyframe = true   // new parameter sets — receiver must resync
        Log.info("encoder ready: \(width)x\(height) H.264 \(bitrate / 1_000_000)Mbps")
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        // Rotation changes the delivered buffer size on iOS — rebuild for the
        // new dimensions; the receiver rebuilds its format description off
        // the fresh SPS/PPS.
        ensureEncoder(width: CVPixelBufferGetWidth(pixelBuffer),
                      height: CVPixelBufferGetHeight(pixelBuffer))
        guard let encoder else { return }
        let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        var frameProperties: CFDictionary?
        if needsKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            needsKeyframe = false
        }
        VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, buffer in
            guard status == noErr, let buffer, let self else { return }
            if let data = self.annexB(from: buffer) {
                // Telemetry prefix before the first start code — the receiver
                // parses it and skips to the H.264 payload. cap = capture time,
                // snd = handoff to the socket (so cap→snd ≈ encode duration).
                let sndMs = Int64(Date().timeIntervalSince1970 * 1000)
                var framed = Data("{\"cap\":\(capturedAtMs),\"snd\":\(sndMs)}".utf8)
                framed.append(data)
                self.queue.async { self.sendFramed(framed) }
            }
        }
    }

    // MARK: - H.264 -> Annex B (same conversion as the Mac sender)

    private func annexB(from sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &len, totalLengthOut: &total,
                dataPointerOut: &ptr) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 128)
        // On keyframes, prepend SPS/PPS (they live in the format description).
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
        // Convert AVCC (4-byte length-prefixed NALUs) to Annex B start codes.
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

    private func sendJSONFrame(_ json: String) {
        guard let connection, connectionReady else { return }
        let payload = Data(json.utf8)
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func sendFramed(_ payload: Data) {
        guard let connection, connectionReady else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        pendingSends += 1
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingSends -= 1
            if let error { Log.info("send error: \(error)") }
        })
    }
}
