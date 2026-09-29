import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Dev-only sharpness probe (#322): decodes every received sample on a side
/// session and, once the stream has been quiet for `idle`, writes the settled
/// frame to `/tmp/od-idle.png`. Debug builds only, enabled with
/// `-dumpIdleFrames YES`.
final class IdleFrameDumper {
    static func makeIfEnabled() -> IdleFrameDumper? {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "dumpIdleFrames") ? IdleFrameDumper() : nil
        #else
        nil
        #endif
    }

    private let queue = DispatchQueue(label: "idle-frame-dumper")
    private let idle: DispatchTimeInterval = .milliseconds(700)
    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?
    private var lastImage: CVImageBuffer?
    private var framesSinceDump = 0
    private var timer: DispatchSourceTimer?

    func push(_ shared: CMSampleBuffer) {
        // The display path mutates the shared sample's attachments right after
        // this call; VideoToolbox reading them on our queue at the same time
        // crashed (NSDictionary objectForKey). Decode a private sample that
        // shares only the immutable data and format.
        guard let data = CMSampleBufferGetDataBuffer(shared),
              let format = CMSampleBufferGetFormatDescription(shared) else { return }
        var size = CMSampleBufferGetTotalSampleSize(shared)
        var privateSample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
                                        formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &privateSample) == noErr,
              let sample = privateSample else { return }
        queue.async { [self] in
            decode(sample)
            framesSinceDump += 1
            // `touch /tmp/od-dump-request` dumps the next frame even if the screen never idles.
            if FileManager.default.fileExists(atPath: "/tmp/od-dump-request") {
                try? FileManager.default.removeItem(atPath: "/tmp/od-dump-request")
                dump()
            }
            timer?.cancel()
            let next = DispatchSource.makeTimerSource(queue: queue)
            next.schedule(deadline: .now() + idle)
            next.setEventHandler { [weak self] in self?.dump() }
            next.resume()
            timer = next
        }
    }

    private func decode(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        if let session, let sessionFormat, CMFormatDescriptionEqual(format, otherFormatDescription: sessionFormat) == false {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        if session == nil {
            let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
            VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                         decoderSpecification: nil, imageBufferAttributes: attrs,
                                         outputCallback: nil, decompressionSessionOut: &session)
            sessionFormat = format
        }
        guard let session else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                          infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            if status == noErr, let image { self?.lastImage = image }
        }
    }

    private func dump() {
        timer = nil
        guard let image = lastImage else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(image),
                                  width: CVPixelBufferGetWidth(image),
                                  height: CVPixelBufferGetHeight(image),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(image),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue),
              let cg = ctx.makeImage() else { return }
        let url = URL(fileURLWithPath: "/tmp/od-idle.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        Log.info("idle frame dumped after \(framesSinceDump) frames")
        framesSinceDump = 0
    }
}
