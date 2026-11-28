// CastSender — Google Cast Mirroring transport over Cast V2 TLS + Cast RTP/RTCP UDP.
//
// Control plane (TCP/TLS :8009):
//   [4-byte big-endian length][CastMessage protobuf]
//   Launches the Cast Mirroring receiver app (0F5096E8) and exchanges WebRTC
//   OFFER/ANSWER JSON over `urn:x-cast:com.google.cast.webrtc`.
//
// Media plane (UDP negotiated port):
//   Annex B H.264/HEVC frames encrypted with AES-128-CTR and packetized into
//   Cast RTP packets, with RTCP Sender Reports, RRTR, PLI, and NACK recovery.

import Foundation
import Network
import Security
import CoreMedia

protocol CastSenderDelegate: AnyObject {
    func castSenderDidConnect()
    func castSenderDidNegotiate(width: Int32, height: Int32, maxFps: Int32, codec: CastVideoCodec)
    func castSenderDidRequestKeyframe()
    func castSenderDidFail(error: String)
    func castSenderDidDisconnect()
    func castSenderStatusDidChange(_ status: String)
}

extension CastSenderDelegate {
    func castSenderDidConnect() {}
    func castSenderDidNegotiate(width: Int32, height: Int32, maxFps: Int32, codec: CastVideoCodec) {}
    func castSenderDidRequestKeyframe() {}
    func castSenderDidFail(error: String) {}
    func castSenderDidDisconnect() {}
    func castSenderStatusDidChange(_ status: String) {}
}

final class CastSender {

    private static let mirroringAppId = "0F5096E8"
    private static let legacyMirroringAppId = "674A0243"
    private static let maxPacketBurst = 64
    private static let maxQueuedPackets = 1_024

    // MARK: - Thread-Safe Snapshot State

    weak var delegate: CastSenderDelegate?

    private let stateLock = NSLock()
    private var _isConnected = false
    private var _isStreaming = false
    private var _stopped = false
    private var _framesSent: UInt64 = 0
    private var _currentBitrateMbps: Double = 0.0

    var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isConnected
    }

    var isStreaming: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isStreaming
    }

    var framesSent: UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return _framesSent
    }

    var currentBitrateMbps: Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return _currentBitrateMbps
    }

    private var stopped: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _stopped }
        set { stateLock.lock(); _stopped = newValue; stateLock.unlock() }
    }

    private func setConnectionState(connected: Bool? = nil, streaming: Bool? = nil) {
        stateLock.lock()
        if let connected { _isConnected = connected }
        if let streaming { _isStreaming = streaming }
        stateLock.unlock()
    }

    var targetDelayMs: Int = 200

    // MARK: - Queue-Confined State (`castQueue`)

    private let host: String
    private var resolvedHost: String?
    private let port: UInt16
    private var width: Int32 = 1920
    private var height: Int32 = 1080
    private var fps: Int32 = 60
    private var maxBitrate: Int32 = 10_000_000

    private let castQueue = DispatchQueue(label: "cast.sender")
    private var bytesSent: UInt64 = 0
    private var lastBitrateCalcTime = Date()

    private var tlsConnection: NWConnection?
    private var udpConnection: NWConnection?
    private var pingTimer: DispatchSourceTimer?
    private var offerRetryTimer: DispatchSourceTimer?
    private var rtcpTimer: DispatchSourceTimer?
    private var pacingTimer: DispatchSourceTimer?
    private var rxBuffer = Data()

    private enum SessionState {
        case initial
        case stoppingStaleSession
        case launchingReceiver
        case streamOffered
        case terminating
    }

    private let senderId: String
    private var transportId: String?
    private var sessionId: String?
    private let ssrc: UInt32 = 1
    private var rtpSeq: UInt16 = UInt16.random(in: 0...UInt16.max)
    private var frameId: UInt32 = 0
    private var appState: SessionState = .initial
    private var sessionStartUs: Int64 = 0
    private var lastVideoRtpTimestamp: UInt32 = 0
    private var hasVideoRtpTimestamp = false
    private var videoPacketsSent: UInt32 = 0
    private var cumulativeBytesSent: UInt64 = 0
    private var packetCache: [UInt8: [Data]] = [:]
    private var outgoingPackets = CastRTP.PacketBuffer()
    private var hasSentFirstKeyframe = false
    private var isStopping = false
    private var offerAttemptsRemaining = 0
    private var currentRequestId = 10

    private func nextRequestId() -> Int {
        currentRequestId += 1
        return currentRequestId
    }

    private var offeredCodecs: [Int: CastVideoCodec] = [:]
    private(set) var selectedCodec: CastVideoCodec = .h264
    private var aesKey: [UInt8] = []
    private var aesIvMask: [UInt8] = []

    /// Monotonic host clock in microseconds (`CMClockGetHostTimeClock`), immune to NTP jumps.
    static func monotonicMicroseconds() -> Int64 {
        let seconds = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        guard seconds.isFinite else { return 0 }
        return Int64(seconds * 1_000_000)
    }

    /// Converts elapsed microseconds into modular 90 kHz 32-bit RTP timestamp ticks (RFC 3550).
    static func rtpTimestamp90kHz(elapsedMicroseconds: Int64) -> UInt32 {
        let clamped = max(0, elapsedMicroseconds)
        let ticks = (clamped / 1_000) &* 90 + ((clamped % 1_000) * 90) / 1_000
        return UInt32(truncatingIfNeeded: ticks)
    }

    init(host: String, port: UInt16, delegate: CastSenderDelegate? = nil) {
        self.host = host
        self.port = port > 0 ? port : 8009
        self.delegate = delegate
        self.senderId = "sender-\(UInt32.random(in: 0..<1_000_000))"
    }

    // MARK: - Lifecycle

    func start(width: Int32, height: Int32, fps: Int32, maxBitrate: Int32) {
        let key = CastCrypto.randomBytes(count: 16)
        let mask = CastCrypto.randomBytes(count: 16)
        let delay = targetDelayMs

        stateLock.lock()
        _stopped = false
        _isConnected = false
        _isStreaming = false
        _framesSent = 0
        _currentBitrateMbps = 0
        stateLock.unlock()

        castQueue.async { [weak self] in
            guard let self else { return }
            self.width = width
            self.height = height
            self.fps = fps
            self.maxBitrate = maxBitrate
            self.targetDelayMs = delay
            self.isStopping = false
            self.appState = .initial
            self.aesKey = key
            self.aesIvMask = mask
            Log.info("cast sender: dialing TLS \(self.host):\(self.port)")
            self.connectTLS()
        }
    }

    // MARK: - TLS Control Channel & Heartbeat

    private func connectTLS() {
        let endpoint: NWEndpoint
        if host.contains("._googlecast._tcp") {
            let serviceName = host.components(separatedBy: "._googlecast._tcp").first ?? host
            endpoint = .service(name: serviceName, type: "_googlecast._tcp", domain: "local", interface: nil)
        } else {
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 8009)
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, complete in
                complete(true)   // Cast receivers present per-device self-signed ICA certs
            },
            castQueue
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        CastWire.configureLocalParameters(parameters)

        let conn = NWConnection(to: endpoint, using: parameters)
        tlsConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.setConnectionState(connected: true)

                if let currentPath = conn.currentPath,
                   case let .hostPort(remoteHost, _) = currentPath.remoteEndpoint {
                    switch remoteHost {
                    case .name(let name, _):
                        self.resolvedHost = name
                    case .ipv4(let addr):
                        let rawAddr = "\(addr)"
                        let cleanAddr = CastDiscovery.sanitizeIPv4(rawAddr) ?? rawAddr
                        self.resolvedHost = cleanAddr
                        Task { @MainActor in
                            CastDiscovery.shared.recordDeviceIP(cleanAddr)
                        }
                    case .ipv6(let addr):
                        self.resolvedHost = "\(addr)"
                    @unknown default:
                        break
                    }
                }

                Log.info("cast sender: TLS connected to \(self.resolvedHost ?? self.host)")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.castSenderDidConnect()
                }

                self.sendCastMessage(
                    source: self.senderId,
                    dest: "receiver-0",
                    ns: "urn:x-cast:com.google.cast.tp.connection",
                    json: CastWire.makeConnectPayload(connType: 1)
                )
                self.sendCastMessage(
                    source: self.senderId,
                    dest: "receiver-0",
                    ns: "urn:x-cast:com.google.cast.receiver",
                    json: "{\"type\":\"GET_STATUS\",\"requestId\":1}"
                )

                self.startHeartbeat()
                self.readNextTLSChunk()

            case .waiting(let error):
                Log.info("cast sender: TLS waiting (\(error))")
            case .failed(let error):
                Log.info("cast sender: TLS failed (\(error))")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.castSenderDidFail(error: "Could not connect to Cast receiver (\(error.localizedDescription))")
                }
            default:
                break
            }
        }

        conn.start(queue: castQueue)
    }

    private func startHeartbeat() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: castQueue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.sendCastMessage(
                source: self.senderId,
                dest: "receiver-0",
                ns: "urn:x-cast:com.google.cast.tp.heartbeat",
                json: "{\"type\":\"PING\"}"
            )
            if let tid = self.transportId, !tid.isEmpty {
                self.sendCastMessage(
                    source: self.senderId,
                    dest: tid,
                    ns: "urn:x-cast:com.google.cast.tp.heartbeat",
                    json: "{\"type\":\"PING\"}"
                )
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func sendCastMessage(source: String, dest: String, ns: String, json: String) {
        guard let tlsConn = tlsConnection, !stopped else { return }
        let packet = CastWire.buildMessage(sourceId: source, destId: dest, ns: ns, jsonPayload: json)
        tlsConn.send(content: packet, completion: .contentProcessed { error in
            if let error {
                Log.info("cast sender: TLS send error on \(ns) (\(error))")
            }
        })
    }

    private func readNextTLSChunk() {
        guard let tlsConn = tlsConnection, !stopped else { return }
        tlsConn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self, !self.stopped else { return }

            if let content, !content.isEmpty {
                self.rxBuffer.append(content)
                if !self.processRxBuffer() { return }
            }

            if error == nil && !isComplete {
                self.readNextTLSChunk()
            } else {
                Log.info("cast sender: TLS closed (isComplete=\(isComplete), error=\(String(describing: error)))")
                if !self.stopped {
                    self.stop()
                }
            }
        }
    }

    // MARK: - Control Message Dispatch & State Machine

    @discardableResult
    private func processRxBuffer() -> Bool {
        let frames: [Data]
        do {
            frames = try CastWire.extractFrames(from: &rxBuffer)
        } catch {
            Log.info("cast sender: framing error (\(error.localizedDescription)) — closing session")
            stop()
            return false
        }

        for msgData in frames {
            if let parsed = CastWire.parseProtobuf(data: msgData),
               let payloadStr = parsed.payloadUtf8,
               let payloadData = payloadStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                handleReceivedJson(json, sourceId: parsed.sourceId ?? "")
            }
        }
        return true
    }

    private func handleReceivedJson(_ dict: [String: Any], sourceId: String) {
        guard let type = dict["type"] as? String else { return }

        switch type {
        case "PING":
            handlePing(from: sourceId)
        case "RECEIVER_STATUS":
            let status = dict["status"] as? [String: Any]
            let apps = (status?["applications"] as? [[String: Any]]) ?? []
            handleReceiverStatus(applications: apps)
        case "ANSWER":
            handleAnswer(dict)
        default:
            if let error = dict["error"] {
                Log.info("cast sender: receiver reported error (\(error))")
            }
        }
    }

    private func handlePing(from sourceId: String) {
        let replyDest = sourceId.isEmpty ? "receiver-0" : sourceId
        sendCastMessage(
            source: senderId,
            dest: replyDest,
            ns: "urn:x-cast:com.google.cast.tp.heartbeat",
            json: "{\"type\":\"PONG\"}"
        )
        if let tid = transportId, !tid.isEmpty, replyDest != tid {
            sendCastMessage(
                source: senderId,
                dest: tid,
                ns: "urn:x-cast:com.google.cast.tp.heartbeat",
                json: "{\"type\":\"PONG\"}"
            )
        }
    }

    private func findMirroringApp(in apps: [[String: Any]]) -> [String: Any]? {
        apps.first { app in
            guard let appId = app["appId"] as? String else { return false }
            return appId == Self.mirroringAppId || appId == Self.legacyMirroringAppId
        }
    }

    private func handleReceiverStatus(applications apps: [[String: Any]]) {
        switch appState {
        case .initial:
            handleInitialStatus(apps: apps)
        case .stoppingStaleSession:
            handleStoppingStaleStatus(apps: apps)
        case .launchingReceiver:
            handleLaunchingReceiverStatus(apps: apps)
        case .streamOffered:
            handleStreamOfferedStatus(apps: apps)
        case .terminating:
            handleTerminatingStatus(apps: apps)
        }
    }

    private func handleInitialStatus(apps: [[String: Any]]) {
        if let staleApp = findMirroringApp(in: apps),
           let staleSessionId = staleApp["sessionId"] as? String {
            Log.info("cast sender: stopping stale mirroring session \(staleSessionId)")
            reportStatus("Starting Cast receiver…")
            appState = .stoppingStaleSession
            let stopJson = "{\"type\":\"STOP\",\"sessionId\":\"\(staleSessionId)\",\"requestId\":\(nextRequestId())}"
            sendCastMessage(source: senderId, dest: "receiver-0", ns: "urn:x-cast:com.google.cast.receiver", json: stopJson)
        } else {
            Log.info("cast sender: launching mirroring receiver app \(Self.mirroringAppId)")
            reportStatus("Starting Cast receiver…")
            appState = .launchingReceiver
            let launchJson = "{\"type\":\"LAUNCH\",\"appId\":\"\(Self.mirroringAppId)\",\"requestId\":\(nextRequestId())}"
            sendCastMessage(source: senderId, dest: "receiver-0", ns: "urn:x-cast:com.google.cast.receiver", json: launchJson)
        }
    }

    private func handleStoppingStaleStatus(apps: [[String: Any]]) {
        guard findMirroringApp(in: apps) == nil else { return }
        Log.info("cast sender: stale session cleared, launching \(Self.mirroringAppId)")
        appState = .launchingReceiver
        let launchJson = "{\"type\":\"LAUNCH\",\"appId\":\"\(Self.mirroringAppId)\",\"requestId\":\(nextRequestId())}"
        sendCastMessage(source: senderId, dest: "receiver-0", ns: "urn:x-cast:com.google.cast.receiver", json: launchJson)
    }

    private func handleLaunchingReceiverStatus(apps: [[String: Any]]) {
        guard transportId == nil,
              let app = findMirroringApp(in: apps),
              let tid = app["transportId"] as? String, !tid.isEmpty else { return }

        sessionId = app["sessionId"] as? String
        transportId = tid
        appState = .streamOffered
        Log.info("cast sender: mirroring receiver ready (transport=\(tid))")
        reportStatus("Negotiating video stream…")

        sendCastMessage(
            source: senderId,
            dest: tid,
            ns: "urn:x-cast:com.google.cast.tp.connection",
            json: CastWire.makeConnectPayload(connType: 1)
        )

        offerAttemptsRemaining = 5
        offerRetryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: castQueue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(500), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard !self.stopped, self.appState == .streamOffered, self.udpConnection == nil,
                  self.offerAttemptsRemaining > 0 else {
                self.offerRetryTimer?.cancel()
                self.offerRetryTimer = nil
                return
            }
            self.offerAttemptsRemaining -= 1
            let capSeq = self.nextRequestId()
            self.sendCastMessage(
                source: self.senderId,
                dest: tid,
                ns: "urn:x-cast:com.google.cast.webrtc",
                json: "{\"type\":\"GET_CAPABILITIES\",\"seqNum\":\(capSeq)}"
            )
            self.sendOffer(toTransportId: tid)
        }
        timer.resume()
        offerRetryTimer = timer
    }

    private func handleStreamOfferedStatus(apps: [[String: Any]]) {
        guard findMirroringApp(in: apps) == nil else { return }
        Log.info("cast sender: session closed on receiver")
        sessionId = nil
        transportId = nil
        finishTearDown()
    }

    private func handleTerminatingStatus(apps: [[String: Any]]) {
        guard findMirroringApp(in: apps) == nil else { return }
        finishTearDown()
    }

    private func handleAnswer(_ dict: [String: Any]) {
        guard udpConnection == nil else { return }
        guard let answer = dict["answer"] as? [String: Any],
              let udpPort = answer["udpPort"] as? Int else { return }

        offerRetryTimer?.cancel()
        offerRetryTimer = nil

        var chosenCodec: CastVideoCodec = .h264
        if let sendIndexes = answer["sendIndexes"] as? [Int],
           let firstIndex = sendIndexes.first,
           let codec = offeredCodecs[firstIndex] {
            chosenCodec = codec
        }

        selectedCodec = chosenCodec
        Log.info("cast sender: receiver selected \(chosenCodec.rawValue.uppercased()) on UDP port \(udpPort)")
        if udpPort > 0, udpPort <= Int(UInt16.max) {
            setupUDPStreaming(toPort: UInt16(udpPort), codec: chosenCodec)
        }
    }

    // MARK: - WebRTC Stream Negotiation (OFFER / ANSWER)

    private func sendOffer(toTransportId tid: String) {
        let bitrate = maxBitrate > 0 ? maxBitrate : 10_000_000
        let targetDelay = targetDelayMs > 0 ? targetDelayMs : 200

        var streams: [[String: Any]] = []
        offeredCodecs.removeAll()

        if aesKey.count != 16 { aesKey = CastCrypto.randomBytes(count: 16) }
        if aesIvMask.count != 16 { aesIvMask = CastCrypto.randomBytes(count: 16) }
        let aesKeyHex = aesKey.map { String(format: "%02x", $0) }.joined()
        let aesIvMaskHex = aesIvMask.map { String(format: "%02x", $0) }.joined()

        var streamIndex = 0
        func makeVideoStreamSpec(index: Int, codec: CastVideoCodec) -> [String: Any] {
            [
                "index": index,
                "type": "video_source",
                "codecName": codec.rawValue,
                "rtpProfile": "cast",
                "rtpPayloadType": 96,
                "ssrc": ssrc,
                "channels": 1,
                "targetDelay": targetDelay,
                "aesKey": aesKeyHex,
                "aesIvMask": aesIvMaskHex,
                "timeBase": "1/90000",
                "maxBitRate": bitrate,
                "resolutions": [["width": width, "height": height]],
                "maxFrameRate": "\(fps)000/1000",
                "errorRecoveryMode": "cast",
                "receiverRtcpEventLog": false
            ]
        }

        if CastEncoderSupport.supportsHEVC {
            streams.append(makeVideoStreamSpec(index: streamIndex, codec: .hevc))
            offeredCodecs[streamIndex] = .hevc
            streamIndex += 1
        }
        if CastEncoderSupport.supportsH264 {
            streams.append(makeVideoStreamSpec(index: streamIndex, codec: .h264))
            offeredCodecs[streamIndex] = .h264
            streamIndex += 1
        }

        guard !streams.isEmpty else {
            Log.info("cast sender: no hardware video encoders available")
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.castSenderDidFail(error: "No hardware video encoders available on this Mac")
            }
            return
        }

        let offerDict: [String: Any] = [
            "type": "OFFER",
            "seqNum": nextRequestId(),
            "offer": [
                "castMode": "mirroring",
                "supportedStreams": streams
            ]
        ]

        guard let offerData = try? JSONSerialization.data(withJSONObject: offerDict),
              let offerJson = String(data: offerData, encoding: .utf8) else { return }

        sendCastMessage(source: senderId, dest: tid, ns: "urn:x-cast:com.google.cast.webrtc", json: offerJson)
    }

    // MARK: - UDP Media Plane & RTCP Reports

    private func setupUDPStreaming(toPort port: UInt16, codec: CastVideoCodec) {
        let targetHost = resolvedHost ?? host
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetHost), port: nwPort)
        let udpParams = NWParameters.udp
        CastWire.configureLocalParameters(udpParams)

        let conn = NWConnection(to: endpoint, using: udpParams)
        udpConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                Log.info("cast sender: UDP media ready to \(targetHost):\(port) (\(codec.rawValue.uppercased()))")

                self.setConnectionState(streaming: true)
                self.hasSentFirstKeyframe = false
                self.sessionStartUs = Self.monotonicMicroseconds()
                self.lastVideoRtpTimestamp = 0
                self.hasVideoRtpTimestamp = false
                self.videoPacketsSent = 0
                self.cumulativeBytesSent = 0

                let (ntpSec, ntpFrac) = Self.currentNtpTimestamp()
                CastRTP.sendSenderReport(
                    udpConn: self.udpConnection,
                    ssrc: self.ssrc,
                    ntpSec: ntpSec,
                    ntpFrac: ntpFrac,
                    rtpTimestamp: 0,
                    packetCount: 0,
                    octetCount: 0
                )

                self.startRtcpReports()
                self.readNextUDPPacket()

                let negotiatedWidth = self.width
                let negotiatedHeight = self.height
                let negotiatedFps = self.fps
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.castSenderDidNegotiate(
                        width: negotiatedWidth,
                        height: negotiatedHeight,
                        maxFps: negotiatedFps,
                        codec: codec
                    )
                }
            case .failed(let error):
                Log.info("cast sender: UDP media failed (\(error))")
            default:
                break
            }
        }

        conn.start(queue: castQueue)
    }

    private static func currentNtpTimestamp() -> (sec: UInt32, frac: UInt32) {
        var tv = timeval()
        gettimeofday(&tv, nil)
        let ntpSec = UInt32(truncatingIfNeeded: Int64(tv.tv_sec) + 2_208_988_800)
        let ntpFrac = UInt32((Double(tv.tv_usec) * 4294.967296).rounded(.down))
        return (ntpSec, ntpFrac)
    }

    private func startRtcpReports() {
        rtcpTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: castQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.isStreaming, self.udpConnection != nil, !self.stopped else { return }
            self.sendImmediateRtcpSenderReport()
        }
        timer.resume()
        rtcpTimer = timer
    }

    private func sendImmediateRtcpSenderReport() {
        let elapsedUs = Self.monotonicMicroseconds() - sessionStartUs
        let (ntpSec, ntpFrac) = Self.currentNtpTimestamp()
        let videoTimestamp = Self.rtpTimestamp90kHz(elapsedMicroseconds: elapsedUs)

        CastRTP.sendSenderReport(
            udpConn: udpConnection,
            ssrc: ssrc,
            ntpSec: ntpSec,
            ntpFrac: ntpFrac,
            rtpTimestamp: videoTimestamp,
            packetCount: videoPacketsSent,
            octetCount: UInt32(truncatingIfNeeded: cumulativeBytesSent)
        )
    }

    private func readNextUDPPacket() {
        guard !stopped, let udpConn = udpConnection else { return }
        udpConn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, error in
            guard let self, !self.stopped else { return }
            if let content, content.count >= 4 {
                self.handleIncomingRtcpPacket(content)
            }
            if error == nil && !self.stopped && self.udpConnection != nil {
                self.readNextUDPPacket()
            }
        }
    }

    private func handleIncomingRtcpPacket(_ content: Data) {
        for event in CastRTP.parseRtcpEvents(content) {
            switch event {
            case .rrtr:
                sendImmediateRtcpSenderReport()
            case .pli:
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.castSenderDidRequestKeyframe()
                }
            case .castFeedback(let lossFields):
                var retransmittedAny = false
                for field in lossFields {
                    if retransmitPackets(frameId8: field.frameId8,
                                         lostPacketId: field.lostPacketId,
                                         bitVector: field.bitVector) {
                        retransmittedAny = true
                    }
                }
                if !retransmittedAny {
                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.castSenderDidRequestKeyframe()
                    }
                }
            }
        }
    }

    private func retransmitPackets(frameId8: UInt8, lostPacketId: UInt16, bitVector: UInt8) -> Bool {
        guard let framePackets = packetCache[frameId8], !framePackets.isEmpty else { return false }

        guard let indices = CastRTP.missingPacketIndices(
            lostPacketId: lostPacketId,
            bitVector: bitVector,
            totalPacketCount: framePackets.count
        ) else {
            // 0xFFFF requests the entire frame. If the pacing queue is already busy,
            // ask for a fresh keyframe rather than piling stale packets onto the backlog.
            guard outgoingPackets.count + framePackets.count <= Self.maxQueuedPackets / 2 else {
                return false
            }
            enqueueOutgoingPackets(framePackets)
            return true
        }

        for idx in indices {
            udpConnection?.send(content: framePackets[idx], completion: .contentProcessed { _ in })
        }
        return true
    }

    // MARK: - Paced FIFO Packet Queue

    private func enqueueOutgoingPackets(_ packets: [Data]) {
        outgoingPackets.append(contentsOf: packets)
        ensurePacingTimer()
    }

    private func ensurePacingTimer() {
        guard pacingTimer == nil, !outgoingPackets.isEmpty,
              !stopped, isStreaming, udpConnection != nil else { return }
        sendNextPacketBurst()
        guard !outgoingPackets.isEmpty else { return }

        let timer = DispatchSource.makeTimerSource(queue: castQueue)
        timer.schedule(deadline: .now() + .milliseconds(1),
                       repeating: .milliseconds(1),
                       leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in
            self?.sendNextPacketBurst()
        }
        timer.resume()
        pacingTimer = timer
    }

    private func stopPacingTimer() {
        pacingTimer?.cancel()
        pacingTimer = nil
    }

    private func sendNextPacketBurst() {
        guard !stopped, isStreaming, let udpConn = udpConnection else {
            stopPacingTimer()
            outgoingPackets.removeAll()
            return
        }
        guard !outgoingPackets.isEmpty else {
            stopPacingTimer()
            return
        }

        if outgoingPackets.count > Self.maxQueuedPackets {
            Log.info("cast sender: packet queue overflow (\(outgoingPackets.count) packets) — flushing and requesting keyframe")
            outgoingPackets.removeAll()
            stopPacingTimer()
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.castSenderDidRequestKeyframe()
            }
            return
        }

        let burst = outgoingPackets.popBurst(maxCount: Self.maxPacketBurst)
        for pkt in burst {
            videoPacketsSent &+= 1
            udpConn.send(content: pkt, completion: .contentProcessed { error in
                if let error {
                    Log.info("cast sender: UDP send error (\(error))")
                }
            })
        }

        if outgoingPackets.isEmpty {
            stopPacingTimer()
        }
    }

    // MARK: - Frame Packetization

    func enqueueAnnexBFrame(frameData: Data, isKeyframe: Bool, ptsMicroseconds ptsUs: Int64) {
        guard !stopped, isStreaming, !frameData.isEmpty else { return }

        castQueue.async { [weak self] in
            guard let self, !self.stopped, self.isStreaming, self.udpConnection != nil else { return }

            if !self.hasSentFirstKeyframe {
                guard isKeyframe else { return }
                self.hasSentFirstKeyframe = true
            }

            if self.sessionStartUs <= 0 {
                self.sessionStartUs = ptsUs
            }
            let relPtsUs = max(0, ptsUs - self.sessionStartUs)
            var rtpTimestamp = Self.rtpTimestamp90kHz(elapsedMicroseconds: relPtsUs)
            if self.hasVideoRtpTimestamp {
                // RFC 1982 modular 32-bit monotonicity check
                let delta = Int32(bitPattern: rtpTimestamp &- self.lastVideoRtpTimestamp)
                if delta <= 0 {
                    rtpTimestamp = self.lastVideoRtpTimestamp &+ 1
                }
            }
            self.lastVideoRtpTimestamp = rtpTimestamp
            self.hasVideoRtpTimestamp = true

            let currentFrameId = self.frameId
            let refFrameId: UInt8 = isKeyframe ? UInt8(currentFrameId & 0xFF) : UInt8((currentFrameId &- 1) & 0xFF)

            guard let encData = CastCrypto.encryptPayload(
                frameId: currentFrameId,
                inData: frameData,
                aesKey: self.aesKey,
                aesIvMask: self.aesIvMask
            ), !encData.isEmpty else {
                Log.info("cast sender: frame encryption failed — dropping frame \(currentFrameId)")
                return
            }

            let framePackets = CastRTP.packetizeFrame(
                encryptedPayload: encData,
                isKeyframe: isKeyframe,
                frameId: currentFrameId,
                refFrameId: refFrameId,
                rtpTimestamp: rtpTimestamp,
                ssrc: self.ssrc,
                rtpSeq: &self.rtpSeq
            )
            guard !framePackets.isEmpty else { return }

            self.frameId &+= 1

            let frameKey = UInt8(currentFrameId & 0xFF)
            self.packetCache[frameKey] = framePackets
            let staleKey = UInt8((currentFrameId &- 128) & 0xFF)
            self.packetCache.removeValue(forKey: staleKey)

            let totalLen = UInt64(frameData.count)
            self.bytesSent += totalLen
            self.cumulativeBytesSent += totalLen

            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastBitrateCalcTime)
            var updatedMbps: Double?
            if elapsed >= 1.0 {
                updatedMbps = (Double(self.bytesSent) * 8.0) / (elapsed * 1_000_000.0)
                self.bytesSent = 0
                self.lastBitrateCalcTime = now
            }

            self.stateLock.lock()
            self._framesSent += 1
            if let updatedMbps {
                self._currentBitrateMbps = updatedMbps
            }
            self.stateLock.unlock()

            self.enqueueOutgoingPackets(framePackets)
        }
    }

    // MARK: - Session Teardown

    private func finishTearDown() {
        guard !stopped else { return }
        stopped = true
        setConnectionState(connected: false, streaming: false)
        isStopping = false
        offerRetryTimer?.cancel()
        offerRetryTimer = nil
        stopPacingTimer()
        aesKey.removeAll()
        aesIvMask.removeAll()
        outgoingPackets.removeAll()

        if let tlsConn = tlsConnection {
            let closePacket = CastWire.buildMessage(
                sourceId: senderId,
                destId: "receiver-0",
                ns: "urn:x-cast:com.google.cast.tp.connection",
                jsonPayload: "{\"type\":\"CLOSE\",\"reasonCode\":5}"
            )
            tlsConn.send(content: closePacket, completion: .contentProcessed { [weak self] _ in
                self?.castQueue.async {
                    self?.tlsConnection?.cancel()
                    self?.tlsConnection = nil
                }
            })
            castQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.tlsConnection?.cancel()
                self?.tlsConnection = nil
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.castSenderDidDisconnect()
        }
    }

    func stop() {
        setConnectionState(connected: false, streaming: false)

        castQueue.async { [weak self] in
            guard let self, !self.stopped, !self.isStopping else { return }
            self.isStopping = true
            self.appState = .terminating

            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.offerRetryTimer?.cancel()
            self.offerRetryTimer = nil
            self.rtcpTimer?.cancel()
            self.rtcpTimer = nil
            self.stopPacingTimer()

            self.packetCache.removeAll()
            self.outgoingPackets.removeAll()
            self.hasSentFirstKeyframe = false

            self.udpConnection?.cancel()
            self.udpConnection = nil

            guard let tlsConn = self.tlsConnection, let sid = self.sessionId, !sid.isEmpty else {
                self.finishTearDown()
                return
            }

            if let tid = self.transportId, !tid.isEmpty {
                let closeAppPacket = CastWire.buildMessage(
                    sourceId: self.senderId,
                    destId: tid,
                    ns: "urn:x-cast:com.google.cast.tp.connection",
                    jsonPayload: "{\"type\":\"CLOSE\",\"reasonCode\":5}"
                )
                tlsConn.send(content: closeAppPacket, completion: .contentProcessed { _ in })
            }

            let reqId = self.nextRequestId()
            let stopPacket = CastWire.buildMessage(
                sourceId: self.senderId,
                destId: "receiver-0",
                ns: "urn:x-cast:com.google.cast.receiver",
                jsonPayload: "{\"type\":\"STOP\",\"sessionId\":\"\(sid)\",\"requestId\":\(reqId)}"
            )
            tlsConn.send(content: stopPacket, completion: .contentProcessed { error in
                if let error {
                    Log.info("cast sender: STOP send failed (\(error))")
                } else {
                    Log.info("cast sender: STOP sent for session \(sid)")
                }
            })

            self.castQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, !self.stopped else { return }
                self.finishTearDown()
            }
        }
    }

    private func reportStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.castSenderStatusDidChange(status)
        }
    }
}
