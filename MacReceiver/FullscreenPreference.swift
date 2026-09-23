import Foundation

/// Whether a newly shown receiver video window enters native fullscreen.
/// A receiver Mac acts as a display, so the default is fullscreen; the
/// user's last green-button choice sticks across sessions and relaunches.
struct FullscreenPreference {
    static let key = "receiverFullscreen"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var wantsFullscreen: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
