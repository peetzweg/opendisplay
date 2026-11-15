// CastDisplaySender — captures a Mac display (mirror or virtual extend),
// hardware-encodes H.264/HEVC via VideoToolbox, and streams to a Google Cast
// receiver via CastSender.

import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics

enum CastDisplayError: LocalizedError, Equatable {
    case virtualDisplayCreationFailed
    case noDisplayToMirror
    case captureDisplayNotFound
    case hardwareEncoderUnavailable(codec: CastVideoCodec, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .virtualDisplayCreationFailed:
            return "Failed to create virtual display for Cast receiver."
        case .noDisplayToMirror:
            return "No display found to mirror."
        case .captureDisplayNotFound:
            return "Failed to locate display for screen capture."
        case .hardwareEncoderUnavailable(let codec, let status):
            return "Hardware \(codec.rawValue.uppercased()) encoder unavailable (status \(status))."
        }
    }
}

@available(macOS 14.0, *)
final class CastDisplaySender: NSObject, SCStreamOutput, SCStreamDelegate, CastSenderDelegate {

    static let streamWidth = 1920
    static let streamHeight = 1080
    static let streamFps = 60
    private static let blackColor = CGColor(gray: 0, alpha: 1)
    private static let panelFacts = PanelFacts(
        pixelsWide: streamWidth,
        pixelsHigh: streamHeight,
        scale: 1,
        pointsWide: nil,
        pointsHigh: nil
    )

    @MainActor var onStatus: ((String) -> Void)?
    @MainActor var onStats: ((Int, Double) -> Void)?
    @MainActor var onDisconnected: (() -> Void)?
    @MainActor var onFailed: ((String) -> Void)?
    @MainActor var onCaptureStoppedByUser: (() -> Void)?

    private let device: CastDevice
    private let mode: CaptureMode
    private let quality: StreamQuality
    private let displaySerial: UInt32

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    @MainActor private var virtualDisplay: VirtualDisplay?
    private var sender: CastSender?
    private let queue = DispatchQueue(label: "cast.video")
    private let startCode: [UInt8] = [0, 0, 0, 1]

    private let pipelineLock = NSLock()
    private var stoppedFlag = false
    private var pendingEncodes = 0
    // Cap at 1 in-flight encode ("latest frame wins"), matching MacSender's latency profile.
    private let maxPendingEncodes = 1

    private var isStopped: Bool {
        pipelineLock.lock(); defer { pipelineLock.unlock() }
        return stoppedFlag
    }

    // Queue-confined (`queue`)
    private var captureGeneration: UInt64 = 0
    private var needsKeyframe = true
    private var lastKeyframeAt = Date.distantPast
    private var isStreaming = false
    private var captureDisplayID: CGDirectDisplayID = 0
    private var cachedParameterSets: Data?
    private var currentCodec: CastVideoCodec = .h264
    private var totalFramesSent = 0
    private var captureSourceCheck = CaptureSourceCheck()
    private var wrongDisplayReattaches = 0
    private let maxWrongDisplayReattaches = 3

    private var lastPixelBuffer: CVPixelBuffer?
    private var lastCaptureAt = Date.distantPast
    private var lastPts: CMTime = .invalid
    private var replayTimer: DispatchSourceTimer?

    init(device: CastDevice,
         mode: CaptureMode,
         quality: StreamQuality,
         displaySerial: UInt32) {
        self.device = device
        self.mode = mode
        self.quality = quality
        self.displaySerial = displaySerial
        super.init()
    }

    // MARK: - Display Sizing (`DesktopPolicy` integration)

    var arrangementKey: String { "cast:\(device.id)" }

    var displaySizeKey: String {
        DisplaySizeStore.key(installID: arrangementKey, serial: displaySerial)
    }

    func displaySizeOutcomes() -> [DisplaySizeOutcome] {
        guard mode == .extend else { return [] }
        let sent = PixelSize(width: Self.streamWidth, height: Self.streamHeight)
        return DisplaySize.allCases.map { choice in
            let plan = DesktopPolicy.plan(facts: Self.panelFacts, choice: choice)
            return DisplaySizeOutcome(choice: choice, desktop: plan.desktop, sent: sent)
        }
    }

    private func currentCanvasSize() -> VirtualCanvasSize {
        let choice = DisplaySizeStore.load(key: displaySizeKey)
        return DesktopPolicy.plan(facts: Self.panelFacts, choice: choice).desktop
    }

    func setDisplaySize(_ size: DisplaySize) {
        guard DisplaySizeStore.load(key: displaySizeKey) != size else { return }
        DisplaySizeStore.save(size, key: displaySizeKey)
        Log.info("cast display size set to \(size.rawValue) for \(displaySizeKey)")
        guard mode == .extend, !isStopped else { return }
        Task { [weak self] in
            await self?.applyCurrentDisplaySize()
        }
    }

    private func applyCurrentDisplaySize() async {
        guard !isStopped, mode == .extend else { return }
        guard let vd = await MainActor.run(body: { self.virtualDisplay }) else { return }
        let canvas = currentCanvasSize()
        let key = arrangementKey
        let targetOrigin = await MainActor.run {
            DisplayArrangement.origin(
                for: CGSize(width: canvas.pointsWide, height: canvas.pointsHigh),
                device: key
            )
        }
        let didResize = await vd.resize(
            pointsWide: canvas.pointsWide,
            pointsHigh: canvas.pointsHigh,
            scale: canvas.scale,
            movingTo: targetOrigin,
            stillCurrent: { [weak self] in !(self?.isStopped ?? true) }
        )
        guard didResize, !isStopped else { return }
        do {
            let expected = CGSize(width: canvas.pointsWide, height: canvas.pointsHigh)
            let display = try await findSCDisplay(id: vd.displayID, expectedSize: expected)
            guard !isStopped else { return }
            try await attachCapture(to: display)
        } catch {
            if !isStopped {
                Log.info("cast display size resize failed to reattach capture: \(error)")
            }
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        await status("Connecting to \(device.name)…")

        let sender = CastSender(host: device.host, port: device.port, delegate: self)
        sender.targetDelayMs = 200
        self.sender = sender
        sender.start(
            width: Int32(Self.streamWidth),
            height: Int32(Self.streamHeight),
            fps: Int32(Self.streamFps),
            maxBitrate: Int32(quality.bitrate)
        )

        var targetDisplay: SCDisplay?
        if mode == .extend {
            await status("Preparing virtual display…")
            let canvas = currentCanvasSize()
            let displayName = "OpenDisplay — \(device.name)"
            let mm = VirtualCanvasSizing.physicalSizeInMillimeters(for: canvas)
            let key = arrangementKey
            let serial = displaySerial

            let restoreOrigin = await MainActor.run {
                DisplayArrangement.origin(
                    for: CGSize(width: canvas.pointsWide, height: canvas.pointsHigh),
                    device: key
                )
            }

            let vd = await MainActor.run {
                VirtualDisplay(
                    name: displayName,
                    pointsWide: canvas.pointsWide,
                    pointsHigh: canvas.pointsHigh,
                    scale: canvas.scale,
                    descriptorMaxPixelsPerAxis: DesktopPolicy.maxPixelsPerAxis,
                    sizeInMillimeters: mm,
                    serialNum: serial,
                    productID: 0xCA57,
                    restoreOrigin: restoreOrigin,
                    onOriginChange: { origin, currentSize in
                        DisplayArrangement.save(origin: origin, size: currentSize, device: key)
                    }
                )
            }

            guard let vd else {
                throw CastDisplayError.virtualDisplayCreationFailed
            }
            await MainActor.run { self.virtualDisplay = vd }
            Log.info("cast virtual display ready: id=\(vd.displayID) \(canvas.pointsWide)x\(canvas.pointsHigh)pt @\(canvas.scale)x")
        }

        if !CGPreflightScreenCaptureAccess() {
            await status("Screen Recording permission needed — see Permissions below")
            CGRequestScreenCaptureAccess()
            while !CGPreflightScreenCaptureAccess() {
                try await Task.sleep(for: .seconds(1))
                if isStopped { return }
            }
        }

        switch mode {
        case .mirror:
            let content = try await SCShareableContent.current
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
                throw CastDisplayError.noDisplayToMirror
            }
            targetDisplay = display

        case .extend:
            if let vd = await MainActor.run(body: { self.virtualDisplay }) {
                targetDisplay = try await findSCDisplay(
                    id: vd.displayID,
                    expectedSize: CGSize(width: vd.pointsWide, height: vd.pointsHigh)
                )
            }
        }

        guard let display = targetDisplay else {
            throw CastDisplayError.captureDisplayNotFound
        }
        try await attachCapture(to: display)
    }

    private func findSCDisplay(id: CGDirectDisplayID, expectedSize: CGSize? = nil) async throws -> SCDisplay {
        var latestMatch: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.current
            if let display = content.displays.first(where: { $0.displayID == id }) {
                latestMatch = display
                if let expectedSize {
                    if display.width == Int(expectedSize.width) && display.height == Int(expectedSize.height) {
                        return display
                    }
                } else {
                    return display
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        if let latestMatch {
            return latestMatch
        }
        throw CastDisplayError.captureDisplayNotFound
    }

    private func attachCapture(to display: SCDisplay) async throws {
        let oldStream: SCStream? = queue.sync {
            let previous = self.stream
            self.stream = nil
            self.captureGeneration &+= 1
            self.captureSourceCheck = CaptureSourceCheck()
            self.lastPixelBuffer = nil
            self.lastCaptureAt = .distantPast
            self.needsKeyframe = true
            return previous
        }
        if let oldStream {
            try? await oldStream.stopCapture()
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Self.streamWidth
        config.height = Self.streamHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.streamFps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = 4
        config.showsCursor = true
        config.backgroundColor = Self.blackColor

        // Letterbox non-16:9 panels (e.g. 16:10 MacBook displays) inside 1920x1080 in Mirror mode.
        if mode == .mirror, display.width > 0, display.height > 0 {
            let fitted = VideoStreamConfiguration.fit(
                PixelSize(width: display.width, height: display.height),
                inside: PixelSize(width: Self.streamWidth, height: Self.streamHeight)
            )
            let x = Double(Self.streamWidth - fitted.width) / 2.0
            let y = Double(Self.streamHeight - fitted.height) / 2.0
            config.destinationRect = CGRect(x: x, y: y, width: Double(fitted.width), height: Double(fitted.height))
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await newStream.startCapture()

        let displayID = display.displayID
        let shouldCancel = queue.sync { () -> Bool in
            guard !self.isStopped else { return true }
            self.stream = newStream
            self.captureDisplayID = displayID
            self.isStreaming = true
            return false
        }
        if shouldCancel {
            try? await newStream.stopCapture()
            return
        }

        Log.info("cast capture attached: display=\(displayID) \(Self.streamWidth)x\(Self.streamHeight) @\(Self.streamFps)fps for \(device.name)")
    }

    private func setupEncoder(width: Int, height: Int, codec: CastVideoCodec) throws {
        cachedParameterSets = nil
        if let encoder {
            VTCompressionSessionInvalidate(encoder)
            self.encoder = nil
        }

        let cmCodec: CMVideoCodecType
        let profileLevel: CFString
        switch codec {
        case .h264:
            cmCodec = kCMVideoCodecType_H264
            profileLevel = kVTProfileLevel_H264_Main_AutoLevel
        case .hevc:
            cmCodec = kCMVideoCodecType_HEVC
            profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel
        }

        let spec: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ] as CFDictionary

        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: cmCodec,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        if session == nil {
            let hwSpec: CFDictionary = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any
            ] as CFDictionary
            status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width),
                height: Int32(height),
                codecType: cmCodec,
                encoderSpecification: hwSpec,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
        }

        guard let encoder = session else {
            throw CastDisplayError.hardwareEncoderUnavailable(codec: codec, status: status)
        }

        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (Self.streamFps * 2) as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: quality.bitrate as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: Self.streamFps as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(encoder)

        self.encoder = encoder
        currentCodec = codec
        Log.info("cast \(codec.rawValue.uppercased()) encoder ready: \(width)x\(height) \(quality.bitrate / 1_000_000)Mbps")
    }

    func stop() {
        pipelineLock.lock()
        guard !stoppedFlag else {
            pipelineLock.unlock()
            return
        }
        stoppedFlag = true
        pendingEncodes = 0
        pipelineLock.unlock()

        let activeSender = sender
        sender = nil
        activeSender?.stop()

        queue.async { [weak self] in
            guard let self else { return }
            self.captureGeneration &+= 1
            self.isStreaming = false
            self.replayTimer?.cancel()
            self.replayTimer = nil
            self.lastPixelBuffer = nil
            self.lastPts = .invalid
            self.cachedParameterSets = nil

            let activeStream = self.stream
            self.stream = nil
            activeStream?.stopCapture { _ in }

            if let encoder = self.encoder {
                VTCompressionSessionInvalidate(encoder)
                self.encoder = nil
            }
        }

        Task { @MainActor in
            self.virtualDisplay = nil
        }
        Log.info("cast display sender stopped for \(device.name)")
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let isCurrent = queue.sync { stream === self.stream }
        guard isCurrent, !isStopped else { return }
        Log.info("cast capture stopped: \(error)")
        if let scError = error as? SCStreamError, scError.code == .userStopped {
            Task { @MainActor in
                self.onCaptureStoppedByUser?()
            }
            return
        }
        stop()
        Task { @MainActor in
            self.onFailed?("Capture stopped: \(error.localizedDescription)")
        }
    }

    private func startReplayTimer() {
        replayTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.isStreaming, !self.isStopped else { return }
            if Date().timeIntervalSince(self.lastCaptureAt) >= 0.09, let pixelBuffer = self.lastPixelBuffer {
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                self.encodePixelBuffer(pixelBuffer, pts: pts, forceKeyframe: self.needsKeyframe)
            }
        }
        timer.resume()
        replayTimer = timer
    }

    // MARK: - SCStreamOutput (`queue`)

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard stream === self.stream,
              type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              !isStopped
        else { return }

        if capturingAnotherDisplay(sampleBuffer) {
            reattachCaptureToOwnDisplay()
            return
        }

        lastPixelBuffer = pixelBuffer
        lastCaptureAt = Date()

        guard isStreaming else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encodePixelBuffer(pixelBuffer, pts: pts, forceKeyframe: false)
    }

    /// Guards against macOS ScreenCaptureKit bug #391 (delivering frames from a sibling monitor after wake).
    private func capturingAnotherDisplay(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let displayID = captureDisplayID
        guard mode == .extend, displayID != 0,
              wrongDisplayReattaches < maxWrongDisplayReattaches,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rectDictionary = info[.screenRect] as? NSDictionary,
              let screenRect = CGRect(dictionaryRepresentation: rectDictionary)
        else { return false }

        let expected = CGDisplayBounds(displayID)
        guard captureSourceCheck.frame(screenRect: screenRect, expected: expected) else { return false }
        wrongDisplayReattaches += 1
        Log.info("cast capture of display \(displayID) delivered \(screenRect), expected \(expected) — re-attaching (#391, \(wrongDisplayReattaches)/\(maxWrongDisplayReattaches))")
        return true
    }

    private func reattachCaptureToOwnDisplay() {
        guard !isStopped, mode == .extend else { return }
        let displayID = captureDisplayID
        lastPixelBuffer = nil
        Task { [weak self] in
            guard let self, !self.isStopped else { return }
            do {
                let display = try await self.findSCDisplay(id: displayID)
                try await self.attachCapture(to: display)
            } catch {
                if !self.isStopped {
                    Log.info("cast #391 capture re-attach failed: \(error)")
                }
            }
        }
    }

    private func encodePixelBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) {
        guard let encoder, !isStopped else { return }

        pipelineLock.lock()
        guard !stoppedFlag, pendingEncodes < maxPendingEncodes else {
            pipelineLock.unlock()
            return
        }
        pendingEncodes += 1
        pipelineLock.unlock()

        var framePts = pts
        if lastPts.isValid && CMTimeCompare(framePts, lastPts) <= 0 {
            framePts = CMTime(value: lastPts.value + 1, timescale: lastPts.timescale)
        }
        lastPts = framePts

        let ptsSeconds = CMTimeGetSeconds(framePts)
        let ptsUs: Int64 = ptsSeconds.isFinite ? Int64(ptsSeconds * 1_000_000) : CastSender.monotonicMicroseconds()
        let generation = captureGeneration

        var frameProperties: CFDictionary?
        if forceKeyframe || needsKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            needsKeyframe = false
            lastKeyframeAt = Date()
        }

        let submitStatus = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: framePts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, buffer in
            guard let self else { return }
            self.pipelineLock.lock()
            self.pendingEncodes = max(0, self.pendingEncodes - 1)
            self.pipelineLock.unlock()

            guard status == noErr, let buffer else {
                if status != noErr {
                    Log.info("cast encode failed: status \(status)")
                }
                return
            }

            // Serialize Annex B framing + parameter-set cache onto `queue`.
            self.queue.async { [weak self] in
                guard let self, !self.isStopped, self.captureGeneration == generation else { return }
                let isKey = self.isKeyframe(buffer)
                guard let annexBData = self.annexB(from: buffer, isKeyframe: isKey) else { return }

                self.sender?.enqueueAnnexBFrame(
                    frameData: annexBData,
                    isKeyframe: isKey,
                    ptsMicroseconds: ptsUs
                )

                self.totalFramesSent += 1
                if self.totalFramesSent == 1 {
                    Log.info("cast stream active: first \(self.currentCodec.rawValue.uppercased()) frame (\(annexBData.count) bytes, keyframe=\(isKey))")
                }
                if self.totalFramesSent % 60 == 0, let sender = self.sender {
                    let frames = Int(sender.framesSent)
                    let mbps = sender.currentBitrateMbps
                    Task { @MainActor in
                        self.onStats?(frames, mbps)
                    }
                }
            }
        }

        if submitStatus != noErr {
            pipelineLock.lock()
            pendingEncodes = max(0, pendingEncodes - 1)
            pipelineLock.unlock()
            Log.info("cast encode submit failed: status \(submitStatus)")
        }
    }

    private func annexB(from sample: CMSampleBuffer, isKeyframe: Bool) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &len,
            totalLengthOut: &total,
            dataPointerOut: &ptr
        ) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 128)

        if isKeyframe {
            if cachedParameterSets == nil, let fmt = CMSampleBufferGetFormatDescription(sample) {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(fmt)
                var paramSets = Data()

                if mediaSubType == kCMVideoCodecType_HEVC {
                    var count = 0
                    if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        fmt, parameterSetIndex: 0,
                        parameterSetPointerOut: nil,
                        parameterSetSizeOut: nil,
                        parameterSetCountOut: &count,
                        nalUnitHeaderLengthOut: nil
                    ) == noErr {
                        for i in 0..<count {
                            var psPtr: UnsafePointer<UInt8>?
                            var psLen = 0
                            if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                                fmt, parameterSetIndex: i,
                                parameterSetPointerOut: &psPtr,
                                parameterSetSizeOut: &psLen,
                                parameterSetCountOut: nil,
                                nalUnitHeaderLengthOut: nil
                            ) == noErr, let psPtr {
                                paramSets.append(contentsOf: startCode)
                                paramSets.append(contentsOf: UnsafeRawBufferPointer(start: psPtr, count: psLen))
                            }
                        }
                    }
                } else {
                    var count = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: 0,
                        parameterSetPointerOut: nil,
                        parameterSetSizeOut: nil,
                        parameterSetCountOut: &count,
                        nalUnitHeaderLengthOut: nil
                    ) == noErr {
                        for i in 0..<count {
                            var psPtr: UnsafePointer<UInt8>?
                            var psLen = 0
                            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                                fmt, parameterSetIndex: i,
                                parameterSetPointerOut: &psPtr,
                                parameterSetSizeOut: &psLen,
                                parameterSetCountOut: nil,
                                nalUnitHeaderLengthOut: nil
                            ) == noErr, let psPtr {
                                paramSets.append(contentsOf: startCode)
                                paramSets.append(contentsOf: UnsafeRawBufferPointer(start: psPtr, count: psLen))
                            }
                        }
                    }
                }

                if !paramSets.isEmpty {
                    cachedParameterSets = paramSets
                }
            }

            if let paramSets = cachedParameterSets {
                out.append(paramSets)
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
            out.append(contentsOf: UnsafeRawBufferPointer(start: raw + offset, count: Int(nalLen)))
            offset += Int(nalLen)
        }
        return out
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let dict = (arr as? [[CFString: Any]])?.first else { return true }
        return !(dict[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    // MARK: - CastSenderDelegate

    func castSenderDidConnect() {
        Task { @MainActor in
            self.onStatus?("Connected to \(self.device.name)")
        }
    }

    func castSenderDidNegotiate(width: Int32, height: Int32, maxFps: Int32, codec: CastVideoCodec) {
        let modeVerb = mode == .extend ? "Extending to" : "Mirroring to"
        Task { @MainActor in
            self.onStatus?("\(modeVerb) \(self.device.name) (\(width)×\(height))")
        }
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.needsKeyframe = true
            do {
                try self.setupEncoder(width: Int(width), height: Int(height), codec: codec)
            } catch {
                Log.info("cast encoder setup failed: \(error)")
                let message = error.localizedDescription
                self.stop()
                Task { @MainActor in
                    self.onFailed?(message)
                }
                return
            }
            self.startReplayTimer()
            if let pixelBuffer = self.lastPixelBuffer {
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                self.encodePixelBuffer(pixelBuffer, pts: pts, forceKeyframe: true)
            }
        }
    }

    func castSenderDidRequestKeyframe() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.needsKeyframe = true
            guard let pixelBuffer = self.lastPixelBuffer, self.isStreaming else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastKeyframeAt) >= 0.25 else { return }
            self.lastKeyframeAt = now
            let pts = CMClockGetTime(CMClockGetHostTimeClock())
            self.encodePixelBuffer(pixelBuffer, pts: pts, forceKeyframe: true)
        }
    }

    func castSenderDidFail(error: String) {
        guard !isStopped else { return }
        stop()
        Task { @MainActor in
            self.onFailed?(error)
        }
    }

    func castSenderDidDisconnect() {
        guard !isStopped else { return }
        stop()
        Task { @MainActor in
            self.onDisconnected?()
        }
    }

    func castSenderStatusDidChange(_ status: String) {
        guard !isStopped else { return }
        Task { @MainActor in
            self.onStatus?(status)
        }
    }

    private func status(_ text: String) async {
        await MainActor.run {
            self.onStatus?(text)
        }
    }
}
