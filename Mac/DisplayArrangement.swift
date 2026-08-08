import CoreGraphics
import Foundation

/// Remembers where the user placed each device's virtual display (#116).
///
/// macOS does persist display arrangement, but keys it on the monitor
/// identity (vendor/product/serial) — and ours legitimately changes: each
/// orientation uses a distinct serial (saved-mode separation, see
/// setupExtend), and the serial also derives from the session id, so USB
/// and WiFi produce different identities for the same iPad. Every such
/// change makes macOS treat the display as a brand-new monitor and park it
/// at the default position. Keying saved origins on the device's install id
/// makes the arrangement follow the physical device instead.
enum DisplayArrangement {

    /// Record the origin (global desktop points) the display settled at.
    /// One record per device — the latest arrangement wins regardless of
    /// orientation, so the display follows wherever the user last put it
    /// (tested per-orientation spots and flipping back to an orientation's
    /// old position reads as broken; deliberate split positions are a
    /// possible opt-in, see #128).
    static func save(origin: CGPoint, size: CGSize, device: String) {
        let rect = CGRect(origin: origin, size: size)
        let previousSide = load(device)?.side
        let main = CGDisplayBounds(CGMainDisplayID())
        let side = side(of: rect, relativeTo: main, preferring: previousSide)
        var record = [Int(origin.x), Int(origin.y), Int(size.width), Int(size.height)]
        if let side { record.append(side.rawValue) }
        UserDefaults.standard.set(record, forKey: key(device))
    }

    /// Where a new display of `size` points should go: the saved spot
    /// verbatim when the size matches. On rotation, keep the device on the
    /// same side of the built-in display and retain its cross-axis offset. A
    /// center-preserving remap puts a rotated display half the aspect-ratio
    /// difference into a gap or overlap; WindowServer then snaps it, and the
    /// snap becomes the next saved position (#203).
    ///
    /// Nil on first contact — let macOS choose.
    static func origin(for size: CGSize, device: String) -> CGPoint? {
        guard let placement = load(device) else { return nil }
        if placement.rect.size == size { return placement.rect.origin }
        let main = CGDisplayBounds(CGMainDisplayID())
        // Records from before #203 did not store a side. If one already
        // touches the main display, infer it now so an otherwise clean
        // existing arrangement also gains the stable behavior on rotation.
        if let side = placement.side ?? side(of: placement.rect, relativeTo: main, preferring: nil) {
            return origin(for: size, from: placement.rect, side: side,
                          relativeTo: main)
        }
        return remappedOrigin(from: placement.rect, to: size, against: activeDisplayBounds())
    }

    /// The user-visible slot a virtual display occupies relative to the main
    /// desktop. This survives the virtual display being destroyed and rebuilt
    /// on every device rotation.
    enum Side: Int {
        case left, right, above, below

        var priority: Int {
            switch self {
            case .left, .right: return 1
            case .above, .below: return 0
            }
        }
    }

    /// Pure geometry seam for side-preserving arrangement tests.
    static func origin(for size: CGSize, from saved: CGRect, side: Side, relativeTo main: CGRect) -> CGPoint {
        switch side {
        case .left:
            return CGPoint(x: main.minX - size.width, y: saved.minY)
        case .right:
            return CGPoint(x: main.maxX, y: saved.minY)
        case .above:
            return CGPoint(x: saved.minX, y: main.minY - size.height)
        case .below:
            return CGPoint(x: saved.minX, y: main.maxY)
        }
    }

    /// Pure geometry seam for arrangement regression tests. `displays` are
    /// the displays already on the desktop; the rebuilt virtual display is
    /// deliberately not present yet.
    static func remappedOrigin(from saved: CGRect, to size: CGSize,
                               against displays: [CGRect]) -> CGPoint {
        guard saved.size != size else { return saved.origin }

        if let attachment = attachment(of: saved, to: displays) {
            switch attachment.side {
            case .left:
                return CGPoint(x: attachment.display.minX - size.width,
                               y: attachment.display.minY + attachment.crossAxisOffset)
            case .right:
                return CGPoint(x: attachment.display.maxX,
                               y: attachment.display.minY + attachment.crossAxisOffset)
            case .above:
                return CGPoint(x: attachment.display.minX + attachment.crossAxisOffset,
                               y: attachment.display.minY - size.height)
            case .below:
                return CGPoint(x: attachment.display.minX + attachment.crossAxisOffset,
                               y: attachment.display.maxY)
            }
        }

        // A record written by an older version, or a layout whose neighbour
        // disappeared, has no reliable attachment to preserve. Keep the old
        // behaviour as a compatibility fallback rather than guessing a side.
        return CGPoint(x: saved.midX - size.width / 2,
                       y: saved.midY - size.height / 2)
    }

    private struct Placement {
        let rect: CGRect
        let side: Side?
    }

    private static func load(_ device: String) -> Placement? {
        guard let record = UserDefaults.standard.array(forKey: key(device)) as? [Int],
              record.count == 4 || record.count == 5 else { return nil }
        let rect = CGRect(x: CGFloat(record[0]), y: CGFloat(record[1]),
                          width: CGFloat(record[2]), height: CGFloat(record[3]))
        return Placement(rect: rect, side: record.count == 5 ? Side(rawValue: record[4]) : nil)
    }

    private static func side(of rect: CGRect, relativeTo main: CGRect,
                             preferring preferred: Side?) -> Side? {
        var candidates: [Side] = []
        if rect.maxX == main.minX { candidates.append(.left) }
        if rect.minX == main.maxX { candidates.append(.right) }
        if rect.maxY == main.minY { candidates.append(.above) }
        if rect.minY == main.maxY { candidates.append(.below) }
        if let preferred, candidates.contains(preferred) { return preferred }
        return candidates.max { $0.priority < $1.priority }
    }

    static func inferredMainDisplaySide(of rect: CGRect, relativeTo main: CGRect) -> Side? {
        side(of: rect, relativeTo: main, preferring: nil)
    }

    private struct Attachment {
        let side: Side
        let display: CGRect
        let crossAxisOffset: CGFloat
        let overlap: CGFloat
    }

    private static func attachment(of saved: CGRect, to displays: [CGRect]) -> Attachment? {
        let candidates = displays.flatMap { display -> [Attachment] in
            var attachments: [Attachment] = []
            if saved.maxX == display.minX,
               let overlap = overlap(of: saved.minY...saved.maxY, and: display.minY...display.maxY) {
                attachments.append(Attachment(side: .left, display: display,
                                              crossAxisOffset: saved.minY - display.minY,
                                              overlap: overlap))
            }
            if saved.minX == display.maxX,
               let overlap = overlap(of: saved.minY...saved.maxY, and: display.minY...display.maxY) {
                attachments.append(Attachment(side: .right, display: display,
                                              crossAxisOffset: saved.minY - display.minY,
                                              overlap: overlap))
            }
            if saved.maxY == display.minY,
               let overlap = overlap(of: saved.minX...saved.maxX, and: display.minX...display.maxX) {
                attachments.append(Attachment(side: .above, display: display,
                                              crossAxisOffset: saved.minX - display.minX,
                                              overlap: overlap))
            }
            if saved.minY == display.maxY,
               let overlap = overlap(of: saved.minX...saved.maxX, and: display.minX...display.maxX) {
                attachments.append(Attachment(side: .below, display: display,
                                              crossAxisOffset: saved.minX - display.minX,
                                              overlap: overlap))
            }
            return attachments
        }
        return candidates.max {
            if $0.overlap != $1.overlap { return $0.overlap < $1.overlap }
            // At a corner, both a horizontal and vertical attachment are
            // geometrically valid. Prefer the horizontal side: it preserves
            // the display's relationship to the Mac's left/right desktop
            // region and maximises continuity through a phone rotation.
            return $0.side.priority < $1.side.priority
        }
    }

    private static func overlap(of first: ClosedRange<CGFloat>, and second: ClosedRange<CGFloat>) -> CGFloat? {
        let amount = min(first.upperBound, second.upperBound) - max(first.lowerBound, second.lowerBound)
        // WindowServer permits a desktop to be connected at a single corner.
        // That still gives us a valid attachment side to preserve on rotation.
        return amount >= 0 ? amount : nil
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    private static func key(_ device: String) -> String { "displayOrigin.\(device)" }
}
