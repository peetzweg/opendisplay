// Generates real H.264/HEVC parameter sets (SPS/PPS, and VPS for HEVC) by
// encoding one frame at each target size, and prints them as base64.
//
// Why: a decode-capability probe needs a VALID format description. Building one
// with CMVideoFormatDescriptionCreate and no parameter sets fails session
// creation on every Mac, including ones that decode the format fine — so it
// measures nothing. These headers get embedded in decode-probe.swift, which can
// then run on a machine that cannot ENCODE the size it is asked to DECODE.
//
// Run on a Mac that can encode 5K (Apple silicon).

import Foundation
import VideoToolbox
import CoreMedia

func parameterSets(codec: CMVideoCodecType, width: Int32, height: Int32) -> [Data]? {
    var session: VTCompressionSession?
    guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                     width: width, height: height,
                                     codecType: codec,
                                     encoderSpecification: nil,
                                     imageBufferAttributes: nil,
                                     compressedDataAllocator: nil,
                                     outputCallback: nil, refcon: nil,
                                     compressionSessionOut: &session) == noErr,
          let session else { return nil }
    defer { VTCompressionSessionInvalidate(session) }

    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, Int(width), Int(height),
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixelBuffer)
    guard let pixelBuffer else { return nil }

    var result: [Data]?
    let sem = DispatchSemaphore(value: 0)
    VTCompressionSessionEncodeFrame(
        session, imageBuffer: pixelBuffer,
        presentationTimeStamp: CMTime(value: 0, timescale: 30),
        duration: .invalid, frameProperties: nil, infoFlagsOut: nil
    ) { status, _, sample in
        defer { sem.signal() }
        guard status == noErr, let sample,
              let format = CMSampleBufferGetFormatDescription(sample) else { return }

        // HEVC has its own accessor (3 sets: VPS, SPS, PPS); the H264 one
        // returns an error for HEVC format descriptions rather than serving them.
        let isHEVC = (codec == kCMVideoCodecType_HEVC)
        var count = 0
        let countStatus = isHEVC
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil)
        guard countStatus == noErr, count > 0 else { return }

        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st = isHEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
            if st == noErr, let ptr { sets.append(Data(bytes: ptr, count: size)) }
        }
        result = sets.isEmpty ? nil : sets
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    _ = sem.wait(timeout: .now() + 10)
    return result
}

let targets: [(String, CMVideoCodecType, Int32, Int32)] = [
    ("h264_3840x2160", kCMVideoCodecType_H264, 3840, 2160),
    ("h264_5120x2880", kCMVideoCodecType_H264, 5120, 2880),
    ("hevc_3840x2160", kCMVideoCodecType_HEVC, 3840, 2160),
    ("hevc_5120x2880", kCMVideoCodecType_HEVC, 5120, 2880),
]

for (name, codec, w, h) in targets {
    if let sets = parameterSets(codec: codec, width: w, height: h) {
        let joined = sets.map { $0.base64EncodedString() }.joined(separator: "|")
        print("\"\(name)\": \"\(joined)\",")
    } else {
        print("// \(name): ENCODE FAILED on this Mac")
    }
}
