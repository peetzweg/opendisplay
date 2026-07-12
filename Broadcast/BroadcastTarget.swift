// Compiled into BOTH the iOS app and the broadcast extension (see project.yml
// `sources`). App-group defaults are the only channel the two processes share:
// the app writes the chosen receiver here, the extension reads it when the
// system starts the broadcast (issue #123).

import Foundation

enum BroadcastTarget {
    /// Must match `com.apple.security.application-groups` in both the app's
    /// and the extension's entitlements.
    static let appGroupID = "group.com.peetzweg.opensidecar.ios"

    /// The extension's bundle id — the app's broadcast picker pins itself to
    /// it so the system sheet doesn't list unrelated broadcast services.
    static let extensionBundleID = "com.peetzweg.opensidecar.ios.broadcast"

    private static let serviceKey = "broadcastTargetService"

    /// Bonjour service name of the receiver to stream to. Nil until the user
    /// picks a device in the app.
    static var serviceName: String? {
        get { UserDefaults(suiteName: appGroupID)?.string(forKey: serviceKey) }
        set { UserDefaults(suiteName: appGroupID)?.set(newValue, forKey: serviceKey) }
    }
}
