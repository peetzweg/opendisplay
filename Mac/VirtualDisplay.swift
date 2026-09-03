import Foundation
import CoreGraphics

/// Scaled HiDPI mode steps offered in System Settings → Displays (the
/// "More Space" / "Larger Text" equivalents). Index 0 is native @2x; the rest
/// are progressively downscaled point sizes, each still backed by a @2x
/// framebuffer so text stays sharp. Publishing several lets the user pick a
/// resolution that actually sticks (issue #9) instead of being forced back to
/// the single native mode.
let resolutionSteps: [CGFloat] = [1.0, 0.85, 0.75, 0.67]

/// Build the mode list for a virtual display of the given point size.
/// - Returns: resolutionSteps.count modes, native first. Pure (no I/O) so it is
///   unit-testable without a real display.
func buildDisplayModes(pointsWide: Int, pointsHigh: Int) -> [CGVirtualDisplayMode] {
    resolutionSteps.map { s in
        CGVirtualDisplayMode(
            width: UInt((CGFloat(pointsWide) * s).rounded(.toNearestOrEven)),
            height: UInt((CGFloat(pointsHigh) * s).rounded(.toNearestOrEven)),
            refreshRate: 60
        )
    }
}

/// Decision for the lifetime mode-enforcement loop. The loop exists to undo
/// macOS asynchronously restoring a *stale* saved mode (issue #26) — which
/// shows up as a 1x/blurry relapse or a wrong-orientation mode pillarboxing
/// the framebuffer (issue #29). But a user picking a scaled mode we published
/// must be LEFT ALONE (#9). So we discriminate:
///   - current is one of our published modes  → leave it (user choice stands)
///   - current is NOT published AND not settled → re-assert (startup race)
///   - current is NOT published AND settled    → only after it has been missing
///     for `missingTicks` consecutive ticks (issue #29 fix-plan point 2: debounce
///     so transient wipes during a neighbor's reconfiguration heal on their own).
/// Pure + testable. `missingTicks` is the running count of consecutive ticks
/// where the @2x mode was absent.
func shouldReassertMode(currentWidth: Int, currentPixelWidth: Int,
                         published: [CGVirtualDisplayMode],
                         targetStep: Int = 0,
                         settled: Bool, missingTicks: Int) -> Bool {
    let publishedIndex = published.firstIndex {
        $0.width == UInt(currentWidth) && $0.width * 2 == UInt(currentPixelWidth)
    }
    if !settled {
        let targetIndex = published.indices.contains(targetStep) ? targetStep : 0
        return publishedIndex != targetIndex
    }
    if publishedIndex != nil { return false }            // #9: user choice stands
    return missingTicks >= 3                   // #29: debounced recovery only
}

/// Per-device resolution memory (issue #9 "persist per device"). Keyed by the
/// same install-id used for arrangement (#116) so each physical device keeps
/// its chosen mode across sessions and transports. Stores the chosen step index.
enum ResolutionStore {
    private static func key(for device: String) -> String { "resolution.\(device)" }

    static func save(step: Int, device: String) {
        UserDefaults.standard.set(step, forKey: key(for: device))
    }
    static func load(device: String) -> Int? {
        guard UserDefaults.standard.object(forKey: key(for: device)) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: key(for: device))
    }
}

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
    private let deviceKey: String?
    /// Running count of consecutive enforcement ticks where the @2x mode was
    /// absent. Drives the debounced recovery (issue #29 fix-plan point 2).
    private var missingTicks = 0

    var displayID: CGDirectDisplayID { display.displayID }

    /// Must be called on the main thread. `serialNum` must be unique per
    /// concurrent display AND stable per device — macOS keys saved display
    /// arrangement on vendor/product/serial, so a stable serial means each
    /// device keeps its position in System Settings across sessions.
    /// `restoreOrigin` overrides that saved arrangement (see manageOrigin);
    /// `onOriginChange` reports where the display sits afterwards, so the
    /// caller can persist user drags.
    /// `deviceKey` (install id, per #116/#26) keys per-device resolution memory
    /// so a chosen scaled mode is reapplied and persisted (issue #9).
    init?(name: String, pointsWide: Int, pointsHigh: Int, sizeInMillimeters: CGSize,
          serialNum: UInt32 = 0x0001, productID: UInt32 = 0x4F53,
          restoreOrigin: CGPoint? = nil,
          onOriginChange: ((CGPoint, CGSize) -> Void)? = nil,
          deviceKey: String? = nil) {
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh
        // Reserve the longer orientation on both axes. That lets a phone or
        // tablet change orientation by applying a new mode to this *same*
        // virtual monitor instead of removing it and stranding its windows.
        maxPointsPerAxis = max(pointsWide, pointsHigh)
        self.restoreTarget = restoreOrigin
        self.restoreUntil = restoreOrigin == nil ? .distantPast : Date().addingTimeInterval(6)
        self.onOriginChange = onOriginChange
        self.deviceKey = deviceKey

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
        // Publish every scaled HiDPI step (issue #9) so the user can pick a
        // resolution in System Settings → Displays that actually sticks.
        settings.modes = buildDisplayModes(pointsWide: pointsWide, pointsHigh: pointsHigh)
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
        // not a one-shot. BUT a user picking a scaled mode we published must
        // stick (issue #9), while macOS's async 1x/wrong-orientation relapses
        // (issue #26/#29) must still be undone. `shouldReassertMode` is the
        // discriminator; recovery is debounced so transient wipes during a
        // neighbor's reconfiguration heal on their own (issue #29 point 2).
        Task { @MainActor [weak self] in
            var settled = false
            while true {
                // Scoped strong ref: a rotation rebuild relies on release
                // removing the display — never hold it across the sleep.
                do {
                    guard let self else { return }
                    self.ensureNotMirrored()
                    if self.enforceMode(settled: settled) { settled = true }
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
        newSettings.modes = buildDisplayModes(pointsWide: pointsWide, pointsHigh: pointsHigh)
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
    @discardableResult
    private func enforceMode(settled: Bool) -> Bool {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let runtimeModes = CGDisplayCopyAllDisplayModes(display.displayID, opts) as? [CGDisplayMode] else {
            // Whole mode list gone — republish (mirrors old `recover` path).
            Log.info("@2x modes vanished from display \(display.displayID) — re-applying settings")
            _ = display.apply(settings)
            missingTicks += 1
            return false
        }
        guard let current = CGDisplayCopyDisplayMode(display.displayID) else { return false }

        let targetStep = deviceKey.flatMap { ResolutionStore.load(device: $0) } ?? 0

        let currentPublishedIndex = settings.modes.firstIndex(where: {
            $0.width == current.width && $0.width * 2 == current.pixelWidth
        })

        if let idx = currentPublishedIndex {
            missingTicks = 0
            if let key = deviceKey {
                ResolutionStore.save(step: idx, device: key)
            }
        } else {
            missingTicks += 1
        }

        let reassert = shouldReassertMode(
            currentWidth: Int(current.width),
            currentPixelWidth: Int(current.pixelWidth),
            published: settings.modes,
            targetStep: targetStep,
            settled: settled,
            missingTicks: missingTicks
        )

        if !reassert {
            return true
        }

        // Find the runtime CGDisplayMode to restore to: prefer the persisted
        // per-device choice (if still offered), else native @2x.
        let step = settings.modes.indices.contains(targetStep) ? targetStep : 0
        let targetDescriptor = settings.modes[step]
        guard let target = runtimeModes.first(where: {
            $0.width == targetDescriptor.width && $0.pixelWidth == targetDescriptor.width * 2
        }) else {
            Log.info("mode re-assert target \(targetDescriptor.width)x\(targetDescriptor.height) not in runtime list — republishing")
            _ = display.apply(settings)
            return false
        }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, display.displayID, target, nil)
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        if err == .success {
            missingTicks = 0
        }
        Log.info("mode re-asserted to \(target.width)x\(target.height) (result \(err.rawValue))")
        return err == .success
    }

    /// Legacy alias retained for callers/tests that referenced the old name.
    @discardableResult
    private func selectHiDPIMode(recover: Bool = false) -> Bool { enforceMode(settled: recover) }

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
