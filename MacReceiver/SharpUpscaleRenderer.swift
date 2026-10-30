// SharpUpscaleRenderer — opt-in display path for streams smaller than the panel.
//
// The system video layer stretches Balanced/Fast streams with a plain bilinear
// filter, which softens text. Here the receiver decodes explicitly (NV12), and
// a fragment shader resamples luma with Catmull-Rom (9 bilinear taps) at the
// view's native pixel size, then applies a mild unsharp mask. Chroma stays
// bilinear. Enabled with: defaults write <receiver bundle id> sharpUpscale -bool YES
// (`sharpenAmount`, a float, tunes the mask; 0 = resample only).
//
// Frames land in a single latest-wins slot drained on a dedicated queue, as in
// iOS/MetalVideoRenderer.

import AppKit
import Metal
import QuartzCore
import CoreVideo

final class SharpUpscaleRenderer {
    let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let pipelineOneToOne: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    private let renderQueue = DispatchQueue(label: "sharp.upscale.render", qos: .userInteractive)
    private let lock = NSLock()
    private var pendingFrame: (buffer: CVPixelBuffer, captureMs: Double?)?

    var onPresented: ((_ presentedTime: CFTimeInterval, _ captureMs: Double?) -> Void)?

    private struct Uniforms {
        var rect: SIMD4<Float>      // aspect-fit rect in NDC: minX, minY, maxX, maxY
        var srcSize: SIMD2<Float>
        var sharpen: Float
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct U { float4 rect; float2 srcSize; float sharpen; };
        struct VOut { float4 pos [[position]]; float2 uv; };
        // BT.709 video range to RGB; luma already clamped to the legal range.
        float4 toRGB(float y, float2 cbcr) {
            float yn = 1.1644 * (y - 0.0627);
            float cb = cbcr.x - 0.5;
            float cr = cbcr.y - 0.5;
            return float4(yn + 1.7927 * cr,
                          yn - 0.2133 * cb - 0.5329 * cr,
                          yn + 2.1124 * cb,
                          1.0);
        }
        // Stream and drawable have the same size: each pixel is exactly one texel.
        fragment float4 fmain11(VOut in [[stage_in]],
                                texture2d<float> texY [[texture(0)]],
                                texture2d<float> texCbCr [[texture(1)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float y = clamp(texY.read(uint2(in.pos.xy)).r, 0.0627, 0.9216);
            return toRGB(y, texCbCr.sample(s, in.uv).rg);
        }
        vertex VOut vmain(uint vid [[vertex_id]], constant U &u [[buffer(0)]]) {
            float2 c[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
            float2 q = c[vid];
            VOut o;
            o.pos = float4(mix(u.rect.x, u.rect.z, q.x), mix(u.rect.y, u.rect.w, q.y), 0, 1);
            o.uv = float2(q.x, 1.0 - q.y);
            return o;
        }
        fragment float4 fmain(VOut in [[stage_in]],
                              constant U &u [[buffer(0)]],
                              texture2d<float> texY [[texture(0)]],
                              texture2d<float> texCbCr [[texture(1)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float2 pos = in.uv * u.srcSize;
            float2 c = floor(pos - 0.5) + 0.5;
            float2 f = pos - c;
            // Catmull-Rom weights; the two middle taps merge into one bilinear fetch.
            float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
            float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
            float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
            float2 w3 = f * f * (-0.5 + 0.5 * f);
            float2 w12 = w1 + w2;
            float2 t0 = (c - 1.0) / u.srcSize;
            float2 t12 = (c + w2 / w12) / u.srcSize;
            float2 t3 = (c + 2.0) / u.srcSize;
            float y = 0;
            y += texY.sample(s, float2(t0.x, t0.y)).r * w0.x * w0.y;
            y += texY.sample(s, float2(t12.x, t0.y)).r * w12.x * w0.y;
            y += texY.sample(s, float2(t3.x, t0.y)).r * w3.x * w0.y;
            y += texY.sample(s, float2(t0.x, t12.y)).r * w0.x * w12.y;
            y += texY.sample(s, float2(t12.x, t12.y)).r * w12.x * w12.y;
            y += texY.sample(s, float2(t3.x, t12.y)).r * w3.x * w12.y;
            y += texY.sample(s, float2(t0.x, t3.y)).r * w0.x * w3.y;
            y += texY.sample(s, float2(t12.x, t3.y)).r * w12.x * w3.y;
            y += texY.sample(s, float2(t3.x, t3.y)).r * w3.x * w3.y;
            if (u.sharpen > 0.0) {
                float2 px = 0.5 / u.srcSize;
                float blur = 0.25 * (texY.sample(s, in.uv + float2(px.x, 0)).r
                                   + texY.sample(s, in.uv - float2(px.x, 0)).r
                                   + texY.sample(s, in.uv + float2(0, px.y)).r
                                   + texY.sample(s, in.uv - float2(0, px.y)).r);
                y += u.sharpen * (y - blur);
            }
            y = clamp(y, 0.0627, 0.9216);
            return toRGB(y, texCbCr.sample(s, in.uv).rg);
        }
        """
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: source, options: nil) }
        catch { Log.info("sharp upscale shader compile failed: \(error)"); return nil }
        guard let vfn = lib.makeFunction(name: "vmain"),
              let ffn = lib.makeFunction(name: "fmain"),
              let ffn11 = lib.makeFunction(name: "fmain11") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            desc.fragmentFunction = ffn11
            pipelineOneToOne = try device.makeRenderPipelineState(descriptor: desc)
        } catch { Log.info("sharp upscale pipeline failed: \(error)"); return nil }

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Called on the receiver's queue — returns immediately.
    func render(_ pixelBuffer: CVPixelBuffer, captureMs: Double?) {
        lock.lock()
        let hadPending = pendingFrame != nil
        pendingFrame = (pixelBuffer, captureMs)
        lock.unlock()
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
        guard let cache = textureCache else { return }
        var cvY: CVMetalTexture?
        var cvCbCr: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .r8Unorm, w, h, 0, &cvY)
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .rg8Unorm, w / 2, h / 2, 1, &cvCbCr)
        guard let cvY, let cvCbCr,
              let texY = CVMetalTextureGetTexture(cvY),
              let texCbCr = CVMetalTextureGetTexture(cvCbCr),
              let drawable = metalLayer.nextDrawable(),
              let cmd = commandQueue.makeCommandBuffer() else { return }

        // Aspect-fit the video inside the drawable, in NDC.
        let dw = Float(drawable.texture.width), dh = Float(drawable.texture.height)
        let scale = min(dw / Float(w), dh / Float(h))
        let fx = Float(w) * scale / dw, fy = Float(h) * scale / dh
        var uniforms = Uniforms(rect: SIMD4(-fx, -fy, fx, fy),
                                srcSize: SIMD2(Float(w), Float(h)),
                                // 1:1 (raw 5K on a 5K panel) is already exact: no mask.
                                sharpen: Float(w) == dw && Float(h) == dh ? 0 : Self.sharpenAmount)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let oneToOne = Float(w) == dw && Float(h) == dh && Self.fastPathEnabled
        encoder.setRenderPipelineState(oneToOne ? pipelineOneToOne : pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texY, index: 0)
        encoder.setFragmentTexture(texCbCr, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        drawable.addPresentedHandler { [weak self] d in
            self?.onPresented?(d.presentedTime, captureMs)
        }
        cmd.addCompletedHandler { [weak self] buffer in
            _ = cvY; _ = cvCbCr
            self?.noteGPUTime(buffer.gpuEndTime - buffer.gpuStartTime, oneToOne: oneToOne)
        }
        cmd.present(drawable)
        cmd.commit()
    }

    /// `defaults write <bundle id> upscaleFastPath -bool NO` turns the 1:1 fast path off, for A/B.
    private static var fastPathEnabled: Bool {
        UserDefaults.standard.object(forKey: "upscaleFastPath") == nil
            || UserDefaults.standard.bool(forKey: "upscaleFastPath")
    }

    private var gpuTimeTotal = 0.0
    private var gpuFrames = 0
    private var gpuWindowStart = CACurrentMediaTime()
    private let gpuStatsLock = NSLock()

    private func noteGPUTime(_ seconds: Double, oneToOne: Bool) {
        gpuStatsLock.lock()
        defer { gpuStatsLock.unlock() }
        gpuTimeTotal += seconds
        gpuFrames += 1
        let now = CACurrentMediaTime()
        guard now - gpuWindowStart >= 5 else { return }
        Log.info(String(format: "upscale GPU: %.2f ms/frame over %d frames (%@)",
                        gpuTimeTotal / Double(gpuFrames) * 1000, gpuFrames,
                        oneToOne ? "1:1 fast path" : "resample"))
        gpuTimeTotal = 0
        gpuFrames = 0
        gpuWindowStart = now
    }

    private static var sharpenAmount: Float {
        UserDefaults.standard.object(forKey: "sharpenAmount") == nil
            ? 0.35 : UserDefaults.standard.float(forKey: "sharpenAmount")
    }
}
