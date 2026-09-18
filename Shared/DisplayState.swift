import Foundation

/// Video state communicated by the sender over the existing control channel.
enum DisplayState: String {
    case running
    case paused

    static func decode(messageType: String, value: String?) -> Self? {
        guard messageType == "displayState", let value else { return nil }
        return Self(rawValue: value)
    }
}
