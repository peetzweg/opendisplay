import CoreGraphics

/// The receiver's window in panel pixels, as announced in `hello.panel`.
/// UIKit-free so folds, Split View and Display Zoom are unit tested.
struct ReceiverPanelGeometry: Equatable {
    let pixelsWide: Int
    let pixelsHigh: Int
    let scale: Double

    /// `window` and `screen` are bounds in points, in the current
    /// orientation; `nativePixels` is the screen's `nativeBounds` size
    /// (portrait pixels). nil for a layout without a usable size, such as
    /// the zero-sized window of a scene that is still attaching.
    init?(window: CGSize, screen: CGSize, nativePixels: CGSize, nativeScale: CGFloat) {
        guard window.width.isFinite, window.height.isFinite,
              window.width > 0, window.height > 0,
              nativeScale.isFinite, nativeScale > 0 else { return nil }
        let wide: CGFloat, high: CGFloat
        if window == screen, nativePixels.width > 0, nativePixels.height > 0 {
            // A window filling the screen reports the panel exactly. Under
            // Display Zoom points times nativeScale misses by a few pixels
            // (iPhone 8 Plus zoomed: 667 x 2.88 = 1921 for a 1920 panel).
            let long = max(nativePixels.width, nativePixels.height)
            let short = min(nativePixels.width, nativePixels.height)
            let landscape = window.width > window.height
            wide = landscape ? long : short
            high = landscape ? short : long
        } else {
            wide = (window.width * nativeScale).rounded()
            high = (window.height * nativeScale).rounded()
        }
        pixelsWide = Int(wide)
        pixelsHigh = Int(high)
        scale = Double(nativeScale)
    }
}
