#if DEBUG
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Dev-only sharpness probe (#322): decodes every received sample on a side
/// session and, once the stream has been quiet for `idle`, writes the settled
/// frame to `od-idle.png` in `/tmp` (macOS) or the app's temporary directory (iOS).
/// Debug builds only, enabled with `-dumpIdleFrames YES`; creating
/// `od-dump-request` there dumps the next frame even if the screen never idles;
/// writing a number N into it saves the next N frames as `od-seq-<i>.png`.
final class IdleFrameDumper {
    static func makeIfEnabled() -> IdleFrameDumper? {
        UserDefaults.standard.bool(forKey: "dumpIdleFrames") ? IdleFrameDumper() : nil
    }

    private let queue = DispatchQueue(label: "idle-frame-dumper")
    private let idle: DispatchTimeInterval = .milliseconds(700)
    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?
    private var lastImage: CVImageBuffer?
    private var framesSinceDump = 0
    private var sequenceRemaining = 0
    private var sequence: [CVImageBuffer] = []
    private var timer: DispatchSourceTimer?
    #if os(macOS)
    private let directory = URL(fileURLWithPath: "/tmp")   // easy to reach over ssh
    #else
    private let directory = URL(fileURLWithPath: NSTemporaryDirectory())   // sandboxed
    #endif
    private var requestPath: String { directory.appendingPathComponent("od-dump-request").path }

    deinit {
        timer?.cancel()
        if let session { VTDecompressionSessionInvalidate(session) }
    }

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
            if sequenceRemaining > 0, let image = lastImage {
                sequence.append(image)
                sequenceRemaining -= 1
                if sequenceRemaining == 0 { writeSequence() }
            }
            if FileManager.default.fileExists(atPath: requestPath) {
                let count = (try? String(contentsOfFile: requestPath, encoding: .utf8))
                    .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
                try? FileManager.default.removeItem(atPath: requestPath)
                if count > 0 { sequenceRemaining = count; sequence = [] } else { dump() }
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
        // Flags [] decode synchronously, so the handler runs on this queue
        // before the call returns and `lastImage` stays queue-confined.
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                          infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            if status == noErr, let image { self?.lastImage = image }
        }
    }

    private func writeSequence() {
        for (i, image) in sequence.enumerated() { write(image, name: String(format: "od-seq-%02d.png", i)) }
        Log.info("frame sequence dumped: \(sequence.count) frames")
        sequence = []
    }

    private func dump() {
        timer = nil
        if sequenceRemaining > 0 {   // the stream went quiet before N frames arrived
            sequenceRemaining = 0
            writeSequence()
        }
        guard let image = lastImage else { return }
        if write(image, name: "od-idle.png") {
            Log.info("idle frame dumped after \(framesSinceDump) frames")
            framesSinceDump = 0
        }
    }

    @discardableResult
    private func write(_ image: CVImageBuffer, name: String) -> Bool {
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
              let cg = ctx.makeImage() else { return false }
        let url = directory.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            Log.info("frame dump failed to write \(url.path)")
            return false
        }
        return true
    }
}
#endif
