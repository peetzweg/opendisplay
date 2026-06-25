// MetalVideoRenderer — experimental low-latency display path.
//
// AVSampleBufferDisplayLayer hides decode and presentation scheduling and is
// suspected of buffering ~1 extra frame (moonlight-qt ships a Metal path for
// the same reason). Here the receiver decodes explicitly with
// VTDecompressionSession and hands us NV12 pixel buffers; we convert YUV→RGB
// in a fragment shader and present immediately. The drawable's presented
// handler reports when the frame actually hit the glass — the only true
// "capture→photon" measurement point available on iOS.
//
// Pacing: render() never blocks the caller. Frames land in a single
// latest-wins slot and a dedicated queue drains it — if the GPU/vsync can't
// keep up we skip straight to the newest frame instead of queueing latency.

import Foundation
import Metal
import QuartzCore
import CoreVideo

final class MetalVideoRenderer {
    let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    private let renderQueue = DispatchQueue(label: "metal.render", qos: .userInteractive)
    private let lock = NSLock()
    private var pendingFrame: (buffer: CVPixelBuffer, captureMs: Double?)?

    /// presentedTime (CACurrentMediaTime base) + the capture timestamp that
    /// was threaded through render(_:captureMs:).
    var onPresented: ((_ presentedTime: CFTimeInterval, _ captureMs: Double?) -> Void)?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue

        // Fullscreen quad sampling NV12 (BT.709 video range) — compiled from
        // source so the project needs no .metal build phase.
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut vmain(uint vid [[vertex_id]]) {
            float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
            VOut o;
            o.pos = float4(p[vid], 0, 1);
            o.uv = float2((p[vid].x + 1.0) * 0.5, (1.0 - p[vid].y) * 0.5);
            return o;
        }
        fragment float4 fmain(VOut in [[stage_in]],
                              texture2d<float> texY [[texture(0)]],
                              texture2d<float> texCbCr [[texture(1)]]) {
            constexpr sampler s(filter::linear);
            float y = texY.sample(s, in.uv).r;
            float2 cbcr = texCbCr.sample(s, in.uv).rg;
            float yn = 1.1644 * (y - 0.0627);
            float cb = cbcr.x - 0.5;
            float cr = cbcr.y - 0.5;
            return float4(yn + 1.7927 * cr,
                          yn - 0.2133 * cb - 0.5329 * cr,
                          yn + 2.1124 * cb,
                          1.0);
        }
        """
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: source, options: nil) }
        catch { Log.info("Metal shader compile failed: \(error)"); return nil }
        guard let vfn = lib.makeFunction(name: "vmain"),
              let ffn = lib.makeFunction(name: "fmain") else {
            Log.info("Metal shader functions missing")
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { Log.info("Metal pipeline failed: \(error)"); return nil }

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        // Best measured config (photon p50 ~58ms): 3 drawables, plain
        // present. 2 drawables measured WORSE (~88ms — background presents
        // slip transactions), and presentsWithTransaction broke presented
        // handlers on a runloop-less queue. The system video layer still
        // beats all of these on iOS (dedicated video compositor plane),
        // which is why this renderer is opt-in.
        metalLayer.maximumDrawableCount = 3
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Called on the receiver's queue — returns immediately.
    func render(_ pixelBuffer: CVPixelBuffer, captureMs: Double?) {
        lock.lock()
        let hadPending = pendingFrame != nil
        pendingFrame = (pixelBuffer, captureMs)
        lock.unlock()
        // A pending frame means a drain is already queued and will pick up
        // the newer buffer we just stored.
        if !hadPending {
            renderQueue.async { [weak self] in self?.drainPending() }
        }
    }

    private func drainPending() {
        lock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        lock.unlock()
        guard let frame else { return }
        draw(frame.buffer, captureMs: frame.captureMs)
    }

    private func draw(_ pixelBuffer: CVPixelBuffer, captureMs: Double?) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        if metalLayer.drawableSize != CGSize(width: w, height: h) {
            metalLayer.drawableSize = CGSize(width: w, height: h)
        }

        guard let cache = textureCache else { return }
        var cvY: CVMetalTexture?
        var cvCbCr: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .r8Unorm, w, h, 0, &cvY)
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .rg8Unorm, w / 2, h / 2, 1, &cvCbCr)
        guard let cvY, let cvCbCr,
              let texY = CVMetalTextureGetTexture(cvY),
              let texCbCr = CVMetalTextureGetTexture(cvCbCr) else { return }

        guard let drawable = metalLayer.nextDrawable(),
              let cmd = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texY, index: 0)
        encoder.setFragmentTexture(texCbCr, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // CAMetalDrawable's presented handler is device-only; the Simulator
        // SDK omits it. The handler only feeds the experimental Metal path's
        // glass-time telemetry, so skipping it in the Simulator is harmless.
        #if !targetEnvironment(simulator)
        drawable.addPresentedHandler { [weak self] d in
            self?.onPresented?(d.presentedTime, captureMs)
        }
        #endif
        // Keep the source textures alive until the GPU is done with them.
        cmd.addCompletedHandler { _ in _ = cvY; _ = cvCbCr }
        cmd.present(drawable)
        cmd.commit()
    }
}
