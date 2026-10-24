// The receiver plus the app-lifecycle policy around it (lock vs app switch
// vs quit), for the SwiftUI app or a UIKit host. OPENDISPLAY_LEGACY marks
// a build without Combine (an iOS 12 receiver built outside this repo's
// Xcode project): it supplies its own `ObservableObject` and `@Published`,
// and nothing is forwarded. Nothing here defines it.

import UIKit
import AVFoundation
import VideoToolbox
#if !OPENDISPLAY_LEGACY
import Combine
#endif

/// "iPad" or "iPhone" — so UI copy names the device the user is holding.
let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

#if !OPENDISPLAY_LEGACY
@MainActor
#endif
final class ReceiverModel: ObservableObject {
    let receiver: StreamReceiver
    private var started = false
    #if !OPENDISPLAY_LEGACY
    private var cancellables = Set<AnyCancellable>()
    #endif

    init() {
        // Offer HEVC wherever the hardware decodes it (A9 and later; the A8/A8X
        // iPads stay on H.264). Panels here fit H.264's raster anyway, so HEVC
        // buys quality per bit, which matters most over WiFi. Bounded by the
        // panel in either orientation, so a large mirrored Mac display is
        // scaled to what this screen can show instead of sent in full.
        let native = UIScreen.main.nativeBounds.size   // portrait pixels
        let longSide = Int(max(native.width, native.height))
        var decodesHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        #if DEBUG
        // The simulator has no hardware decoder; -forceHEVCOffer YES exercises
        // the HEVC receive path there with software decode.
        if UserDefaults.standard.bool(forKey: "forceHEVCOffer") { decodesHEVC = true }
        #endif
        let hevc = decodesHEVC
            ? VideoCapability(codec: "hevc", maxWidth: longSide, maxHeight: longSide,
                              maxFrameRate: 60)
            : nil
        receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                  deviceKind: deviceKind,
                                  fallbackServiceName: UIDevice.current.name,
                                  hevcCapability: hevc)
        // Announce the native panel size to the Mac.
        receiver.setNativePanel(long: Int(max(native.width, native.height)),
                                short: Int(min(native.width, native.height)),
                                scale: Double(UIScreen.main.nativeScale))
        receiver.setDisplayMaxFrameRate(UIScreen.main.maximumFramesPerSecond)
        if let budget = DecodeBudget.maxPixelsPerSecond(model: DecodeBudget.currentModel) {
            receiver.setDecodeBudget(maxPixelsPerSecond: budget)
        }
        let savedName = UserDefaults.standard.string(forKey: "deviceName")
        receiver.serviceName = (savedName?.isEmpty == false) ? savedName! : UIDevice.current.name
        #if !OPENDISPLAY_LEGACY
        receiver.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        #endif
    }

    func start() {
        guard !started else { return }
        started = true
        receiver.start(port: 9000)
    }

    // MARK: - Lock vs app switch vs app quit

    // A plain app switch keeps the session (and the Mac's virtual display,
    // and therefore the user's window arrangement) alive INDEFINITELY. The
    // assertion buys ~30s of live pings; after iOS suspends us the kernel
    // still accepts the Mac's redials, so the session survives untouched
    // until we return. Only a device lock (deliberate "screen off") or the
    // app being quit ends the session. Known hole: a lock that happens
    // after we're already suspended is undetectable — no code runs and the
    // kernel behaves identically — so the display stays up until the user
    // returns or the app dies.
    private var backgroundToken: UIBackgroundTaskIdentifier = .invalid

    func sceneDidBackground() {
        // Known limitation: lock detection rides the protected-data signal,
        // which only fires when a passcode is set AND "Require Passcode" is
        // Immediately (the Face ID default). Other configurations make a
        // lock indistinguishable from an app switch, so those keep the
        // session like a backgrounded app would.
        if !UIApplication.shared.isProtectedDataAvailable {
            // Backgrounded because the device locked, not an app switch.
            Log.info("backgrounded by device lock — sleeping now")
            goToSleep()
            return
        }
        Log.info("app switched away — keeping the session, rendering paused")
        beginBackgroundAssertion()
        receiver.setRenderingPaused(true)
    }

    func sceneDidActivate() {
        endBackgroundAssertion()
        receiver.setRenderingPaused(false)
        receiver.ensureListening()
    }

    func deviceWillLock() {
        Log.info("device locking — sleeping now")
        goToSleep()
    }

    /// Unlock arrives via the protected-data notification, which also fires
    /// when the user unlocks into ANOTHER app while we sit in the background
    /// — don't re-arm the listener or unpause rendering off-screen there;
    /// the real return still comes through scenePhase.
    func deviceDidUnlock() {
        guard UIApplication.shared.applicationState == .active else {
            Log.info("unlocked while backgrounded — staying dormant")
            return
        }
        sceneDidActivate()
    }

    /// User swiped the app away (or iOS terminates us while still running):
    /// ~5s of runtime remain, plenty for the "closing" goodbye that lets the
    /// Mac end the session immediately instead of after its silence grace.
    func appWillTerminate() {
        Log.info("app terminating — closing session")
        receiver.shutDown()
    }

    private func goToSleep() {
        receiver.enterSleep { [weak self] in
            DispatchQueue.main.async { self?.endBackgroundAssertion() }
        }
    }

    private func beginBackgroundAssertion() {
        guard backgroundToken == .invalid else { return }
        backgroundToken = UIApplication.shared.beginBackgroundTask { [weak self] in
            // Suspension takes us now; the session stays up by design (the
            // kernel keeps accepting for us) — just release the assertion.
            self?.endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundToken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundToken)
        backgroundToken = .invalid
    }
}
