import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

// Standalone API probe, not an import of MacSender. Keep the requested capture
// space, encoder tags, and frame attachments aligned with the production patch.
// A pass here does not prove that the app still calls these APIs correctly.
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let patches: [[UInt8]] = [
    [0, 0, 0], [16, 16, 16], [41, 41, 41], [64, 64, 64],
    [96, 96, 96], [128, 128, 128], [160, 160, 160], [192, 192, 192],
    [224, 224, 224], [235, 235, 235], [248, 248, 248], [255, 255, 255],
    [235, 20, 20], [20, 230, 20], [20, 20, 230], [60, 180, 75]
]
let width = 1280, height = 768
let omitRelabel = CommandLine.arguments.contains("--omit-relabel")
let captureBGRA = CommandLine.arguments.contains("--bgra")
let colorKeys: [CFString] = [kCVImageBufferColorPrimariesKey,
                           kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
let colorValues: [CFString] = [kCVImageBufferColorPrimaries_P3_D65,
                             kCVImageBufferTransferFunction_sRGB, kCVImageBufferYCbCrMatrix_ITU_R_709_2]
let ci = CIContext(options: [.cacheIntermediates: false])

func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}
func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw NSError(domain: operation, code: Int(status)) }
}
func bufferTags(_ buffer: CVPixelBuffer) -> [String: String] {
    var tags: [String: String] = [:]
    for key in colorKeys {
        tags[key as String] = CVBufferCopyAttachment(buffer, key, nil).map { String(describing: $0) } ?? "<absent>"
    }
    return tags
}
func formatTags(_ format: CMFormatDescription) -> [String: String] {
    var tags: [String: String] = [:]
    for key in [kCMFormatDescriptionExtension_ColorPrimaries,
                kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix] {
        tags[key as String] = CMFormatDescriptionGetExtension(format, extensionKey: key).map { String(describing: $0) } ?? "<absent>"
    }
    return tags
}

final class Chart: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (i, rgb) in patches.enumerated() {
            context.setFillColor(CGColor(colorSpace: p3, components: rgb.map { CGFloat($0) / 255 } + [1])!)
            context.fill(CGRect(x: CGFloat(i % 4) * bounds.width / 4,
                                y: CGFloat(3 - i / 4) * bounds.height / 4,
                                width: bounds.width / 4, height: bounds.height / 4))
        }
    }
}

final class Capture: NSObject, SCStreamOutput {
    let lock = NSLock()
    private var first: CVPixelBuffer?
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let status = info[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sample.imageBuffer else { return }
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = buffer }
    }
    func frame() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return first }
}

final class Encoded {
    var status: OSStatus = noErr
    var sample: CMSampleBuffer?
}
final class Decoded {
    var status: OSStatus = noErr
    var buffer: CVPixelBuffer?
}

// Reconstruct the format from parameter sets, as the receiver does after NALU
// transport; do not hand the encoder's in-process format straight to the decoder.
func wireFormat(_ format: CMFormatDescription, codec: CMVideoCodecType) throws -> CMVideoFormatDescription {
    var sets: [Data] = []
    var count = 0, header: Int32 = 0
    let get: (Int, UnsafeMutablePointer<UnsafePointer<UInt8>?>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?) -> OSStatus = { index, pointer, size, count, header in
        if codec == kCMVideoCodecType_HEVC {
            return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: pointer, parameterSetSizeOut: size, parameterSetCountOut: count, nalUnitHeaderLengthOut: header)
        }
        return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
            parameterSetPointerOut: pointer, parameterSetSizeOut: size, parameterSetCountOut: count, nalUnitHeaderLengthOut: header)
    }
    var pointer: UnsafePointer<UInt8>?, size = 0
    try check(get(0, &pointer, &size, &count, &header), "get parameter-set count")
    for i in 0..<count {
        try check(get(i, &pointer, &size, nil, nil), "get parameter set")
        sets.append(Data(bytes: pointer!, count: size))
    }
    var output: CMVideoFormatDescription?
    // Own each allocation for the entire CreateFrom call.
    let allocations = sets.map { data -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: p, count: data.count)
        return p
    }
    defer { allocations.forEach { $0.deallocate() } }
    let pointers = allocations.map { UnsafePointer($0) }
    let sizes = sets.map(\.count)
    let status = pointers.withUnsafeBufferPointer { pp in sizes.withUnsafeBufferPointer { ss in
        if codec == kCMVideoCodecType_HEVC {
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: sets.count, parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!,
                nalUnitHeaderLength: header, extensions: nil, formatDescriptionOut: &output)
        }
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count, parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!,
            nalUnitHeaderLength: header, formatDescriptionOut: &output)
    }}
    try check(status, "reconstruct wire format")
    return output!
}

func roundTrip(_ buffer: CVPixelBuffer, codec: CMVideoCodecType) throws -> (CVPixelBuffer, [String: String], Bool) {
    let result = Encoded()
    let ref = Unmanaged.passUnretained(result).toOpaque()
    var encoder: VTCompressionSession?
    try check(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
        codecType: codec, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: { ref, _, status, _, sample in
            let result = Unmanaged<Encoded>.fromOpaque(ref!).takeUnretainedValue()
            result.status = status; result.sample = sample
        }, refcon: ref, compressionSessionOut: &encoder), "create encoder")
    guard let encoder else { throw NSError(domain: "missing encoder", code: 1) }
    defer { VTCompressionSessionInvalidate(encoder) }
    for (key, value) in [(kVTCompressionPropertyKey_ColorPrimaries, colorValues[0]),
                         (kVTCompressionPropertyKey_TransferFunction, colorValues[1]),
                         (kVTCompressionPropertyKey_YCbCrMatrix, colorValues[2])] {
        try check(VTSessionSetProperty(encoder, key: key, value: value), "set \(key)")
    }
    try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue), "set realtime")
    try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), "disable reordering")
    try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel,
        value: codec == kCMVideoCodecType_HEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel), "set profile")
    try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: 18_000_000 as CFNumber), "set bitrate")
    var hardware: Unmanaged<CFTypeRef>?
    try check(VTSessionCopyProperty(encoder, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                   allocator: nil, valueOut: &hardware), "query encoder hardware")
    try check(VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: .zero,
        duration: CMTime(value: 1, timescale: 60), frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
        sourceFrameRefcon: nil, infoFlagsOut: nil), "encode")
    try check(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), "complete encode")
    try check(result.status, "encode callback")
    guard let sample = result.sample, let format = sample.formatDescription, let block = sample.dataBuffer else {
        throw NSError(domain: "encoder produced no sample", code: 1)
    }
    let reconstructed = try wireFormat(format, codec: codec)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var length = CMBlockBufferGetDataLength(block), transported: CMSampleBuffer?
    try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: reconstructed,
        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &length, sampleBufferOut: &transported), "rebuild sample")
    let decoded = Decoded()
    var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, buffer, _, _ in
        let result = Unmanaged<Decoded>.fromOpaque(ref!).takeUnretainedValue()
        result.status = status; result.buffer = buffer
    }, decompressionOutputRefCon: Unmanaged.passUnretained(decoded).toOpaque())
    var decoder: VTDecompressionSession?
    try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: reconstructed,
        decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
        outputCallback: &callback, decompressionSessionOut: &decoder), "create decoder")
    defer { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
    try check(VTDecompressionSessionDecodeFrame(decoder!, sampleBuffer: transported!, flags: [], frameRefcon: nil, infoFlagsOut: nil), "decode")
    try check(VTDecompressionSessionWaitForAsynchronousFrames(decoder!), "wait decode")
    try check(decoded.status, "decode callback")
    guard let output = decoded.buffer else { throw NSError(domain: "decoder produced no image", code: 1) }
    return (output, formatTags(reconstructed), (hardware?.takeRetainedValue() as? Bool) ?? false)
}

func samplePatches(_ buffer: CVPixelBuffer) throws -> [[Double]] {
    let image = CIImage(cvPixelBuffer: buffer)
    guard let cg = ci.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: p3) else {
        throw NSError(domain: "convert decoded buffer to Display P3", code: 1)
    }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    try bytes.withUnsafeMutableBytes { raw in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw NSError(domain: "create sampling context", code: 1)
        }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return patches.indices.map { i in
        let x = (i % 4) * width / 4 + width / 8
        let y = (i / 4) * height / 4 + height / 8
        var sum = [Double](repeating: 0, count: 3)
        for dy in -4...4 { for dx in -4...4 { for c in 0..<3 {
            sum[c] += Double(bytes[((y + dy) * width + x + dx) * 4 + c])
        }}}
        return sum.map { $0 / 81 }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard CGPreflightScreenCaptureAccess() else {
    fputs("SKIP: no Screen Recording permission. Run from an authorized terminal; this probe does not request permission.\n", stderr)
    exit(77)
}
let window = NSWindow(contentRect: CGRect(x: 80, y: 120, width: 640, height: 384),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.title = "OpenDisplay P3 API probe"
window.isReleasedWhenClosed = false
window.level = .floating
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
window.isOpaque = true
window.contentView = Chart(frame: CGRect(x: 0, y: 0, width: 640, height: 384))
window.orderFrontRegardless()
window.displayIfNeeded()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    fputs("FAIL: probe timed out\n", stderr)
    exit(1)
}
Task { @MainActor in
    var stream: SCStream?
    do {
        // Let WindowServer publish the newly drawn window before querying SCK.
        try await Task.sleep(nanoseconds: 300_000_000)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let source = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            emit(["event": "window-discovery-failed", "requestedID": window.windowNumber,
                  "ownWindowIDs": content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }.map(\.windowID)])
            throw NSError(domain: "own chart window not found", code: 1)
        }
        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.pixelFormat = captureBGRA ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.displayP3
        if !captureBGRA { config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2 }
        config.showsCursor = false
        config.queueDepth = 3
        config.ignoreShadowsSingleWindow = true
        let capture = Capture()
        let active = SCStream(filter: SCContentFilter(desktopIndependentWindow: source), configuration: config, delegate: nil)
        stream = active
        try active.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "p3-probe.capture"))
        try await active.startCapture()
        var buffer: CVPixelBuffer?
        for _ in 0..<100 {
            if let first = capture.frame() { buffer = first; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await active.stopCapture()
        stream = nil
        window.orderOut(nil)
        guard let buffer else { throw NSError(domain: "no complete captured frame in five seconds", code: 1) }
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
            throw NSError(domain: "unexpected capture dimensions", code: 1)
        }
        emit(["event": "capture", "os": ProcessInfo.processInfo.operatingSystemVersionString,
              "width": width, "height": height, "pixelFormat": CVPixelBufferGetPixelFormatType(buffer),
              "requestedSpace": "Display P3", "attachments": bufferTags(buffer), "windowOnly": true])
        var failed = false
        let originals = colorKeys.map { CVBufferCopyAttachment(buffer, $0, nil) }
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            for relabel in (omitRelabel ? [false] : [false, true]) {
                for (i, key) in colorKeys.enumerated() {
                    if relabel { CVBufferSetAttachment(buffer, key, colorValues[i], .shouldPropagate) }
                    else if let value = originals[i] { CVBufferSetAttachment(buffer, key, value, .shouldPropagate) }
                    else { CVBufferRemoveAttachment(buffer, key) }
                }
                let (output, tags, hardware) = try roundTrip(buffer, codec: codec)
                let pixels = try samplePatches(output)
                let errors = zip(patches, pixels).map { expected, actual in
                    zip(expected, actual).map { abs(Double($0) - $1) }.max()!
                }
                let maxError = errors.max()!
                let expectedTags = [kCMFormatDescriptionExtension_ColorPrimaries as String: "P3_D65",
                                    kCMFormatDescriptionExtension_TransferFunction as String: "IEC_sRGB",
                                    kCMFormatDescriptionExtension_YCbCrMatrix as String: "ITU_R_709_2"]
                let passed = maxError <= 6 && tags == expectedTags
                emit(["event": "round-trip", "codec": codec == kCMVideoCodecType_H264 ? "H.264" : "HEVC",
                      "relabel": relabel, "hardwareEncode": hardware, "wireTags": tags,
                      "decodedAttachments": bufferTags(output), "maxChannelError": maxError,
                      "withinTolerance": passed,
                      "patches": zip(patches, pixels).map { ["expected": $0.map(Double.init), "decoded": $1] }])
                if (relabel || omitRelabel) && !passed { failed = true }
            }
        }
        emit(["event": "verdict", "passed": !failed, "candidateRelabelled": !omitRelabel])
        fputs(failed ? "FAIL: candidate round trip differs from the chart or loses colour tags\n" : "PASS: both candidate codecs preserve tags and broad patches within six levels\n", stderr)
        exit(failed ? 1 : 0)
    } catch {
        if let stream { try? await stream.stopCapture() }
        window.orderOut(nil)
        fputs("FAIL: \(error)\n", stderr)
        exit(1)
    }
}
app.run()
