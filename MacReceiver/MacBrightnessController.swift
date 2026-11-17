import CoreGraphics
import Darwin
import Foundation

/// Controls display brightness on the receiving Mac (MacReceiver) via DisplayServices.
enum MacBrightnessController {
    private typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )

    private static let getBrightness: GetBrightnessFunc? = {
        guard let handle, let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetBrightnessFunc.self)
    }()

    private static let setBrightness: SetBrightnessFunc? = {
        guard let handle, let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(sym, to: SetBrightnessFunc.self)
    }()

    private static var lastApplied: (displayID: CGDirectDisplayID, value: Float, time: TimeInterval)?

    /// Applies a relative brightness delta (-1.0 ... 1.0) and returns the updated brightness value.
    @MainActor
    @discardableResult
    static func applyDelta(_ delta: Float, on displayID: CGDirectDisplayID) -> Float? {
        guard let getBrightness, let setBrightness else { return nil }

        var readValue: Float = 0.5
        guard getBrightness(displayID, &readValue) == 0 else { return nil }

        let now = ProcessInfo.processInfo.systemUptime
        let current: Float
        if let last = lastApplied,
           last.displayID == displayID,
           (now - last.time) < 0.5,
           abs(readValue - last.value) > 0.005 {
            current = last.value
        } else {
            current = readValue
        }

        let next = min(max(current + delta, 0.0), 1.0)

        guard setBrightness(displayID, next) == 0 else { return nil }
        lastApplied = (displayID, next, now)
        return next
    }
}

