import XCTest

final class UnknownControlTypeLogPolicyTests: XCTestCase {
    func testLogsEachTypeOnlyOnce() {
        var policy = UnknownControlTypeLogPolicy(capacity: 2)

        XCTAssertEqual(policy.record("pencil"), .logType("pencil"))
        XCTAssertEqual(policy.record("pencil"), .none)
        XCTAssertEqual(policy.record("proximity"), .logType("proximity"))
    }

    func testReportsCapacityOnceInsteadOfSilentlyDroppingLaterTypes() {
        var policy = UnknownControlTypeLogPolicy(capacity: 2)
        _ = policy.record("first")
        _ = policy.record("second")

        XCTAssertEqual(policy.record("third"), .logSuppression(limit: 2))
        XCTAssertEqual(policy.record("fourth"), .none)
    }
}

final class ThrottledLogPolicyTests: XCTestCase {
    func testFlushReportsFailuresSuppressedAtTheEndOfABurst() {
        var policy = ThrottledLogPolicy<Int32>(interval: 1)

        XCTAssertEqual(policy.record(-1, at: 10),
                       .report(.init(detail: -1, count: 1)))
        XCTAssertEqual(policy.record(-1, at: 10.25), .schedule(after: 0.75))
        XCTAssertEqual(policy.record(-2, at: 10.5), .none)
        XCTAssertEqual(policy.flush(at: 11), .init(detail: -2, count: 2))
        XCTAssertNil(policy.flush(at: 12))
    }

    func testReportsImmediatelyAgainAfterAnIdleInterval() {
        var policy = ThrottledLogPolicy<Int32>(interval: 1)
        _ = policy.record(-1, at: 10)

        XCTAssertEqual(policy.record(-2, at: 11),
                       .report(.init(detail: -2, count: 1)))
    }

    // The desync case: garbage keeps arriving at the peer's message rate, so a
    // second burst after a flush has to throttle exactly like the first.
    func testThrottlesASecondBurstAfterFlushing() {
        var policy = ThrottledLogPolicy<Int>(interval: 1)

        XCTAssertEqual(policy.record(64, at: 10), .report(.init(detail: 64, count: 1)))
        assertSchedules(policy.record(64, at: 10.1), after: 0.9)
        XCTAssertEqual(policy.flush(at: 11), .init(detail: 64, count: 1))

        assertSchedules(policy.record(72, at: 11.2), after: 0.8)
        XCTAssertEqual(policy.record(80, at: 11.5), .none)
        XCTAssertEqual(policy.flush(at: 12), .init(detail: 80, count: 2))
    }

    // The delay is arithmetic on the caller's clock, so compare it with a
    // tolerance rather than for binary equality.
    private func assertSchedules<Detail: Equatable>(
        _ action: ThrottledLogPolicy<Detail>.Action,
        after expected: TimeInterval,
        line: UInt = #line
    ) {
        guard case .schedule(let delay) = action else {
            return XCTFail("expected a scheduled flush, got \(action)", line: line)
        }
        XCTAssertEqual(delay, expected, accuracy: 0.000_001, line: line)
    }
}
