import Foundation

/// Which stream size and codec a session should use, decided against the
/// receiver's advertised decode ceilings (PROTOCOL.md 6.5/6.6).
///
/// H.264 is the default: cheapest to encode and every receiver decodes it.
/// HEVC here is not a quality upgrade, it is a size enabler — H.264
/// hardware decode stops around 4K on every Mac measured while HEVC
/// sustains 5K even on 2017 hardware — so the switch happens only when the
/// stream the receiver asked for cannot fit through H.264: the desired size
/// exceeds the H.264 ceiling, the receiver said it decodes HEVC, and this
/// Mac can encode it at that size. Everything else stays H.264, and a
/// receiver that advertises nothing keeps the exact pre-negotiation
/// behavior.
enum StreamNegotiation {
    struct Choice: Equatable {
        let width: Int
        let height: Int
        let useHEVC: Bool
    }

    /// `senderEncodesHEVC` is called with the size the HEVC stream would
    /// actually use (already clamped to the HEVC ceiling), and only when the
    /// policy wants HEVC — probing an encoder is not free.
    static func choose(desiredWidth: Int, desiredHeight: Int,
                       h264Ceiling: (wide: Int, high: Int)?,
                       hevcCeiling: (wide: Int, high: Int)?,
                       receiverDecodesHEVC: Bool,
                       forceHEVC: Bool,
                       senderEncodesHEVC: (Int, Int) -> Bool) -> Choice {
        if receiverDecodesHEVC,
           forceHEVC || exceeds(desiredWidth, desiredHeight, h264Ceiling) {
            let (w, h) = clamp(desiredWidth, desiredHeight, to: hevcCeiling)
            if senderEncodesHEVC(w, h) {
                return Choice(width: w, height: h, useHEVC: true)
            }
        }
        let (w, h) = clamp(desiredWidth, desiredHeight, to: h264Ceiling)
        return Choice(width: w, height: h, useHEVC: false)
    }

    private static func exceeds(_ w: Int, _ h: Int,
                                _ ceiling: (wide: Int, high: Int)?) -> Bool {
        guard let ceiling, ceiling.wide > 0, ceiling.high > 0 else { return false }
        return w > ceiling.wide || h > ceiling.high
    }

    /// The 6.5 cap: scale to fit the ceiling, keep dimensions even for the
    /// encoder. An absent ceiling caps nothing.
    private static func clamp(_ w: Int, _ h: Int,
                              to ceiling: (wide: Int, high: Int)?) -> (Int, Int) {
        guard let ceiling, ceiling.wide > 0, ceiling.high > 0,
              w > ceiling.wide || h > ceiling.high else { return (w, h) }
        let s = min(Double(ceiling.wide) / Double(w), Double(ceiling.high) / Double(h))
        return ((Int(Double(w) * s)) & ~1, (Int(Double(h) * s)) & ~1)
    }
}
