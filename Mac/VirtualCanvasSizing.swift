import Foundation

struct VirtualCanvasSize: Hashable {
    let pointsWide: Int
    let pointsHigh: Int
    /// Backing scale of the virtual display: 2 (HiDPI) for Retina receivers,
    /// 1 for a non-Retina receiver panel, which is then streamed 1:1.
    var scale: Int = 2

    var pixelsWide: Int { pointsWide * scale }
    var pixelsHigh: Int { pointsHigh * scale }
    var cgSize: CGSize { CGSize(width: pointsWide, height: pointsHigh) }
}

struct VirtualCanvasPlan: Equatable {
    let requested: VirtualCanvasSize
    let bootstrap: VirtualCanvasSize
    let descriptorMaxPixelsPerAxis: Int
}

/// WindowServer can refuse a large CGVirtualDisplay when that mode is present
/// at creation, while accepting the same mode when it is applied to an online
/// display. This is a local macOS startup workaround, not a protocol limit:
/// start within a conservative 3200x1800 pixel envelope and promote the same
/// identity after ScreenCaptureKit sees it.
enum VirtualCanvasSizing {
    private static let bootstrapLongEdgePixels = 3_200
    private static let bootstrapShortEdgePixels = 1_800
    private static let reservedPixelsPerAxis = 8_192

    static func plan(pixelsWide: Int, pixelsHigh: Int, scale: Int = 2) -> VirtualCanvasPlan? {
        guard let requested = requested(pixelsWide: pixelsWide,
                                        pixelsHigh: pixelsHigh,
                                        scale: scale) else { return nil }
        return VirtualCanvasPlan(
            requested: requested,
            bootstrap: bootstrap(for: requested),
            descriptorMaxPixelsPerAxis: max(reservedPixelsPerAxis,
                                             requested.pixelsWide,
                                             requested.pixelsHigh))
    }

    /// Physical size declared for the virtual display. Only two things
    /// depend on it, measured on macOS 26.1 and 27.0.1:
    /// - macOS 26.1 never brings a virtual display online when the declared
    ///   area is under roughly 160 cm² and the descriptor reserves more than
    ///   about 2,000 pixels per axis, which `reservedPixelsPerAxis` always does.
    /// - macOS 27 ignores a declared width under about 166 mm (it assumes
    ///   72 dpi) and starts the display at 1x below about 147 pixels per inch
    ///   of declared width. The sender forces 2x right after, but that switch
    ///   adds up to a second to the connect.
    /// The height is not used: macOS derives it from the mode's aspect. So
    /// landscape keeps 208 mm, and portrait gets 175 mm, which still reads
    /// as Retina (about 153 ppi) for the narrowest 2x desktop, 526 points.
    static func physicalSizeInMillimeters(for canvas: VirtualCanvasSize) -> CGSize {
        canvas.pointsWide >= canvas.pointsHigh
            ? CGSize(width: 208, height: 96)
            : CGSize(width: 175, height: 380)
    }

    static func requested(pixelsWide: Int, pixelsHigh: Int, scale: Int = 2) -> VirtualCanvasSize? {
        let scale = scale < 2 ? 1 : 2
        guard pixelsWide >= 2 * scale, pixelsHigh >= 2 * scale else { return nil }
        let width = (pixelsWide / scale) & ~1
        let height = (pixelsHigh / scale) & ~1
        guard width >= 2, height >= 2 else { return nil }
        return VirtualCanvasSize(pointsWide: width, pointsHigh: height, scale: scale)
    }

    static func bootstrap(for requested: VirtualCanvasSize) -> VirtualCanvasSize {
        let landscape = requested.pointsWide >= requested.pointsHigh
        let maximumWidth = (landscape ? bootstrapLongEdgePixels : bootstrapShortEdgePixels) / requested.scale
        let maximumHeight = (landscape ? bootstrapShortEdgePixels : bootstrapLongEdgePixels) / requested.scale
        let scale = min(1, min(Double(maximumWidth) / Double(requested.pointsWide),
                               Double(maximumHeight) / Double(requested.pointsHigh)))
        guard scale < 1 else { return requested }
        return VirtualCanvasSize(
            pointsWide: max(2, Int(Double(requested.pointsWide) * scale) & ~1),
            pointsHigh: max(2, Int(Double(requested.pointsHigh) * scale) & ~1),
            scale: requested.scale)
    }
}
