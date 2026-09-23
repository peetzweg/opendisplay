/// Whether the receiver's video window should be in native fullscreen for the
/// current sender session. Each session starts wanting fullscreen; leaving it
/// or closing the window records the user's choice until the session ends. A
/// window rebuilt within the session (a reconnect inside the sender's grace
/// period) is restored to that choice rather than the default.
struct FullscreenSessionState {
    private(set) var wantsFullscreen = true

    mutating func userEnteredFullscreen() {
        wantsFullscreen = true
    }

    mutating func userLeftFullscreen() {
        wantsFullscreen = false
    }

    mutating func beginNextSession() {
        wantsFullscreen = true
    }
}
