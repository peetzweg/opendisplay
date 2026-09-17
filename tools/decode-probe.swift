// Hardware-decode capability probe. Run it on the RECEIVING Mac.
//
// Answers one question before any code gets written: can this machine decode
// 5120x2880 in hardware, and in which codec? Everything else about "can we do
// true 5K" follows from that.
//
// The parameter sets below are real SPS/PPS (and VPS for HEVC) captured from an
// Apple-silicon encoder by tools/make-probe-headers.swift. They have to be real:
// a format description built with CMVideoFormatDescriptionCreate and no
// parameter sets fails session creation on EVERY Mac, including ones that decode
// the format perfectly well — so it measures nothing at all.

import Foundation
import VideoToolbox
import CoreMedia

let headers: [(label: String, codec: CMVideoCodecType, sets: String)] = [
    ("H.264  3840x2160  (4K)", kCMVideoCodecType_H264,
     "J2QAM6xWUA8AEPk=|KO48sA=="),
    ("H.264  5120x2880  (5K)", kCMVideoCodecType_H264,
     "J2QAPKxSMAUABabAWoEBARhWve+AgA==|KP4Jyw=="),
    ("HEVC   3840x2160  (4K)", kCMVideoCodecType_HEVC,
     "QAEMAf//AWAAAAMAsAAAAwAAAwCZFcCQ|QgEBAWAAAAMAsAAAAwAAAwCZoAHgIAIcWIFe5FlR|RAHALL0U2Q=="),
    ("HEVC   5120x2880  (5K)", kCMVideoCodecType_HEVC,
     "QAEMAf//AWAAAAMAsAAAAwAAAwC0FcCQ|QgEBAWAAAAMAsAAAAwAAAwC0oACgCAC0FiBXuRZUQA==|RAHALL0U2Q=="),
]

func formatDescription(codec: CMVideoCodecType, sets: [Data]) -> CMVideoFormatDescription? {
    var pointers: [UnsafePointer<UInt8>] = []
    var sizes: [Int] = []
    var keepAlive: [UnsafeMutablePointer<UInt8>] = []
    defer { keepAlive.forEach { $0.deallocate() } }

    for set in sets {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
        set.copyBytes(to: buf, count: set.count)
        keepAlive.append(buf)
        pointers.append(UnsafePointer(buf))
        sizes.append(set.count)
    }

    var format: CMVideoFormatDescription?
    let status = codec == kCMVideoCodecType_HEVC
        ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
            parameterSetPointers: pointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        : CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
            parameterSetPointers: pointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, formatDescriptionOut: &format)
    return status == noErr ? format : nil
}

/// True when VideoToolbox will build a decoder that is REQUIRED to be hardware.
/// Failure here is the signal we want: it means this silicon cannot do it.
func hardwareDecodes(_ format: CMVideoFormatDescription) -> Bool {
    let spec: [CFString: Any] = [
        kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
    ]
    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault, formatDescription: format,
        decoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
        outputCallback: nil, decompressionSessionOut: &session)
    if let session { VTDecompressionSessionInvalidate(session) }
    return status == noErr
}

/// Identify the machine in the output. Without this it is impossible to tell a
/// result pasted from the sending Mac apart from one produced on the receiver —
/// and they answer very different questions.
func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

print("")
print("MACHINE: \(Host.current().localizedName ?? "?")")
print("MODEL:   \(sysctlString("hw.model"))")
print("CPU:     \(sysctlString("machdep.cpu.brand_string"))")
print("")
print("Hardware decode support on this Mac")
print("===================================")

var hevc5kWorks = false
for entry in headers {
    let sets = entry.sets.split(separator: "|").compactMap { Data(base64Encoded: String($0)) }
    guard let format = formatDescription(codec: entry.codec, sets: sets) else {
        print("  \(entry.label)   could not build format description")
        continue
    }
    let dims = CMVideoFormatDescriptionGetDimensions(format)
    let ok = hardwareDecodes(format)
    print("  \(entry.label)   \(ok ? "OK" : "NOT SUPPORTED")   [\(dims.width)x\(dims.height)]")
    if ok, entry.codec == kCMVideoCodecType_HEVC, dims.width == 5120 { hevc5kWorks = true }
}

print("===================================")
print(hevc5kWorks
      ? "HEVC 5K decodes -> true 5K is worth implementing."
      : "No 5K path on this machine -> 4K is the ceiling. Stop here.")
print("")
