// Compiled into BOTH targets. The iOS App Store listing — the numeric ID
// otherwise lives only in the landing page (`src/App.tsx`). Centralized here so
// the iOS app can deep-link to its own update page AND the Mac can hand the
// same link to the phone in an `updateRequired` message.

import Foundation

enum AppStore {
    static let iOSAppID = "6780264891"
    /// Opens the App Store app directly on the listing (with an Update button).
    static let updateURL = URL(string: "itms-apps://apps.apple.com/app/id\(iOSAppID)")!
    /// Web fallback for anywhere the itms-apps scheme can't be handled.
    static let webURL = URL(string: "https://apps.apple.com/app/id\(iOSAppID)")!
}
