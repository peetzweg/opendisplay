import Foundation
import CoreGraphics

/// Wraps the private CGVirtualDisplay API: makes macOS believe a real monitor
/// is attached. Sized in points at HiDPI (@2x), so a phone with native pixels
/// W×H gets a virtual display of (W/2)×(H/2) points backed by a W×H framebuffer.
/// A non-Retina receiver panel gets a 1x display instead (`scale` 1), whose
/// points are its pixels, so it is streamed 1:1 like the panel's own desktop.
final class VirtualDisplay {

    // CGVirtualDisplay's descriptor ceiling is immutable even though its mode
    // list can be replaced. Keep defensive 8K headroom in addition to the
    // requested capacity supplied by the canvas plan.
    private static let reservedPixelsPerAxis = 8_192

    private let display: CGVirtualDisplay
    private var settings: CGVirtualDisplaySettings
    private let maxPixelsPerAxis: Int
    private(set) var pointsWide: Int
    private(set) var pointsHigh: Int
    /// Backing scale: 2 (HiDPI) or 1. A resize may change it.
    private(set) var scale: Int
    var pixelsWide: Int { pointsWide * scale }
    var pixelsHigh: Int { pointsHigh * scale }

    private var restoreTarget: CGPoint?
    private var restoreUntil: Date
    private var lastReportedOrigin: CGPoint?
    private let onOriginChange: ((CGPoint, CGSize) -> Void)?
    /// Called once on the main thread when macOS keeps refusing a 2x target
    /// (or keeps dropping it from the mode list), with the refused size. The
    /// display is then running some other mode, so the owner should resize
    /// it to a 1x size that capture and the stream agree on (#292).
    var onModeRefused: ((VirtualCanvasSize) -> Void)?

    var displayID: CGDirectDisplayID { display.displayID }

    /// Must be called on the main thread. `serialNum` must be unique per
    /// concurrent display AND stable per device — macOS keys saved display
    /// arrangement on vendor/product/serial, so a stable serial means each
    /// device keeps its position in System Settings across sessions.
    /// `restoreOrigin` overrides that saved arrangement (see manageOrigin);
    /// `onOriginChange` reports where the display sits afterwards, so the
    /// caller can persist user drags.
    init?(name: String, pointsWide: Int, pointsHigh: Int, scale: Int = 2,
          descriptorMaxPixelsPerAxis: Int, sizeInMillimeters: CGSize,
          serialNum: UInt32 = 0x0001, productID: UInt32 = 0x4F53,
          restoreOrigin: CGPoint? = nil,
          onOriginChange: ((CGPoint, CGSize) -> Void)? = nil) {
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh
        self.scale = scale < 2 ? 1 : 2
        // Reserve the longer orientation on both axes. The fixed headroom also
        // covers later receiver scaling changes (for example Larger Text to
        // More Space) without destroying and recreating the virtual display.
        let initialPixelsPerAxis = max(pointsWide, pointsHigh) * self.scale
        let maximumPixelsPerAxis = max(initialPixelsPerAxis,
                                       descriptorMaxPixelsPerAxis,
                                       Self.reservedPixelsPerAxis)
        maxPixelsPerAxis = (maximumPixelsPerAxis + 1) & ~1
        self.restoreTarget = restoreOrigin
        self.restoreUntil = restoreOrigin == nil ? .distantPast : Date().addingTimeInterval(6)
        self.onOriginChange = onOriginChange

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(maxPixelsPerAxis)
        descriptor.maxPixelsHigh = UInt32(maxPixelsPerAxis)
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
        settings.hiDPI = self.scale == 2 ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(pointsWide), height: UInt(pointsHigh), refreshRate: 60)
        ]
        guard display.apply(settings) else {
            Log.info("CGVirtualDisplay applySettings FAILED")
            return nil
        }
        Log.info("virtual display created: id=\(display.displayID) \(pointsWide)x\(pointsHigh)pt @\(self.scale)x")

        // macOS defaults the new display to its 1x mode AND can restore a
        // stale saved mode for this serial asynchronously, seconds after the
        // display appears (observed: a display checked as @2x at creation
        // sitting at 1x later, and a rotated rebuild pillarboxed by the
        // previous orientation's mode). So mode selection is enforcement,
        // not a one-shot: keep watching for the lifetime of the display and
        // re-assert the HiDPI mode whenever something else changes it. A 1x
        // display is enforced the same way, against its 1x mode.
        Task { @MainActor [weak self] in
            var settled = false
            while true {
                // Scoped strong ref: a rotation rebuild relies on release
                // removing the display — never hold it across the sleep.
                do {
                    guard let self else { return }
                    self.ensureNotMirrored()
                    if self.selectTargetMode(recover: settled) { settled = true }
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
    func resize(pointsWide: Int, pointsHigh: Int, scale: Int? = nil,
                movingTo origin: CGPoint?) -> Bool {
        let scale = scale.map { $0 < 2 ? 1 : 2 } ?? self.scale
        guard pointsWide * scale <= maxPixelsPerAxis, pointsHigh * scale <= maxPixelsPerAxis else {
            Log.info("virtual display \(display.displayID) cannot resize beyond its descriptor")
            return false
        }

        let newSettings = CGVirtualDisplaySettings()
        newSettings.hiDPI = scale == 2 ? 1 : 0
        newSettings.modes = [
            CGVirtualDisplayMode(width: UInt(pointsWide), height: UInt(pointsHigh), refreshRate: 60)
        ]
        Log.info("TIMING apply begin")
        let applied = display.apply(newSettings)
        Log.info("TIMING apply end")
        guard applied else {
            Log.info("virtual display \(display.displayID) applySettings FAILED during resize")
            return false
        }
        settings = newSettings
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh
        self.scale = scale
        // A new mode gets a fresh chance: refusals belonged to the old size.
        hidpiRefusals = 0
        hidpiRetryAfter = .distantPast

        if let origin {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success {
                CGConfigureDisplayOrigin(config, display.displayID, Int32(origin.x), Int32(origin.y))
                Log.info("TIMING origin begin")
                let err = CGCompleteDisplayConfiguration(config, .permanently)
                Log.info("TIMING origin end")
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
                Log.info("virtual display \(display.displayID) resized to \(pointsWide)x\(pointsHigh)pt @\(scale)x "
                    + "at (\(Int(origin.x)),\(Int(origin.y))), settled "
                    + "(\(Int(settled.x)),\(Int(settled.y))) (result \(err.rawValue))")
            }
        } else {
            Log.info("virtual display \(display.displayID) resized to \(pointsWide)x\(pointsHigh)pt @\(scale)x")
        }
        return true
    }

    /// Returns true when the display is (now) in its mode at `scale` (HiDPI
    /// for a 2x display, the 1x mode otherwise), or when there
    /// is nothing left to try for now. Silent when nothing needed doing — this
    /// runs every 2s as enforcement. With `recover`, a missing @2x mode (macOS
    /// can replace the whole mode list when it restores saved display state)
    /// re-applies our settings to publish it again instead of failing silently
    /// forever.
    ///
    /// macOS lists but refuses some small @2x modes (a 750×1334 phone panel
    /// asks for 374×666pt and gets kCGErrorFailure every time; the display
    /// then runs at 1x). Without a back-off the 200ms settling loop would
    /// issue a failing permanent reconfiguration five times a second for the
    /// whole session and flood the log, which is what happened before this
    /// counter existed. After a few refusals we report it once, let the loop
    /// settle, and probe again only occasionally in case the mode list changes.
    @discardableResult
    private func selectTargetMode(recover: Bool = false) -> Bool {
        guard Date() >= hidpiRetryAfter else { return true }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display.displayID, opts) as? [CGDisplayMode],
              let hidpi = modes.first(where: {
                  // Width AND height: a stale saved mode can share one axis.
                  $0.width == pointsWide && $0.height == pointsHigh
                      && $0.pixelWidth == pointsWide * scale
                      && $0.pixelHeight == pointsHigh * scale
              }) else {
            if recover {
                // Same back-off as a refusal: a mode list that stays without
                // our @2x entry would otherwise be re-applied and logged every
                // 2s for as long as the display lives.
                hidpiRefusals += 1
                if hidpiRefusals <= Self.hidpiRefusalsBeforeBackoff {
                    Log.info("@\(scale)x mode vanished from display \(display.displayID) — re-applying settings"
                        + (hidpiRefusals == Self.hidpiRefusalsBeforeBackoff
                           ? " (probing again every \(Int(Self.hidpiRetryInterval))s from now)" : ""))
                }
                _ = display.apply(settings)
                if hidpiRefusals == Self.hidpiRefusalsBeforeBackoff { reportRefusal() }
                if hidpiRefusals >= Self.hidpiRefusalsBeforeBackoff {
                    hidpiRetryAfter = Date().addingTimeInterval(Self.hidpiRetryInterval)
                    return true
                }
            }
            return false
        }
        if let current = CGDisplayCopyDisplayMode(display.displayID),
           current.width == hidpi.width, current.height == hidpi.height,
           current.pixelWidth == hidpi.pixelWidth, current.pixelHeight == hidpi.pixelHeight {
            hidpiRefusals = 0   // WindowServer may have restored it for us
            return true
        }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, display.displayID, hidpi, nil)
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        if err == .success {
            hidpiRefusals = 0
            Log.info("display mode (re)selected: \(hidpi.width)x\(hidpi.height)@\(scale)x (result 0)")
            return true
        }
        hidpiRefusals += 1
        if hidpiRefusals < Self.hidpiRefusalsBeforeBackoff {
            Log.info("display mode (re)selected: \(hidpi.width)x\(hidpi.height)@\(scale)x (result \(err.rawValue))")
            return false
        }
        if hidpiRefusals == Self.hidpiRefusalsBeforeBackoff {
            Log.info("macOS refused the @\(scale)x mode \(hidpi.width)x\(hidpi.height) "
                + "\(hidpiRefusals) times (result \(err.rawValue)) — leaving display "
                + "\(display.displayID) in its current mode, probing again every \(Int(Self.hidpiRetryInterval))s")
            reportRefusal()
        }
        hidpiRetryAfter = Date().addingTimeInterval(Self.hidpiRetryInterval)
        return true
    }

    private func reportRefusal() {
        guard scale == 2 else { return }
        onModeRefused?(VirtualCanvasSize(pointsWide: pointsWide, pointsHigh: pointsHigh, scale: scale))
    }

    /// Consecutive `CGCompleteDisplayConfiguration` failures for the target mode.
    private var hidpiRefusals = 0
    /// While in the future, `selectTargetMode` does nothing and reports settled.
    private var hidpiRetryAfter = Date.distantPast
    private static let hidpiRefusalsBeforeBackoff = 5
    private static let hidpiRetryInterval: TimeInterval = 30

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
