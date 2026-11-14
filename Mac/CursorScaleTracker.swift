import AppKit
import Foundation

final class CursorScaleTracker {
    // Shake detection parameters
    private let minSpeed: CGFloat = 250.0            // Minimum movement speed (points/sec)
    private let reversalTimeout: TimeInterval = 0.4  // Max time window between direction reversals
    private let requiredReversals: Int = 3           // Number of consecutive reversals to trigger zoom
    private let holdDuration: TimeInterval = 0.5     // Duration to keep the cursor enlarged after shaking stops
    
    // Smooth interpolation parameters
    private let zoomInSpeed: CGFloat = 14.0
    private let zoomOutSpeed: CGFloat = 6.0
    private let maxScale: CGFloat = 4.0
    
    // Internal state
    private var lastPosition: CGPoint?
    private var lastTimestamp: TimeInterval?
    private var lastVelocityVector: CGVector?
    private var reversalCount: Int = 0
    private var lastReversalTime: TimeInterval = 0
    private var shakeActiveUntil: TimeInterval = 0
    private var wasShaking: Bool = false

    private var currentScale: CGFloat
    
    init() {
        self.currentScale = Self.readAccessibilityScaleFromDefaults()
    }
    
    /// Evaluates current global mouse location and returns the effective scale factor (1.0 to 4.0).
    /// Must be called on the main thread (NSEvent.mouseLocation + mutable state).
    func update(timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CGFloat {
        assert(Thread.isMainThread, "CursorScaleTracker.update() must be called on the main thread")

        let position = NSEvent.mouseLocation
        let baseScale = Self.cachedAccessibilityScale(timestamp: timestamp)

        guard let prevPos = lastPosition, let prevTime = lastTimestamp else {
            lastPosition = position
            lastTimestamp = timestamp
            currentScale = baseScale
            return currentScale
        }

        let dt = timestamp - prevTime
        guard dt > 0 else { return currentScale }

        let dx = position.x - prevPos.x
        let dy = position.y - prevPos.y
        let distance = hypot(dx, dy)

        if distance > 0.5 {
            let speed = distance / CGFloat(dt)

            if speed >= minSpeed {
                let currentVector = CGVector(dx: dx / distance, dy: dy / distance)

                if timestamp - lastReversalTime > reversalTimeout {
                    reversalCount = 0
                    lastVelocityVector = nil
                }

                if let prevVector = lastVelocityVector {
                    let dotProduct = prevVector.dx * currentVector.dx + prevVector.dy * currentVector.dy

                    if dotProduct < -0.5 {
                        reversalCount += 1
                        lastReversalTime = timestamp
                        lastVelocityVector = currentVector

                        // Set shakeActiveUntil only on first trigger; otherwise subsequent small
                        // movements would keep extending the zoom and the cursor would not decay
                        // back to baseScale after the shake.
                        if reversalCount >= requiredReversals && timestamp > shakeActiveUntil {
                            shakeActiveUntil = timestamp + holdDuration
                        }
                    }
                } else {
                    lastVelocityVector = currentVector
                    lastReversalTime = timestamp
                }
            }
        }

        lastPosition = position
        lastTimestamp = timestamp

        let isShaking = timestamp <= shakeActiveUntil

        // If shake just ended, reset scale to baseScale immediately instead of
        // waiting for slow exponential interpolation. Otherwise the cursor stays
        // slightly larger than its original size after the shake decays.
        if wasShaking && !isShaking {
            currentScale = baseScale
        }
        wasShaking = isShaking

        let targetScale = isShaking ? max(baseScale, maxScale) : baseScale

        let interpSpeed = targetScale > currentScale ? zoomInSpeed : zoomOutSpeed
        let factor = min(1.0, CGFloat(dt) * interpSpeed)
        currentScale += (targetScale - currentScale) * factor

        // Interpolation is exponential — currentScale never reaches targetScale
        // exactly. Snap to it when the remainder is invisible.
        if abs(currentScale - targetScale) < 0.01 {
            currentScale = targetScale
        }

        return currentScale
    }

    /// Reads the system cursor size from Accessibility settings, cached for up to 1 second
    /// to avoid repeatedly parsing the whole UserDefaults domain on every 30 Hz tick.
    private static func cachedAccessibilityScale(timestamp: TimeInterval) -> CGFloat {
        if timestamp - _accessibilityScaleLastRead < 1.0 {
            return _accessibilityScaleCached
        }
        _accessibilityScaleCached = readAccessibilityScaleFromDefaults()
        _accessibilityScaleLastRead = timestamp
        return _accessibilityScaleCached
    }

    static func readAccessibilityScaleFromDefaults() -> CGFloat {
        let defaults = UserDefaults.standard.persistentDomain(forName: "com.apple.universalaccess")
        return (defaults?["mouseDriverCursorSize"] as? NSNumber)?.doubleValue ?? 1.0
    }

    private static var _accessibilityScaleCached: CGFloat = 1.0
    private static var _accessibilityScaleLastRead: TimeInterval = 0
}
