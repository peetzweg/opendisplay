import XCTest
import VideoToolbox
import CoreMedia

final class HEVCEncodingTests: XCTestCase {

    private func makeSession(codec: CMVideoCodecType, width: Int32, height: Int32,
                             lowLatency: Bool) -> (VTCompressionSession?, OSStatus) {
        var encoder: VTCompressionSession?
        let spec: CFDictionary? = lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
            : nil
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width, height: height,
            codecType: codec,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder)
        return (encoder, status)
    }

    func testHEVCCompressionSessionCreation() throws {
        // Same fallback ladder as the sender: low-latency spec first, plain
        // session when no encoder offers the mode (#133).
        var (encoder, _) = makeSession(codec: kCMVideoCodecType_HEVC,
                                       width: 1920, height: 1080, lowLatency: true)
        if encoder == nil {
            (encoder, _) = makeSession(codec: kCMVideoCodecType_HEVC,
                                       width: 1920, height: 1080, lowLatency: false)
        }
        // No HEVC encoder at all is a machine property, not a regression —
        // the sender's negotiation stays on H.264 there.
        try XCTSkipIf(encoder == nil, "this machine has no HEVC encoder")

        if let encoder {
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: 15_000_000 as CFNumber)
            let prepStatus = VTCompressionSessionPrepareToEncodeFrames(encoder)
            XCTAssertEqual(prepStatus, noErr)
            VTCompressionSessionInvalidate(encoder)
        }
    }

    func testH264CompressionSessionCreation() {
        let (encoder, status) = makeSession(codec: kCMVideoCodecType_H264,
                                            width: 1280, height: 720, lowLatency: false)
        XCTAssertEqual(status, noErr)
        XCTAssertNotNil(encoder)
        if let encoder { VTCompressionSessionInvalidate(encoder) }
    }
}
