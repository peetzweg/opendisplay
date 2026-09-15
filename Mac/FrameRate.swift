import Foundation

/// Capture-resolution / bitrate trade-off. The virtual display always runs at
/// native size — only the captured/encoded stream is scaled, so lower presets
/// cut encode, transmit, and decode time at the cost of sharpness.
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
        case .best: return "Best (native)"
        case .balanced: return "Balanced (75%)"
        case .fast: return "Fast (50%)"
        }
    }

    var explanation: String {
        switch self {
        case .best: return "Pixel-perfect at the device's native resolution. Highest bandwidth and latency."
        case .balanced: return "75% capture resolution — noticeably lower latency, slight softness."
        case .fast: return "Half resolution — lowest latency and bandwidth, visibly softer. Good for WiFi."
        }
    }
}

/// User-selectable target frame rate for the capture stream and virtual display.
/// Supports high-refresh ProMotion displays (120 Hz) on iPad Pro and iPhone Pro.
enum FrameRate: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60
    case fps90 = 90
    case fps120 = 120

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fps30: return "30 FPS (Low Power)"
        case .fps60: return "60 FPS (Default)"
        case .fps90: return "90 FPS"
        case .fps120: return "120 FPS (ProMotion)"
        }
    }

    var explanation: String {
        switch self {
        case .fps30: return "Lowest CPU and power usage. Best for static content or saving battery."
        case .fps60: return "Standard smooth frame rate for general use."
        case .fps90: return "High refresh rate with balanced CPU and bandwidth overhead."
        case .fps120: return "Ultra-smooth ProMotion 120 Hz for compatible iPad Pro and iPhone Pro displays."
        }
    }

    /// Auto-scaled bitrate to ensure picture clarity is preserved at higher frame rates.
    /// Boosts up to ~28.8 Mbps at 120 FPS for Best quality.
    func bitrate(for quality: StreamQuality) -> Int {
        let base = quality.bitrate
        switch self {
        case .fps30:
            return Int(Double(base) * 0.75)
        case .fps60:
            return base
        case .fps90:
            return Int(Double(base) * 1.25)
        case .fps120:
            return Int(Double(base) * 1.6)
        }
    }
}
