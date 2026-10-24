// Carries out the sender's power actions (PROTOCOL.md 6.6) on this Mac.
// StreamReceiver decides whether a request is allowed; this file only knows
// how macOS turns itself off.

import AppKit

enum PowerControl {
    /// Everything this Mac can do on request.
    static let supported: [PowerAction] = [.shutdown]

    static func perform(_ action: PowerAction) {
        switch action {
        case .shutdown: shutDown()
        }
    }

    /// Shut down right away, without the countdown dialog: kAEShutDown to
    /// loginwindow (kAEShowShutdownDialog is the one with the dialog). Apps
    /// with unsaved changes can still stop it; there is no forced power-off.
    private static func shutDown() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEShutDown),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow"),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        do {
            try event.sendEvent(options: [.noReply], timeout: 10)
        } catch {
            Log.info("power shutdown failed: \(error)")
        }
    }
}
