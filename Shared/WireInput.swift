// Wire input events: Apple Pencil, sent phone → Mac on the control channel.
// JSON-encoded, one framed message per event.
//
// Finger mapping (unchanged wire): legacy `touch` + `scroll` messages until
// multi-touch gesture support lands in a follow-up PR.

import Foundation

enum WireInput {
    static let pencil = "pencil"
    static let proximity = "proximity"
    static let barrelButton = "barrelButton"
}

enum PencilPhase: String {
    case down, move, up, hover
}
