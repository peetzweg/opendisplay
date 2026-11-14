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

/// The physical size declared for the virtual display
/// (`CGVirtualDisplayDescriptor.sizeInMillimeters`): the receiver's real
/// panel size, bent only as far as macOS needs to honour it.
///
/// The size is fixed when the descriptor is created. A rotation or resize
/// applies a new mode to the same display (see `VirtualDisplay.resize`), and
/// macOS keeps reporting the creation-time size (`CGDisplayScreenSize`), so
/// after a rotation the reported shape is the old orientation's until the
/// display is rebuilt. Measured on macOS 27.0.1.
///
/// Limits, all measured with a standalone CGVirtualDisplay probe (PR notes):
/// * macOS 26.1 never brings a display online when the declared area is under
///   about 160 cm² and the descriptor reserves more than about 2,000 pixels
///   per axis, which `VirtualCanvasSizing.reservedPixelsPerAxis` always does
///   (#479). Floor: the area of 208 x 96 mm.
/// * macOS 27.0.1 ignores a declared width under about 170 mm (165 ignored,
///   170 honoured, whatever the pixels or height): it then reports 72 dpi of
///   the backing pixels and defaults the display to its 1x mode. Floor:
///   180 mm wide, so a phone in portrait is declared at least 180 mm wide.
/// * macOS 27.0.1 also defaults a display to its 1x mode when the creation
///   mode has fewer than about 150 pixels per inch of declared width. A 2x
///   desktop is held at 160 or more so it starts in its HiDPI mode.
/// * Large sizes come online (3000 x 1700 mm did); the long side is capped
///   at 2 m as a sanity bound.
///
/// The floors win over the density hold: coming online matters more than
/// the default mode, which `VirtualDisplay` enforces anyway.
enum PhysicalDisplaySize {
    static let minimumWidth = 180.0
    static let minimumArea = 208.0 * 96.0
    static let minimumHiDPIPixelsPerInch = 160.0
    static let maximumLongSide = 2_000.0

    enum Source: String { case reported, estimated }

    /// - Parameters:
    ///   - reported: `hello.panel.millimetersWide/High`, if the receiver sent them.
    ///   - facts: the panel the size describes.
    ///   - device: `hello.device`, for the estimate.
    ///   - creation: the canvas the display is created with; its orientation
    ///     and (for a 2x canvas) its pixel width bound the result.
    static func declared(reported: CGSize?, facts: PanelFacts, device: String?,
                         creation: VirtualCanvasSize) -> (size: CGSize, source: Source) {
        let real: CGSize
        let source: Source
        if let reported, isPlausible(reported, for: facts) {
            real = reported
            source = .reported
        } else {
            real = estimated(facts: facts, device: device)
            source = .estimated
        }
        return (fitted(real, creation: creation), source)
    }

    /// A reported size is used when it is a real size for those pixels:
    /// finite and positive, 50 to 1,000 pixels per inch on each axis, and
    /// the same shape as the pixels within 25 % (so a size reported in the
    /// other orientation is not trusted).
    static func isPlausible(_ size: CGSize, for facts: PanelFacts) -> Bool {
        let w = Double(size.width), h = Double(size.height)
        guard w.isFinite, h.isFinite, w > 0, h > 0 else { return false }
        let dpiWide = Double(facts.pixelsWide) / (w / 25.4)
        let dpiHigh = Double(facts.pixelsHigh) / (h / 25.4)
        guard (50...1_000).contains(dpiWide), (50...1_000).contains(dpiHigh) else { return false }
        let shape = (w / h) / (Double(facts.pixelsWide) / Double(facts.pixelsHigh))
        return (0.8...1.25).contains(shape)
    }

    /// No reported size: typical pixel densities by device kind. iOS has no
    /// public API for the panel's physical size, so iPhones and iPads always
    /// land here.
    static func estimated(facts: PanelFacts, device: String?) -> CGSize {
        let ppi: Double
        switch device {
        case "iPhone": ppi = facts.scale >= 2.5 ? 460 : 326
        case "iPad": ppi = 264
        case "Mac": ppi = facts.scale >= 1.5 ? 220 : 110
        default: ppi = 160 * max(facts.scale, 1)   // Android's density convention
        }
        return CGSize(width: Double(facts.pixelsWide) / ppi * 25.4,
                      height: Double(facts.pixelsHigh) / ppi * 25.4)
    }

    /// Orients `real` like the creation canvas and scales it, keeping its
    /// shape, into the limits above. Whole millimetres.
    static func fitted(_ real: CGSize, creation: VirtualCanvasSize) -> CGSize {
        let long = Double(max(real.width, real.height))
        let short = Double(min(real.width, real.height))
        let landscape = creation.pointsWide >= creation.pointsHigh
        let w = landscape ? long : short
        let h = landscape ? short : long

        var upper = maximumLongSide / long
        if creation.scale == 2 {
            let widest = Double(creation.pixelsWide) / minimumHiDPIPixelsPerInch * 25.4
            upper = min(upper, widest / w)
        }
        let lower = max(minimumWidth / w, (minimumArea / (w * h)).squareRoot())
        let k = max(lower, min(1, upper))
        // Up, so the floors hold; the epsilon keeps 180.000…01 at 180.
        func whole(_ mm: Double) -> Double { (mm - 1e-6).rounded(.up) }
        return CGSize(width: whole(w * k), height: whole(h * k))
    }
}
