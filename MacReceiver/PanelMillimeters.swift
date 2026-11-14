import CoreGraphics

/// `hello.panel.millimetersWide/High` (PROTOCOL.md 6.7) on the Mac
/// receiver: the physical size of the announced pixels, from the screen's
/// `CGDisplayScreenSize` and its native pixels.
enum PanelMillimeters {
    /// - Parameters:
    ///   - pixelsWide, pixelsHigh: the announced panel, oriented, minus any
    ///     notch strip.
    ///   - nativeWide, nativeHigh: the screen's native pixels, oriented the
    ///     same way.
    ///   - screen: `CGDisplayScreenSize`, in either orientation.
    /// - Returns: millimetres to 0.1, or nil when macOS does not know the
    ///   size (it reports 0 x 0 for a display without one).
    static func of(pixelsWide: Int, pixelsHigh: Int,
                   nativeWide: Int, nativeHigh: Int,
                   screen: CGSize) -> (wide: Double, high: Double)? {
        let long = Double(max(screen.width, screen.height))
        let short = Double(min(screen.width, screen.height))
        guard long.isFinite, short > 0, nativeWide > 0, nativeHigh > 0,
              pixelsWide > 0, pixelsHigh > 0 else { return nil }
        let screenWide = nativeWide >= nativeHigh ? long : short
        let screenHigh = nativeWide >= nativeHigh ? short : long
        func tenth(_ mm: Double) -> Double { (mm * 10).rounded() / 10 }
        return (tenth(screenWide * Double(pixelsWide) / Double(nativeWide)),
                tenth(screenHigh * Double(pixelsHigh) / Double(nativeHigh)))
    }
}
