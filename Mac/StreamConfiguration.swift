import Foundation

/// Capture-resolution / bitrate trade-off. The virtual display runs at the
/// receiver's size, capped at the Best stream (`canvasPixels`); presets only
/// scale the captured/encoded stream, so lower presets cut encode, transmit,
/// and decode work at the cost of sharpness.
enum StreamQuality: String, CaseIterable {
    case best, balanced, fast

    var scale: Double {
        switch self {
        case .best: return 1.0
        case .balanced: return 0.75
        case .fast: return 0.5
        }
    }

    var bitrate: Int {
        switch self {
        case .best: return 18_000_000
        case .balanced: return 10_000_000
        case .fast: return 6_000_000
        }
    }

    var label: String {
        switch self {
        case .best: return "Best"
        case .balanced: return "Balanced"
        case .fast: return "Fast"
        }
    }

    var explanation: String {
        switch self {
        case .best: return "Highest safe detail for this sender and display."
        case .balanced: return "Lower capture resolution for less latency and bandwidth."
        case .fast: return "Lowest latency and bandwidth, with a softer image. Good for WiFi."
        }
    }
}

struct PixelSize: Equatable {
    let width: Int
    let height: Int
}

/// One fully validated operating point for the selected codec.
/// Every capture/recovery path builds this through `make`, so dimensions and
/// frame rate cannot drift apart after a rotation or ScreenCaptureKit restart.
struct VideoStreamConfiguration: Equatable {
    static let h264Codec = "h264"
    static let hevcCodec = "hevc"
    static let defaultFramesPerSecond = 60
    // H.264 High@L5.2 MaxFS and MaxMBPS. Keeping these as codec constraints,
    // rather than a model/display special case, is what makes 5K and future
    // receiver sizes follow the same selection path.
    static let maxMacroblocksPerFrame = 36_864
    // H.264 High@L5.2 MaxMBPS. VideoToolbox silently rejects output when a
    // requested raster × rate crosses this boundary (issue #271).
    static let maxMacroblocksPerSecond = 2_073_600

    let codec: String
    let encodedSize: PixelSize
    let bitrate: Int
    let framesPerSecond: Int

    enum SelectionError: LocalizedError, Equatable {
        case invalidSource
        case noCompatibleCodec
        case noCompatibleConfiguration

        var errorDescription: String? {
            switch self {
            case .invalidSource:
                return "The display reported an invalid video size."
            case .noCompatibleCodec:
                return "The receiver does not support the selected video codec."
            case .noCompatibleConfiguration:
                return "The receiver did not advertise a usable video configuration."
            }
        }
    }

    /// Codec policy, no user switch: HEVC whenever the receiver offers it and
    /// this Mac has a hardware HEVC encoder, else H.264. At the same raster the
    /// two encode equally fast on Apple silicon, and HEVC is sharper after every
    /// change and on slow links; above H.264's level limit it is the only way
    /// to send a 5K panel 1:1 (research/hevc-m5-2026-09-29).
    static func preferredCodec(receiverCapabilities: [VideoCapability]?,
                               senderEncodesHEVC: Bool) -> String {
        guard senderEncodesHEVC,
              receiverCapabilities?.contains(where: { $0.codec.lowercased() == hevcCodec }) == true
        else { return h264Codec }
        return hevcCodec
    }

    /// `presentable` is the receiver's physical panel (PROTOCOL.md 6.7): the
    /// source is fitted inside it before the quality preset scales it, so no
    /// stream is larger than the receiver can show 1:1.
    static func make(source: PixelSize,
                     quality: StreamQuality,
                     codec: String = h264Codec,
                     legacyCeiling: PixelSize? = nil,
                     receiverCapabilities: [VideoCapability]? = nil,
                     displayMaxFrameRate: Int? = nil,
                     presentable: PixelSize? = nil,
                     requestedFramesPerSecond: Int = defaultFramesPerSecond) throws -> Self {
        guard source.width > 0, source.height > 0 else { throw SelectionError.invalidSource }

        let shown = fit(source, inside: presentable)
        let scaled = PixelSize(
            width: even(Int(Double(shown.width) * quality.scale)),
            height: even(Int(Double(shown.height) * quality.scale)))
        let targetFPS = max(1, min(requestedFramesPerSecond,
                                   displayMaxFrameRate.flatMap { $0 > 0 ? $0 : nil }
                                       ?? requestedFramesPerSecond))

        // Absence is the legacy H.264 contract. Never infer HEVC support from
        // an older receiver that did not advertise codec capabilities.
        let matchingCapabilities: [VideoCapability?]
        if let receiverCapabilities {
            let matches = receiverCapabilities.filter { $0.codec.lowercased() == codec }
            guard !matches.isEmpty else { throw SelectionError.noCompatibleCodec }
            matchingCapabilities = matches.map(Optional.some)
        } else {
            guard codec == h264Codec else { throw SelectionError.noCompatibleCodec }
            matchingCapabilities = [nil]
        }

        let candidates = matchingCapabilities.compactMap { capability -> Self? in
            if codec == h264Codec, let ceiling = legacyCeiling,
               ceiling.width < 2 || ceiling.height < 2 {
                return nil
            }
            if let capability,
               capability.maxWidth.map({ $0 < 2 }) == true
                || capability.maxHeight.map({ $0 < 2 }) == true
                || capability.maxFrameRate.map({ $0 < 1 }) == true
                || capability.maxPixelsPerSecond.map({ $0 < 4 }) == true {
                return nil
            }
            var size = fit(scaled, inside: codec == h264Codec ? legacyCeiling : nil)
            if let capability {
                size = fit(size, maxWidth: capability.maxWidth,
                           maxHeight: capability.maxHeight)
            }
            if codec == h264Codec { size = fitH264LevelFrame(size) }

            // Prefer detail and lower the rate first. If even one frame would
            // exceed the advertised throughput, reduce the raster as well.
            if let pixelsPerSecond = capability?.maxPixelsPerSecond,
               pixelsPerSecond > 0 {
                guard let fitted = fit(size, maxPixels: pixelsPerSecond) else {
                    return nil
                }
                size = fitted
            }

            var fps = targetFPS
            if let maximum = capability?.maxFrameRate, maximum > 0 {
                fps = min(fps, maximum)
            }
            if let pixelsPerSecond = capability?.maxPixelsPerSecond,
               pixelsPerSecond > 0 {
                let pixels = size.width * size.height
                fps = min(fps, pixelsPerSecond / pixels)
            }
            guard fps > 0 else { return nil }
            if codec == h264Codec {
                fps = safeH264FrameRate(width: size.width, height: size.height,
                                        requested: fps)
            }
            return Self(codec: codec, encodedSize: size, bitrate: quality.bitrate,
                        framesPerSecond: fps)
        }

        // Prefer the most detailed valid receiver constraint set, then the
        // higher rate when two alternatives produce the same raster.
        guard let selected = candidates.max(by: {
            let lhsPixels = $0.encodedSize.width * $0.encodedSize.height
            let rhsPixels = $1.encodedSize.width * $1.encodedSize.height
            return lhsPixels == rhsPixels
                ? $0.framesPerSecond < $1.framesPerSecond
                : lhsPixels < rhsPixels
        }) else {
            throw SelectionError.noCompatibleConfiguration
        }
        return selected
    }

    /// The desktop canvas to create for a receiver: its panel, capped at the
    /// best stream we can send it. When the stream must be smaller than the
    /// panel (a 5K receiver over H.264), a panel-sized canvas would be
    /// downscaled before encoding and upscaled again on the receiver, which
    /// visibly softens text. A canvas at the stream size is captured 1:1 and
    /// scaled once (#322). The cap always uses Best; `makeForCanvas` keeps the
    /// lower presets' raster relative to the panel.
    static func canvasPixels(forReceiver panel: PixelSize,
                             codec: String = h264Codec,
                             legacyCeiling: PixelSize? = nil,
                             presentable: PixelSize? = nil,
                             receiverCapabilities: [VideoCapability]? = nil,
                             displayMaxFrameRate: Int? = nil) -> PixelSize {
        guard let best = try? make(source: panel, quality: .best, codec: codec,
                                   legacyCeiling: legacyCeiling,
                                   receiverCapabilities: receiverCapabilities,
                                   displayMaxFrameRate: displayMaxFrameRate,
                                   presentable: presentable)
        else { return panel }
        return best.encodedSize
    }

    /// Stream for an extended desktop whose canvas may be capped below the
    /// receiver's panel. Quality presets still scale from the panel, as they
    /// did before the cap, and the result never exceeds the canvas: Best stays
    /// 1:1, and Balanced/Fast keep their raster instead of scaling the capped
    /// canvas down a second time.
    static func makeForCanvas(_ canvas: PixelSize,
                              panel: PixelSize,
                              quality: StreamQuality,
                              codec: String = h264Codec,
                              legacyCeiling: PixelSize? = nil,
                              receiverCapabilities: [VideoCapability]? = nil,
                              displayMaxFrameRate: Int? = nil,
                              presentable: PixelSize? = nil) throws -> Self {
        let fromCanvas = try make(source: canvas, quality: quality, codec: codec,
                                  legacyCeiling: legacyCeiling,
                                  receiverCapabilities: receiverCapabilities,
                                  displayMaxFrameRate: displayMaxFrameRate,
                                  presentable: presentable)
        guard panel != canvas,
              let fromPanel = try? make(source: panel, quality: quality, codec: codec,
                                        legacyCeiling: legacyCeiling,
                                        receiverCapabilities: receiverCapabilities,
                                        displayMaxFrameRate: displayMaxFrameRate,
                                        presentable: presentable),
              fromPanel.encodedSize.width <= canvas.width,
              fromPanel.encodedSize.height <= canvas.height,
              fromPanel.encodedSize.width * fromPanel.encodedSize.height
                > fromCanvas.encodedSize.width * fromCanvas.encodedSize.height
        else { return fromCanvas }
        return fromPanel
    }

    private static func safeH264FrameRate(width: Int, height: Int,
                                          requested: Int) -> Int {
        let macroblocksWide = (width + 15) / 16
        let macroblocksHigh = (height + 15) / 16
        let macroblocks = max(1, macroblocksWide * macroblocksHigh)
        let levelRate = max(1, maxMacroblocksPerSecond / macroblocks)
        guard levelRate < requested else { return requested }
        // Keep one frame per second of headroom below the nominal level limit.
        return max(1, levelRate - 1)
    }

    private static func fitH264LevelFrame(_ size: PixelSize) -> PixelSize {
        let macroblocks = ((size.width + 15) / 16) * ((size.height + 15) / 16)
        guard macroblocks > maxMacroblocksPerFrame else { return size }
        let scale = sqrt(Double(maxMacroblocksPerFrame) / Double(macroblocks))
        var fitted = PixelSize(width: even(Int(Double(size.width) * scale)),
                               height: even(Int(Double(size.height) * scale)))
        // Macroblocks round each axis up to 16. The area-derived scale can
        // therefore land a few blocks over the limit; trim while preserving
        // the aspect as closely as two-pixel dimensions permit.
        while ((fitted.width + 15) / 16) * ((fitted.height + 15) / 16)
                > maxMacroblocksPerFrame {
            if Double(fitted.width) / Double(size.width)
                >= Double(fitted.height) / Double(size.height) {
                fitted = PixelSize(width: max(2, fitted.width - 2), height: fitted.height)
            } else {
                fitted = PixelSize(width: fitted.width, height: max(2, fitted.height - 2))
            }
        }
        return fitted
    }

    static func fit(_ size: PixelSize, inside ceiling: PixelSize?) -> PixelSize {
        guard let ceiling else { return size }
        return fit(size, maxWidth: ceiling.width, maxHeight: ceiling.height)
    }

    /// Capability axes are independently optional on the wire. Respect the
    /// one that is present instead of silently requiring a complete rectangle.
    private static func fit(_ size: PixelSize, maxWidth: Int?, maxHeight: Int?) -> PixelSize {
        let widthScale = maxWidth.flatMap { $0 > 0 ? Double($0) / Double(size.width) : nil }
        let heightScale = maxHeight.flatMap { $0 > 0 ? Double($0) / Double(size.height) : nil }
        let scale = min(1, min(widthScale ?? 1, heightScale ?? 1))
        guard scale < 1 else { return size }
        return PixelSize(width: even(Int(Double(size.width) * scale)),
                         height: even(Int(Double(size.height) * scale)))
    }

    private static func fit(_ size: PixelSize, maxPixels: Int) -> PixelSize? {
        guard maxPixels >= 4 else { return nil }
        let pixels = size.width * size.height
        guard pixels > maxPixels else { return size }
        let scale = sqrt(Double(maxPixels) / Double(pixels))
        let fitted = PixelSize(width: even(Int(Double(size.width) * scale)),
                               height: even(Int(Double(size.height) * scale)))
        return fitted.width * fitted.height <= maxPixels ? fitted : nil
    }

    private static func even(_ value: Int) -> Int { max(2, value & ~1) }
}

/// Fractional frame admission shared by live capture, reconnect keyframes and
/// replay. Anchoring deadlines avoids turning a 60 Hz source into 30 FPS when
/// the target is 55 FPS.
struct FrameRateLimiter {
    let framesPerSecond: Int
    private var nextDeadline: Double?

    init(framesPerSecond: Int) {
        self.framesPerSecond = max(1, framesPerSecond)
    }

    mutating func shouldSubmit(at time: Double) -> Bool {
        guard time.isFinite else { return true }
        let interval = 1.0 / Double(framesPerSecond)
        if let next = nextDeadline {
            guard time + 0.0005 >= next else { return false }
            let steps = max(1, floor((time + 0.0005 - next) / interval) + 1)
            nextDeadline = next + steps * interval
        } else {
            nextDeadline = time + interval
        }
        return true
    }
}
