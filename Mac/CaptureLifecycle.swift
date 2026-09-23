import Foundation

enum CaptureMode: String {
    case mirror
    case extend
}

enum CaptureLifecyclePhase: String, Equatable {
    case running
    case pausing
    case paused
    case resuming
    case recovering
    case stopped
}

struct CaptureLifecycleState: Equatable {
    private(set) var phase: CaptureLifecyclePhase = .recovering
    private(set) var receiverDisplayState = DisplayState.running

    var allowsInput: Bool {
        phase == .running || phase == .recovering
    }

    var ownsCaptureStop: Bool {
        phase == .pausing || phase == .paused || phase == .resuming || phase == .stopped
    }

    var shouldRetryCapture: Bool {
        phase == .recovering || phase == .resuming
    }

    mutating func requestPause() -> Bool {
        guard phase == .running || phase == .recovering else { return false }
        phase = .pausing
        receiverDisplayState = .paused
        return true
    }

    mutating func pauseCompleted() -> Bool {
        guard phase == .pausing else { return false }
        phase = .paused
        return true
    }

    mutating func requestResume() -> Bool {
        guard phase == .paused else { return false }
        phase = .resuming
        return true
    }

    mutating func resumeStopFailed() -> Bool {
        guard phase == .resuming else { return false }
        phase = .paused
        return true
    }

    mutating func unexpectedStop() -> Bool {
        switch phase {
        case .running:
            phase = .recovering
            return true
        case .resuming:
            return true
        default:
            return false
        }
    }

    mutating func recoveryFailed() -> Bool {
        guard phase == .recovering else { return false }
        phase = .stopped
        return true
    }

    mutating func resumeFailed() -> Bool {
        guard phase == .resuming else { return false }
        phase = .paused
        return true
    }

    mutating func captureStarted() -> Bool {
        guard phase != .pausing, phase != .paused, phase != .stopped else { return false }
        phase = .running
        receiverDisplayState = .running
        return true
    }

    mutating func stop() {
        phase = .stopped
    }
}

struct CaptureRecoveryBudget {
    let maximumAttempts: Int
    private(set) var failedAttempts = 0

    init(maximumAttempts: Int = 5) {
        self.maximumAttempts = maximumAttempts
    }

    mutating func recordFailure() -> Bool {
        failedAttempts += 1
        return failedAttempts < maximumAttempts
    }

    mutating func reset() {
        failedAttempts = 0
    }
}

enum CaptureRecoveryPath: Equatable {
    case reattachMirrorCapture
    case rebuildMirrorPipeline
    case reattachExtendCapture
    case rebuildExtendPipeline

    static func resolve(mode: CaptureMode, targetDisplayAvailable: Bool) -> Self {
        switch (mode, targetDisplayAvailable) {
        case (.mirror, true): return .reattachMirrorCapture
        case (.mirror, false): return .rebuildMirrorPipeline
        case (.extend, true): return .reattachExtendCapture
        case (.extend, false): return .rebuildExtendPipeline
        }
    }
}
