import Foundation

/// Avoid publishing one-frame system cursor transitions (e.g. arrow/I-beam)
/// while keeping genuine shape changes responsive after a short settle time.
struct CursorSpriteStabilizer {
    private let settleTime: TimeInterval
    private var accepted: Int?
    private var candidate: Int?
    private var candidateSince: TimeInterval = 0

    init(settleTime: TimeInterval = 0.09) { self.settleTime = settleTime }

    mutating func shouldPublish(_ hash: Int, at time: TimeInterval, force: Bool = false) -> Bool {
        guard time.isFinite else { return false }
        if force {
            accepted = nil
            candidate = nil
            candidateSince = 0
        }
        guard accepted != nil else { accepted = hash; return true }
        if accepted == hash { candidate = nil; return false }
        if candidate != hash {
            candidate = hash
            candidateSince = time
            return false
        }
        guard time - candidateSince >= settleTime else { return false }
        accepted = hash
        candidate = nil
        return true
    }
}
