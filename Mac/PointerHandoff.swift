import CoreGraphics
import Foundation

/// Touch mode: a touch borrows the pointer and gives it back.
///
/// macOS clicks wherever the pointer is, so a touch has to move it. On a
/// touchscreen that is plumbing, not something to see or to clean up after:
/// the first touch remembers where the pointer was ("home"), the receiver
/// stops drawing it while a touch owns it, and the next movement of a real
/// mouse or trackpad puts it back home, carrying that movement along.
///
/// One instance serves every session: home is where the user's mouse was,
/// however many devices were touched in between. Touch calls arrive on the
/// sender queues and pointer samples on the cursor queues, hence the lock.
final class PointerHandoff: @unchecked Sendable {
    static let defaultsKey = "returnPointerAfterTouch"

    static let shared = PointerHandoff(
        enabled: UserDefaults.standard.object(forKey: defaultsKey) == nil
            || UserDefaults.standard.bool(forKey: defaultsKey))

    /// How long after a touch event the pointer still counts as the touch's.
    /// The poll can read the location before a just-posted event lands, and
    /// that lag must not look like the user grabbing the mouse.
    static let settle: TimeInterval = 0.15
    /// Movement (in points) away from the last touch point that counts as the
    /// user moving the mouse rather than rounding noise.
    static let movementThreshold: CGFloat = 0.5

    private let lock = NSLock()
    private var isEnabled: Bool
    private var home: CGPoint?
    private var touchPoint = CGPoint.zero
    private var lastTouch: TimeInterval = 0
    private var holding = false

    private let now: () -> TimeInterval
    private let warp: (CGPoint) -> Void

    init(enabled: Bool,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         warp: @escaping (CGPoint) -> Void = { PointerHandoff.warpPointer(to: $0) }) {
        isEnabled = enabled
        self.now = now
        self.warp = warp
    }

    var enabled: Bool {
        get { lock.withLock { isEnabled } }
        set {
            lock.withLock {
                isEnabled = newValue
                if !newValue { home = nil }
            }
        }
    }

    /// True while a touch, not the user's mouse, put the pointer where it is.
    /// Receivers hide the pointer then: a touchscreen shows no cursor.
    var touchOwnsPointer: Bool {
        lock.withLock { isEnabled && home != nil }
    }

    /// Called just before a touch event moves the pointer from `pointer` to
    /// `point`. `holding` is whether a finger stays down after this event.
    func touchMovesPointer(to point: CGPoint, from pointer: CGPoint, holding: Bool) {
        lock.withLock {
            guard isEnabled else { return }
            if home == nil { home = pointer }
            touchPoint = point
            lastTouch = now()
            self.holding = holding
        }
    }

    /// Feed every pointer sample. When the pointer moved away from where the
    /// touch left it, the user is using the mouse again: send the pointer
    /// home, keeping the distance they already moved it.
    func pointerSampled(at location: CGPoint) {
        let target: CGPoint? = lock.withLock {
            guard isEnabled, let homePoint = home, !holding,
                  now() - lastTouch >= Self.settle else { return nil }
            let dx = location.x - touchPoint.x
            let dy = location.y - touchPoint.y
            guard hypot(dx, dy) > Self.movementThreshold else { return nil }
            home = nil
            return CGPoint(x: homePoint.x + dx, y: homePoint.y + dy)
        }
        if let target { warp(target) }
    }

    /// Give the pointer back now, e.g. when the session that borrowed it ends
    /// and its display is about to disappear from under it.
    func returnPointer() {
        let target: CGPoint? = lock.withLock {
            defer { home = nil; holding = false }
            return isEnabled ? home : nil
        }
        if let target { warp(target) }
    }

    static func warpPointer(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // A warp otherwise freezes the hardware pointer for ~0.25s, which reads
        // as the mouse stalling right as the user reaches for it.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
