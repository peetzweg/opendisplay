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

/// Whether the receiver uses the whole panel, including the menu-bar strip
/// beside a notch. Off by default: native fullscreen cannot cover that strip,
/// so this mode presents the video in a borderless window above the menu bar
/// instead, and announces the full panel height to the sender.
enum NotchAreaPreference {
    static let key = "receiverUseNotchArea"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
