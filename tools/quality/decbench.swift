// Decode-throughput benchmark.
//   encode <hevc|h264> <outfile> <png...>   (sender: hardware-encode the frames, looped 4x, 18 Mbps)
//   decode <file>                             (receiver: hardware-decode every frame as fast as possible)
// File: [u8 codec][u32 nParamSets]{[u32 len][bytes]}*[u32 nFrames]{[u32 len][AVCC sample]}*
import Foundation
import CoreMedia
import VideoToolbox
import ImageIO

func u32(_ v: Int) -> Data { var b = UInt32(v).bigEndian; return Data(bytes: &b, count: 4) }
let args = CommandLine.arguments

if args[1] == "encode" {
    let hevc = args[2] == "hevc"
    let images = args[4...].map { CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: $0) as CFURL, nil)!, 0, nil)! }
    let w = images[0].width, h = images[0].height
    var session: VTCompressionSession?
    let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
    precondition(VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h),
        codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, encoderSpecification: spec,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &session) == noErr)
    let s = session!
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 18_000_000 as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
    var params: [Data] = []; var frames: [Data] = []
    let lock = NSLock()
    for i in 0..<(images.count * 4) {
        let img = images[i % images.count]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb!, presentationTimeStamp: CMTime(value: Int64(i), timescale: 60),
                                        duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
            guard status == noErr, let sb, let block = CMSampleBufferGetDataBuffer(sb) else { return }
            lock.lock(); defer { lock.unlock() }
            if params.isEmpty, let fmt = CMSampleBufferGetFormatDescription(sb) {
                for k in 0..<(hevc ? 3 : 2) {
                    var p: UnsafePointer<UInt8>?; var n = 0
                    if hevc { CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: k, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) }
                    else { CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: k, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) }
                    params.append(Data(bytes: p!, count: n))
                }
            }
            var d = Data(count: CMBlockBufferGetDataLength(block))
            d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            frames.append(d)
        }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    }
    var out = Data([hevc ? 1 : 0]) + u32(params.count)
    for p in params { out += u32(p.count) + p }
    out += u32(frames.count)
    for f in frames { out += u32(f.count) + f }
    try! out.write(to: URL(fileURLWithPath: args[3]))
    print("\(args[2]) \(w)x\(h): \(frames.count) frames, \(frames.reduce(0) { $0 + $1.count } / frames.count) bytes/frame avg")
} else {
    let d = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
    var o = 0
    func r32() -> Int { let v = d[o..<o+4].reduce(0) { $0 << 8 | Int($1) }; o += 4; return v }
    let hevc = d[0] == 1; o = 1
    let np = r32(); var params: [Data] = []
    for _ in 0..<np { let n = r32(); params.append(d[o..<o+n]); o += n }
    let nf = r32(); var frames: [Data] = []
    for _ in 0..<nf { let n = r32(); frames.append(d[o..<o+n]); o += n }
    var fmt: CMFormatDescription?
    let ptrs = params.map { p -> UnsafePointer<UInt8> in let m = UnsafeMutablePointer<UInt8>.allocate(capacity: p.count); p.copyBytes(to: m, count: p.count); return UnsafePointer(m) }
    let sizes = params.map { $0.count }
    let st = hevc
        ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: np, parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: np, parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
    precondition(st == noErr, "format \(st)")
    let dims = CMVideoFormatDescriptionGetDimensions(fmt!)
    print("hardware decode supported: \(VTIsHardwareDecodeSupported(hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264))")
    var session: VTDecompressionSession?
    let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: kCFBooleanTrue] as CFDictionary
    let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
    precondition(VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt!, decoderSpecification: spec,
                 imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &session) == noErr)
    var errors = 0, done = 0
    let lock = NSLock()
    func decode(_ f: Data) {
        var block: CMBlockBuffer?
        f.withUnsafeBytes { raw in
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: f.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: f.count, flags: 0, blockBufferOut: &block)
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: f.count)
        }
        var sb: CMSampleBuffer?; var size = f.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sb!, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, img, _, _ in
            lock.lock(); if status != noErr || img == nil { errors += 1 }; done += 1; lock.unlock()
        }
    }
    // Two passes: sequential (one frame at a time, the receiver's live pattern) and pipelined.
    for mode in ["sequential", "pipelined"] {
        let t0 = Date()
        for f in frames {
            decode(f)
            if mode == "sequential" { VTDecompressionSessionWaitForAsynchronousFrames(session!) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
        let dt = Date().timeIntervalSince(t0)
        print("\(hevc ? "HEVC" : "H264") \(dims.width)x\(dims.height) \(mode): \(frames.count) frames in \(String(format: "%.2f", dt)) s = \(String(format: "%.0f", Double(frames.count) / dt)) fps, errors \(errors)")
    }
}
