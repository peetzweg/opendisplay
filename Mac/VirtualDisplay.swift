import Foundation
import CoreGraphics

/// Wraps the private CGVirtualDisplay API: makes macOS believe a real monitor
/// is attached. Sized in points at HiDPI (@2x), so a phone with native pixels
/// W×H gets a virtual display of (W/2)×(H/2) points backed by a W×H framebuffer.
final class VirtualDisplay {

    private let display: CGVirtualDisplay
    private let settings: CGVirtualDisplaySettings
    let pointsWide: Int
    let pointsHigh: Int

    var displayID: CGDirectDisplayID { display.displayID }

    /// Must be called on the main thread. `serialNum` must be unique per
    /// concurrent display AND stable per device — macOS keys saved display
    /// arrangement on vendor/product/serial, so a stable serial means each
    /// device keeps its position in System Settings across sessions.
    init?(name: String, pointsWide: Int, pointsHigh: Int, sizeInMillimeters: CGSize,
          serialNum: UInt32 = 0x0001) {
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(pointsWide * 2)
        descriptor.maxPixelsHigh = UInt32(pointsHigh * 2)
        descriptor.sizeInMillimeters = sizeInMillimeters
        descriptor.productID = 0x4F53   // "OS"
        descriptor.vendorID = 0x5043    // "PC"
        descriptor.serialNum = serialNum
        descriptor.terminationHandler = { _, _ in
            Log.info("virtual display terminated by the system")
        }

        display = CGVirtualDisplay(descriptor: descriptor)

        settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(pointsWide), height: UInt(pointsHigh), refreshRate: 60)
        ]
        guard display.apply(settings) else {
            Log.info("CGVirtualDisplay applySettings FAILED")
            return nil
        }
        Log.info("virtual display created: id=\(display.displayID) \(pointsWide)x\(pointsHigh)pt @2x")

        // macOS defaults the new display to its 1x mode AND can restore a
        // stale saved mode for this serial asynchronously, seconds after the
        // display appears (observed: a display checked as @2x at creation
        // sitting at 1x later, and a rotated rebuild pillarboxed by the
        // previous orientation's mode). So mode selection is enforcement,
        // not a one-shot: keep watching for the lifetime of the display and
        // re-assert the HiDPI mode whenever something else changes it.
        Task { @MainActor [weak self] in
            var settled = false
            while true {
                // Scoped strong ref: a rotation rebuild relies on release
                // removing the display — never hold it across the sleep.
                do {
                    guard let self else { return }
                    self.ensureNotMirrored()
                    if self.selectHiDPIMode(recover: settled) { settled = true }
                }
                try? await Task.sleep(for: .milliseconds(settled ? 2000 : 200))
            }
        }
    }

    /// Returns true when the display is (now) in its HiDPI mode. Silent when
    /// nothing needed doing — this runs every 2s as enforcement. With
    /// `recover`, a missing @2x mode (macOS can replace the whole mode list
    /// when it restores saved display state) re-applies our settings to
    /// publish it again instead of failing silently forever.
    @discardableResult
    private func selectHiDPIMode(recover: Bool = false) -> Bool {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display.displayID, opts) as? [CGDisplayMode],
              let hidpi = modes.first(where: {
                  $0.width == pointsWide && $0.pixelWidth == pointsWide * 2
              }) else {
            if recover {
                Log.info("@2x mode vanished from display \(display.displayID) — re-applying settings")
                _ = display.apply(settings)
            }
            return false
        }
        if let current = CGDisplayCopyDisplayMode(display.displayID),
           current.width == hidpi.width, current.pixelWidth == hidpi.pixelWidth {
            return true
        }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, display.displayID, hidpi, nil)
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        Log.info("HiDPI mode (re)selected: \(hidpi.width)x\(hidpi.height)@2x (result \(err.rawValue))")
        return err == .success
    }

    /// An extend-mode virtual display must never sit in a system mirror set.
    /// macOS can drop it there on its own — e.g. when it misclassifies the
    /// display as a TV, whose arrangement default is "Mirror Entire Screen"
    /// (issue #100) — and that arrangement is saved per vendor/product/serial,
    /// so a stable serial means it's restored every session and the device is
    /// stuck mirroring. Detaching is enforcement, not a one-shot: like the
    /// HiDPI mode, re-break it whenever macOS re-mirrors it. Mirror mode never
    /// builds a VirtualDisplay (it captures the main display instead), so a
    /// VirtualDisplay in a mirror set is always wrong — safe to always undo.
    private func ensureNotMirrored() {
        let id = display.displayID
        guard CGDisplayIsInMirrorSet(id) != 0 else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        // Detach the virtual display itself (covers "macOS mirrors the VD onto
        // the main display")...
        CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
        // ...and any display currently mirroring the VD (covers the reporter's
        // arrangement: the device set as Main, with the built-in mirroring it).
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var list = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &list, &n)
        for other in list where other != id && CGDisplayMirrorsDisplay(other) == id {
            CGConfigureDisplayMirrorOfDisplay(config, other, kCGNullDirectDisplay)
        }
        // Session scope, NOT permanent: permanent mirror reconfiguration of the
        // private virtual display is rejected (kCGErrorIllegalArgument) and
        // silently leaves it mirrored despite a "success" from the mirror call.
        // Session scope actually dissolves the set, and this runs every ~2s for
        // the display's lifetime, so it re-overrides whatever mirror arrangement
        // macOS restores — continuous enforcement, like the HiDPI mode above.
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        Log.info("virtual display \(id) was in a mirror set — detached to extend (result \(err.rawValue))")
    }
}
