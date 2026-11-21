import CoreGraphics
import Foundation

/// One saved position for the whole Mac, including when several receivers are
/// touched before returning to the mouse. Callers serialize access.
struct CursorRestoreState {
    private(set) var savedPosition: CGPoint?
    private var participants: Set<UUID> = []
    private var pressed: Set<UUID> = []

    mutating func touch(from owner: UUID, phase: String, cursor: CGPoint) {
        if savedPosition == nil { savedPosition = cursor }
        participants.insert(owner)
        if phase == "began" { pressed.insert(owner) }
        if phase == "ended" || phase == "cancelled" { pressed.remove(owner) }
    }

    mutating func resumeMouse(displays: [CGRect]) -> CGPoint? {
        guard pressed.isEmpty, let saved = savedPosition else { return nil }
        reset()
        // A disconnected/rearranged display must not strand the pointer.
        if displays.contains(where: { $0.contains(saved) }) { return saved }
        let candidates = displays.map {
            CGPoint(x: min(max(saved.x, $0.minX), $0.maxX - 1),
                    y: min(max(saved.y, $0.minY), $0.maxY - 1))
        }
        return candidates.min {
            hypot($0.x - saved.x, $0.y - saved.y)
                < hypot($1.x - saved.x, $1.y - saved.y)
        }
    }

    mutating func disconnect(_ owner: UUID) {
        participants.remove(owner)
        pressed.remove(owner)
        if participants.isEmpty { reset() }
    }

    mutating func reset() {
        savedPosition = nil
        participants.removeAll()
        pressed.removeAll()
    }
}
