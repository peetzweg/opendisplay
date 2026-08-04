// MetalVideoRenderer — macOS display path for the receiver.
//
// AVSampleBufferDisplayLayer may be promoted to a dedicated video overlay on
// macOS. Moving another layer (the low-latency cursor) above that overlay can
// make WindowServer switch composition paths and briefly expose black on some
// Intel Macs. Decode explicitly to NV12 and render through CAMetalLayer so the
// video and cursor remain in one ordinary Core Animation composition tree.
//
// Frames use a latest-wins slot. The receiver never queues more latency when
// the GPU or the 60 Hz panel cannot consume every decoded frame.

import Foundation
import Metal
import QuartzCore
import CoreVideo
import CoreGraphics
import CoreImage

final class MetalVideoRenderer {
    let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let ciContext: CIContext
    private var textureCache: CVMetalTextureCache?

    private let renderQueue = DispatchQueue(label: "receiver.metal.render",
                                             qos: .userInteractive)
    private let lock = NSLock()
    private var pendingFrame: CVPixelBuffer?
    private var drainScheduled = false
    private var loggedPixelFormat: OSType?
    private var loggedSourceColorDescription = ""
    // Protocol v3 makes the negotiated working space authoritative. Decoder
    // attachments remain diagnostic because some VideoToolbox versions drop
    // or rewrite P3_D65 when producing packed RGB output.
    private var negotiatedSourceColorSpace: WireColorSpace?
    // The receiving screen's exact active ICC profile. Core Image performs
    // source→destination conversion explicitly on the GPU; the CAMetalLayer
    // is then tagged with that same destination profile, making the final
    // WindowServer transform an identity operation instead of relying on an
    // implicit P3→display conversion that differs across macOS/GPU versions.
    private var destinationColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var destinationColorDescription = "sRGB"
    // Protocol 5 sender virtual displays are already composited in the exact
    // receiver ICC device space. In that mode the decoded 10-bit RGB values
    // must not be interpreted as Display P3 and transformed a second time.
    private var deviceICCPassthrough = false
    private var deviceCopyActive = false
    private var latestColorDiagnostic = "waiting-for-frame"

    var colorDiagnostic: String {
        lock.lock()
        defer { lock.unlock() }
        return latestColorDiagnostic
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        commandQueue = queue
        ciContext = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
        ])

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut vmain(uint vid [[vertex_id]]) {
            float2 p[4] = { float2(-1,-1), float2(1,-1),
                            float2(-1, 1), float2(1, 1) };
            VOut o;
            o.pos = float4(p[vid], 0, 1);
            o.uv = float2((p[vid].x + 1.0) * 0.5,
                          (1.0 - p[vid].y) * 0.5);
            return o;
        }
        fragment float4 fmain(VOut in [[stage_in]],
                              texture2d<float> image [[texture(0)]]) {
            constexpr sampler s(filter::linear);
            return image.sample(s, in.uv);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            Log.info("Metal shader compile failed: \(error)")
            return nil
        }
        guard let vertex = library.makeFunction(name: "vmain"),
              let fragment = library.makeFunction(name: "fmain") else {
            Log.info("Metal shader functions missing")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgr10a2Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Log.info("Metal pipeline creation failed: \(error)")
            return nil
        }

        metalLayer.device = device
        // Match the receiver's 10-bit decoder output so Main10 survives all
        // the way to Core Animation/ColorSync instead of being truncated to
        // BGRA8 before the active iMac ICC transform.
        metalLayer.pixelFormat = .bgr10a2Unorm
        // Core Image performs the explicit source→display ICC transform with
        // a Metal compute kernel. A framebuffer-only drawable rejects that
        // shader write and Core Image displays its magenta error surface.
        // Allow general GPU access while keeping the drawable private to this
        // renderer; this is required for the explicit-ICC path.
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // Start conservatively in sRGB. Each decoded frame's HEVC VUI updates
        // this to Display P3 when the sender negotiated a wide-gamut stream;
        // Core Animation then performs one source→active-display ICC transform.
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.maximumDrawableCount = 3
        metalLayer.displaySyncEnabled = true
        metalLayer.presentsWithTransaction = false
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Called on the receiver queue. Replaces any older frame that has not
    /// reached the GPU yet and returns immediately.
    func render(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        pendingFrame = pixelBuffer
        let shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        lock.unlock()

        if shouldSchedule {
            renderQueue.async { [weak self] in self?.drainLatestFrames() }
        }
    }

    func setNegotiatedSourceColorSpace(_ colorSpace: WireColorSpace?) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            negotiatedSourceColorSpace = colorSpace
            loggedSourceColorDescription = ""
            Log.info("Metal negotiated source color: \(colorSpace?.rawValue ?? "attachment-fallback")")
        }
    }

    func setDestinationColorSpace(_ colorSpace: CGColorSpace,
                                  description: String) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            destinationColorSpace = colorSpace
            destinationColorDescription = description
            metalLayer.colorspace = colorSpace
            loggedSourceColorDescription = ""
            Log.info("Metal explicit ICC target: \(description)")
        }
    }

    func setDeviceICCPassthrough(_ enabled: Bool) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            deviceICCPassthrough = enabled
            loggedSourceColorDescription = ""
            Log.info("Metal receiver-device ICC passthrough: \(enabled)")
        }
    }

    private func drainLatestFrames() {
        while true {
            lock.lock()
            guard let frame = pendingFrame else {
                drainScheduled = false
                lock.unlock()
                return
            }
            pendingFrame = nil
            lock.unlock()
            draw(frame)
        }
    }

    private func draw(_ pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        // Native mode is a one-to-one 4480x2520 texture. No reconstruction,
        // sharpening or intermediate GPU surface is allowed in the accurate
        // path; Core Animation only places this source-sized drawable in the
        // view and color-matches it to the active display profile.
        let size = CGSize(width: width, height: height)
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if loggedPixelFormat != pixelFormat {
            loggedPixelFormat = pixelFormat
            Log.info("Metal pixel format: \(fourCC(pixelFormat)) \(width)x\(height)")
        }
        switch pixelFormat {
        case kCVPixelFormatType_ARGB2101010LEPacked:
            // l10r bit layout is A:31...30, R:29...20, G:19...10,
            // B:9...0 — exactly MTLPixelFormat.bgr10a2Unorm.
            break
        case kCVPixelFormatType_32BGRA:
            break // 8-bit compatibility input; output remains 10-bit.
        default:
            return
        }

        let sourceColorSpace = updateSourceColorSpace(from: pixelBuffer)

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let targetColorSpace = destinationColorSpace
        let copiedDevicePixels = deviceICCPassthrough
            && pixelFormat == kCVPixelFormatType_ARGB2101010LEPacked
            && encodeBitExactCopy(from: pixelBuffer, to: drawable.texture,
                                  commandBuffer: commandBuffer)
        if copiedDevicePixels != deviceCopyActive {
            deviceCopyActive = copiedDevicePixels
            loggedSourceColorDescription = ""
            Log.info("Metal bit-exact 10-bit device copy: \(copiedDevicePixels)")
        }
        if !copiedDevicePixels {
            // Canonical-space compatibility path for protocol <= 4 peers.
            let image = CIImage(cvPixelBuffer: pixelBuffer, options: [
                .colorSpace: sourceColorSpace,
            ])
            ciContext.render(image, to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: image.extent,
                             colorSpace: targetColorSpace)
        }
        metalLayer.colorspace = targetColorSpace

        // The decoder owns a pool of IOSurface-backed pixel buffers. Retain the
        // source buffer itself (not only its CVMetalTexture wrappers) until the
        // GPU has finished reading it; otherwise VideoToolbox may recycle the
        // surface early and a flat color reveals mixed old/new macroblocks.
        let retainedPixelBuffer = pixelBuffer
        commandBuffer.addCompletedHandler { _ in
            _ = retainedPixelBuffer
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// `l10r` and `.bgr10a2Unorm` have the same packed bit layout. A Metal
    /// blit therefore preserves every decoded 10-bit channel code exactly —
    /// no shader interpolation, Core Image dither, or second ICC transform.
    private func encodeBitExactCopy(from pixelBuffer: CVPixelBuffer,
                                    to destination: MTLTexture,
                                    commandBuffer: MTLCommandBuffer) -> Bool {
        guard let textureCache else { return false }
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgr10a2Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess,
              let cvTexture,
              let source = CVMetalTextureGetTexture(cvTexture),
              source.width == destination.width,
              source.height == destination.height,
              let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: destination, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.addCompletedHandler { _ in _ = cvTexture }
        return true
    }

    private func encodeCopy(from source: MTLTexture, to destination: MTLTexture,
                            commandBuffer: MTLCommandBuffer) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    /// VideoToolbox propagates the bitstream's source color description onto
    /// decoded buffers. Use its primaries to select the matching standard
    /// working space, then let Core Animation map that source to the active
    /// screen ICC exactly once.
    private func updateSourceColorSpace(from pixelBuffer: CVPixelBuffer) -> CGColorSpace {
        let attachedSpace: CGColorSpace? = {
            guard let value = CVBufferCopyAttachment(
                    pixelBuffer, kCVImageBufferCGColorSpaceKey, nil),
                  CFGetTypeID(value) == CGColorSpace.typeID else { return nil }
            return (value as! CGColorSpace)
        }()
        let primaries = CVBufferCopyAttachment(
            pixelBuffer, kCVImageBufferColorPrimariesKey, nil) as? String
        let transfer = CVBufferCopyAttachment(
            pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let matrix = CVBufferCopyAttachment(
            pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String

        // Some VideoToolbox versions synthesize a generic CGColorSpace whose
        // transfer curve does not match the stream's explicit sRGB transfer.
        // Trust the VUI primaries, but construct Apple's canonical P3/sRGB
        // spaces so the transfer function remains deterministic.
        let p3Primaries = kCVImageBufferColorPrimaries_P3_D65 as String
        let attachmentColor: WireColorSpace = primaries == p3Primaries
            ? .displayP3 : .sRGB
        let selectedColor = negotiatedSourceColorSpace ?? attachmentColor
        let sourceSpace = CGColorSpace(name: selectedColor == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.sRGB)!

        let attachedName = attachedSpace?.name as String? ?? "none"
        let sourceName = sourceSpace.name as String? ?? "unnamed"
        let description = "\(sourceName)|neg=\(negotiatedSourceColorSpace?.rawValue ?? "none")|"
            + "\(primaries ?? "none")|"
            + "\(transfer ?? "none")|\(matrix ?? "none")|\(attachedName)"
        if description != loggedSourceColorDescription {
            loggedSourceColorDescription = description
            lock.lock()
            latestColorDiagnostic = description + "|gpuDst="
                + destinationColorDescription + "|explicitICC=true"
                + "|devicePassthrough=\(deviceICCPassthrough)"
                + "|deviceCopy=\(deviceCopyActive)"
            lock.unlock()
            Log.info("Metal source color: \(sourceName) primaries=\(primaries ?? "none") "
                + "transfer=\(transfer ?? "none") matrix=\(matrix ?? "none") "
                + "decoderSpace=\(attachedName) negotiated="
                + "\(negotiatedSourceColorSpace?.rawValue ?? "none") "
                + "explicitTarget=\(destinationColorDescription)")
        }
        return sourceSpace
    }

    private func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}
