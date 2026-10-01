import Foundation

/// What the receiver reports about its panel (PROTOCOL.md 6.7), in its
/// current orientation. Facts only: the sender decides the desktop.
struct PanelFacts: Equatable {
    /// Physical pixels the receiver lights up 1:1: the hard bound for any stream.
    let pixelsWide: Int
    let pixelsHigh: Int
    /// The device's real backing scale (1, 2, 3, or fractional).
    let scale: Double
    /// The receiving Mac's own "looks like" desktop size; nil where the
    /// receiver has no such setting.
    let pointsWide: Int?
    let pointsHigh: Int?

    var pixels: PixelSize { PixelSize(width: pixelsWide, height: pixelsHigh) }
}

/// The user's per-device desktop size choice, relative to the receiver's
/// default desktop. Presets only: every choice shows the exact size it gives.
enum DisplaySize: String, CaseIterable {
    case largerText, `default`, moreSpace, native
}

struct DesktopPlan: Equatable {
    /// The virtual display before the stream shrink (`DesktopPolicy.canvas`).
    let desktop: VirtualCanvasSize
    /// A size the user asked for (a preset, or a scaled mode on the receiving
    /// Mac): never shrunk to the stream, the stream is scaled once instead.
    let explicit: Bool
    /// The receiver's physical pixels: no stream is larger.
    let presentable: PixelSize

    var desktopPixels: PixelSize {
        PixelSize(width: desktop.pixelsWide, height: desktop.pixelsHigh)
    }

    /// The raster quality presets scale from (`makeForCanvas`'s `panel`):
    /// the desktop as the receiver can present it, before any stream shrink.
    var streamReference: PixelSize {
        VideoStreamConfiguration.fit(desktopPixels, inside: presentable)
    }
}

/// The one place that decides the extended desktop's size (PLAN-display-sizing
/// section 4.3). Every rule is axis-symmetric, so portrait is swapped inputs.
enum DesktopPolicy {
    /// Largest pixel size per axis that a desktop may take, so a size change
    /// always fits the display's descriptor and stays an in-place resize.
    static let maxPixelsPerAxis = 8_192
    /// The smallest short axis, in points, that macOS accepts for a 2x mode
    /// on a virtual display (measured on macOS 26, both orientations, #292).
    static let minimumTwoXPoints = 526

    /// The desktop to run after macOS refused a 2x mode: the panel's own
    /// pixels at 1x (the Native desktop), so capture, stream and the mode
    /// macOS actually runs agree.
    static func oneXFallback(facts: PanelFacts) -> DesktopPlan {
        plan(facts: facts, choice: .native)
    }

    static func plan(facts: PanelFacts, choice: DisplaySize = .default) -> DesktopPlan {
        // A: macOS virtual displays only do 1x and 2x.
        let vdScale = facts.scale >= 1.5 ? 2 : 1

        // B: the default desktop. A receiving Mac's own setting wins (#271);
        // otherwise a Retina-like panel gets half its pixels at 2x, and a 1x
        // panel its own pixels.
        let base: (w: Int, h: Int)
        if let w = facts.pointsWide, let h = facts.pointsHigh {
            base = (even(w), even(h))
        } else if vdScale == 2 {
            base = (even(facts.pixelsWide / 2), even(facts.pixelsHigh / 2))
        } else {
            base = (even(facts.pixelsWide), even(facts.pixelsHigh))
        }

        // C: the user's choice.
        var points: (w: Int, h: Int)
        var scale = vdScale
        switch choice {
        case .default:
            points = base
        case .largerText:
            points = (scaled(base.w, 0.8), scaled(base.h, 0.8))
        case .moreSpace:
            points = (scaled(base.w, 1.25), scaled(base.h, 1.25))
        case .native:
            points = (even(facts.pixelsWide), even(facts.pixelsHigh))
            scale = 1
        }

        // D1: macOS refuses 2x modes under 526 points on the short axis
        // (#292); raise the short axis to 526, keeping the aspect. The
        // stream is still bounded by the panel (step E), so a small phone
        // gets a once-downscaled 2x desktop instead of a 1x one.
        if scale == 2, min(points.w, points.h) < minimumTwoXPoints {
            let short = min(points.w, points.h), long = max(points.w, points.h)
            let raised = even(Int((Double(long) * Double(minimumTwoXPoints) / Double(short)).rounded()))
            points = points.w < points.h ? (minimumTwoXPoints, raised) : (raised, minimumTwoXPoints)
        }

        // D2: fit the descriptor.
        let longest = max(points.w, points.h) * scale
        if longest > maxPixelsPerAxis {
            let f = Double(maxPixelsPerAxis) / Double(longest)
            points = (even(Int((Double(points.w) * f).rounded(.down))),
                      even(Int((Double(points.h) * f).rounded(.down))))
        }

        let desktop = VirtualCanvasSize(pointsWide: points.w, pointsHigh: points.h, scale: scale)
        let explicit = choice != .default
            || desktop.pixelsWide > facts.pixelsWide
            || desktop.pixelsHigh > facts.pixelsHigh
        return DesktopPlan(desktop: desktop, explicit: explicit, presentable: facts.pixels)
    }

    /// D3: a default desktop larger than the best stream is shrunk to that
    /// stream at the same scale, so capture is 1:1 and the picture is scaled
    /// once, on the receiver (#322). Explicit sizes are kept.
    static func canvas(for plan: DesktopPlan,
                       codec: String = VideoStreamConfiguration.h264Codec,
                       legacyCeiling: PixelSize? = nil,
                       videoCaps: [VideoCapability]? = nil,
                       displayMaxFrameRate: Int? = nil) -> VirtualCanvasSize {
        guard !plan.explicit else { return plan.desktop }
        let desktop = plan.desktopPixels
        let best = VideoStreamConfiguration.canvasPixels(
            forReceiver: desktop, codec: codec, legacyCeiling: legacyCeiling,
            presentable: plan.presentable, receiverCapabilities: videoCaps,
            displayMaxFrameRate: displayMaxFrameRate)
        guard best.width < desktop.width || best.height < desktop.height else { return plan.desktop }
        let scale = plan.desktop.scale
        return VirtualCanvasSize(pointsWide: even(best.width / scale),
                                 pointsHigh: even(best.height / scale),
                                 scale: scale)
    }

    private static func even(_ value: Int) -> Int { max(2, value & ~1) }
    private static func scaled(_ value: Int, _ factor: Double) -> Int {
        even(Int((Double(value) * factor).rounded()))
    }
}
