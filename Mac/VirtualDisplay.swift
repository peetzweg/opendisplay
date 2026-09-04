import Foundation
import CoreGraphics

/// Wraps the private CGVirtualDisplay API: makes macOS believe a real monitor
/// is attached. Sized in points at HiDPI (@2x), so a phone with native pixels
/// W×H gets a virtual display of (W/2)×(H/2) points backed by a W×H framebuffer.
final class VirtualDisplay {

    private let display: CGVirtualDisplay
    private var settings: CGVirtualDisplaySettings
    private let maxPointsPerAxis: Int
    private(set) var pointsWide: Int
    private(set) var pointsHigh: Int

    private var restoreTarget: CGPoint?
    private var restoreUntil: Date
    private var lastReportedOrigin: CGPoint?
    private let onOriginChange: ((CGPoint, CGSize) -> Void)?

    var displayID: CGDirectDisplayID { display.displayID }

    /// Must be called on the main thread. `serialNum` must be unique per
    /// concurrent display AND stable per device — macOS keys saved display
    /// arrangement on vendor/product/serial, so a stable serial means each
    /// device keeps its position in System Settings across sessions.
    /// `restoreOrigin` overrides that saved arrangement (see manageOrigin);
    /// `onOriginChange` reports where the display sits afterwards, so the
    /// caller can persist user drags.
    init?(name: String, pointsWide: Int, pointsHigh: Int, sizeInMillimeters: CGSize,
          serialNum: UInt32 = 0x0001, productID: UInt32 = 0x4F53,
          restoreOrigin: CGPoint? = nil,
          onOriginChange: ((CGPoint, CGSize) -> Void)? = nil) {
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh
        // Reserve the longer orientation on both axes. That lets a phone or
        // tablet change orientation by applying a new mode to this *same*
        // virtual monitor instead of removing it and stranding its windows.
        maxPointsPerAxis = max(pointsWide, pointsHigh)
        self.restoreTarget = restoreOrigin
        self.restoreUntil = restoreOrigin == nil ? .distantPast : Date().addingTimeInterval(6)
        self.onOriginChange = onOriginChange

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(maxPointsPerAxis * 2)
        descriptor.maxPixelsHigh = UInt32(maxPointsPerAxis * 2)
        descriptor.sizeInMillimeters = sizeInMillimeters
        descriptor.productID = productID   // base 0x4F53 "OS"; moves with the
                                           // serial when an identity is
                                           // abandoned (see MacSender)
        descriptor.vendorID = 0x5043       // "PC"
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
                    self.manageOrigin()
                }
                try? await Task.sleep(for: .milliseconds(settled ? 2000 : 200))
            }
        }
    }

    /// Change orientation without changing the virtual monitor's identity.
    /// Releasing a CGVirtualDisplay makes WindowServer redistribute every
    /// window on it before the replacement appears; with multiple devices,
    /// it may choose a sibling virtual display. Applying a new mode avoids
    /// that reassignment entirely.
    ///
    /// Must be called on the main thread.
    @discardableResult
    func resize(pointsWide: Int, pointsHigh: Int, movingTo origin: CGPoint?) -> Bool {
        guard pointsWide <= maxPointsPerAxis, pointsHigh <= maxPointsPerAxis else {
            Log.info("virtual display \(display.displayID) cannot resize beyond its descriptor")
            return false
        }

        let newSettings = CGVirtualDisplaySettings()
        newSettings.hiDPI = 1
        newSettings.modes = [
            CGVirtualDisplayMode(width: UInt(pointsWide), height: UInt(pointsHigh), refreshRate: 60)
        ]
        guard display.apply(newSettings) else {
            Log.info("virtual display \(display.displayID) applySettings FAILED during resize")
            return false
        }
        settings = newSettings
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh

        if let origin {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success {
                CGConfigureDisplayOrigin(config, display.displayID, Int32(origin.x), Int32(origin.y))
                let err = CGCompleteDisplayConfiguration(config, .permanently)
                // A mode change is a display reconfiguration, so macOS may
                // restore ITS arrangement for this identity a moment later,
                // exactly as it does after creation. Re-arm the same window so
                // that gets overridden, and adopt whatever WindowServer settled
                // on: a snap is system state, and persisting it as if it were a
                // user drag is the ratchet #203 is about.
                let settled = CGDisplayBounds(display.displayID).origin
                restoreTarget = settled
                restoreUntil = Date().addingTimeInterval(6)
                lastReportedOrigin = settled
                Log.info("virtual display \(display.displayID) resized to \(pointsWide)x\(pointsHigh)pt "
                    + "at (\(Int(origin.x)),\(Int(origin.y))), settled "
                    + "(\(Int(settled.x)),\(Int(settled.y))) (result \(err.rawValue))")
            }
        } else {
            Log.info("virtual display \(display.displayID) resized to \(pointsWide)x\(pointsHigh)pt")
        }
        return true
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

    /// Arrangement restore + observation (#116). For the first few seconds,
    /// assert `restoreTarget`: macOS restores ITS saved arrangement for this
    /// display identity asynchronously, seconds after creation, and that
    /// record is stale or default whenever the identity is fresh (rotation
    /// swaps the serial, transport switches change it) — the caller's
    /// device-keyed record must win. Afterwards, origin changes are the user
    /// rearranging: report them so the caller can persist the new spot.
    private func manageOrigin() {
        let id = display.displayID
        let origin = CGDisplayBounds(id).origin
        if let target = restoreTarget, Date() < restoreUntil {
            // Initial arrangement is system state, not a user drag. Mark it
            // observed so it cannot overwrite the saved device placement
            // when the restore window expires (#203).
            guard origin != target else {
                lastReportedOrigin = origin
                return
            }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return }
            CGConfigureDisplayOrigin(config, id, Int32(target.x), Int32(target.y))
            let err = CGCompleteDisplayConfiguration(config, .permanently)
            // WindowServer snaps the requested origin to the nearest valid
            // arrangement — adopt what it settled on, or every remaining
            // tick of the window would re-apply against the snap.
            restoreTarget = CGDisplayBounds(id).origin
            // A snap is also system state. Keep observing from the settled
            // point, but only a later origin change may be a user drag.
            lastReportedOrigin = restoreTarget
            Log.info("display \(id) origin (\(Int(origin.x)),\(Int(origin.y))) → restored "
                + "(\(Int(target.x)),\(Int(target.y))), settled "
                + "(\(Int(restoreTarget!.x)),\(Int(restoreTarget!.y))) (result \(err.rawValue))")
            return
        }
        if origin != lastReportedOrigin {
            lastReportedOrigin = origin
            onOriginChange?(origin, CGSize(width: pointsWide, height: pointsHigh))
        }
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
        // boolean_t is Int32: CoreGraphics returns 1 for mirrored, 0 for not mirrored,
        // and -1 for unknown/unregistered display IDs. Checking `!= 0` treats missing
        // displays as mirrored (issue #142) — compare explicitly against 1.
        guard CGDisplayIsInMirrorSet(id) == 1 else { return }

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
