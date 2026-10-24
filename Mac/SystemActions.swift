import AppKit
import CoreGraphics
import Darwin

/// System actions a receiver can trigger without a keyboard or trackpad:
/// the `gesture` wire message (PROTOCOL.md 6.1, idea from #371). The wire
/// carries an action name, never a key code, so the Mac decides how.
///
/// Mission Control, App Exposé and Show Desktop go straight to the Dock
/// (CoreDockSendNotification), independent of the user's shortcuts. Spaces
/// and Spotlight have no such entry point, so they post the user's own
/// shortcut, read from the system's symbolic hotkeys: whatever the user
/// rebound in System Settings › Keyboard › Keyboard Shortcuts is what fires.
enum SystemAction: String, CaseIterable {
    case missionControl
    case appExpose
    case showDesktop
    case apps
    case spotlight
    case spaceLeft
    case spaceRight

    enum Route: Equatable {
        /// A Dock notification name.
        case dock(String)
        /// A symbolic hotkey id (CGSSymbolicHotKey).
        case hotKey(Int32)
        /// An app bundle to open.
        case app(String)
    }

    /// How this Mac performs the action. `appsLauncher` is macOS 26+, where
    /// the Apps app replaced Launchpad.
    func route(appsLauncher: Bool) -> Route {
        switch self {
        case .missionControl: return .dock("com.apple.expose.awake")
        case .appExpose: return .dock("com.apple.expose.front.awake")
        case .showDesktop: return .dock("com.apple.showdesktop.awake")
        case .apps:
            return .app(appsLauncher ? "/System/Applications/Apps.app"
                                     : "/System/Applications/Launchpad.app")
        case .spotlight: return .hotKey(64)
        case .spaceLeft: return .hotKey(79)
        case .spaceRight: return .hotKey(81)
        }
    }

    /// Switching Spaces acts on the display under the pointer.
    var needsPointerOnDisplay: Bool { self == .spaceLeft || self == .spaceRight }

    static var appsLauncher: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    /// Returns false (and logs why) when the action could not be performed.
    @discardableResult
    func perform() -> Bool {
        switch route(appsLauncher: Self.appsLauncher) {
        case .dock(let name):
            guard let send = Self.coreDockSend else {
                Log.info("system action \(rawValue): CoreDockSendNotification unavailable")
                return false
            }
            send(name as CFString, nil)
            return true
        case .hotKey(let id):
            return Self.postSymbolicHotKey(id, action: rawValue)
        case .app(let path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                               configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Log.info("system action \(rawValue): could not open \(path): \(error.localizedDescription)") }
            }
            return true
        }
    }

    // MARK: Private API, resolved at runtime

    private typealias CoreDockSend = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
    private typealias GetHotKey = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>,
                                                  UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IsHotKeyEnabled = @convention(c) (Int32) -> Bool

    private static let coreDockSend: CoreDockSend? = symbol(
        "CoreDockSendNotification",
        in: "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
    private static let getHotKey: GetHotKey? = symbol(
        "SLSGetSymbolicHotKeyValue", in: "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
    private static let isHotKeyEnabled: IsHotKeyEnabled? = symbol(
        "SLSIsSymbolicHotKeyEnabled", in: "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")

    private static func symbol<T>(_ name: String, in path: String) -> T? {
        guard let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    private static let keySource = CGEventSource(stateID: .hidSystemState)

    /// Posts the key combination bound to a symbolic hotkey. The stored
    /// modifiers include the function-key bit for arrows and F-keys, which the
    /// system needs to match synthetic events (as #279 found on real hardware).
    private static func postSymbolicHotKey(_ id: Int32, action: String) -> Bool {
        guard let getHotKey, let isHotKeyEnabled else {
            Log.info("system action \(action): symbolic hotkeys unavailable")
            return false
        }
        var character: UInt16 = 0, keyCode: UInt16 = 0
        var modifiers: UInt32 = 0
        guard getHotKey(id, &character, &keyCode, &modifiers) == 0, keyCode != 0xFFFF else {
            Log.info("system action \(action): no shortcut for hotkey \(id)")
            return false
        }
        guard isHotKeyEnabled(id) else {
            Log.info("system action \(action): its shortcut is turned off in System Settings › Keyboard › Keyboard Shortcuts")
            return false
        }
        let flags = CGEventFlags(rawValue: UInt64(modifiers))
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: keySource, virtualKey: keyCode, keyDown: down) else { return false }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}
