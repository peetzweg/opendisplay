import Dispatch
import os

// Stand-ins for what the sender would otherwise need macOS 13 or Swift 5.9 for.

/// `OSAllocatedUnfairLock` for macOS 12.3: the same `init(initialState:)` and
/// `withLock`, over an `os_unfair_lock` of its own.
final class UnfairLock<State>: @unchecked Sendable {
    private var state: State
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init(initialState: State) {
        state = initialState
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return try body(&state)
    }
}

/// `MainActor.assumeIsolated` for Swift 5.8: runs `body` synchronously, for a
/// callback that is known to arrive on the main queue.
func assumeMainActor(_ body: @MainActor () -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    withoutActuallyEscaping(body) { body in
        unsafeBitCast(body, to: (() -> Void).self)()
    }
}
