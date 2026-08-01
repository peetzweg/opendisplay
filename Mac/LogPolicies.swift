import Foundation

struct UnknownControlTypeLogPolicy {
    enum Action: Equatable {
        case logType(String)
        case logSuppression(limit: Int)
        case none
    }

    private let capacity: Int
    private var loggedTypes: Set<String> = []
    private var reportedSuppression = false

    init(capacity: Int = 16) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func record(_ type: String) -> Action {
        if loggedTypes.contains(type) { return .none }
        guard loggedTypes.count < capacity else {
            guard !reportedSuppression else { return .none }
            reportedSuppression = true
            return .logSuppression(limit: capacity)
        }
        loggedTypes.insert(type)
        return .logType(type)
    }
}

/// Rate-limits a log line that a broken peer or a dead pipeline can trigger on
/// every frame or every message. The first occurrence reports immediately, then
/// at most one report per `interval` carrying how many occurrences it stands for
/// and the detail from the most recent one.
///
/// `Detail` is whatever identifies the occurrence: an `OSStatus` for an encoder
/// failure, a byte count for a message that would not parse. The policy is a
/// pure value type and never schedules anything itself; it returns `.schedule`
/// and the caller owns the timer, which keeps it testable without waiting on
/// real time.
struct ThrottledLogPolicy<Detail: Equatable> {
    struct Report: Equatable {
        let detail: Detail
        let count: Int
    }

    enum Action: Equatable {
        case report(Report)
        case schedule(after: TimeInterval)
        case none
    }

    private let interval: TimeInterval
    private var lastReportAt: TimeInterval?
    private var pending: Report?
    private var reportScheduled = false

    init(interval: TimeInterval = 1) {
        precondition(interval > 0)
        self.interval = interval
    }

    mutating func record(_ detail: Detail, at time: TimeInterval) -> Action {
        let report = Report(detail: detail, count: (pending?.count ?? 0) + 1)
        pending = report

        guard let lastReportAt else {
            return .report(take(report, at: time))
        }
        if !reportScheduled, time - lastReportAt >= interval {
            return .report(take(report, at: time))
        }
        // A flush is already queued for the end of this window; it will carry
        // everything recorded since, so there is nothing to ask of the caller.
        guard !reportScheduled else { return .none }
        reportScheduled = true
        return .schedule(after: max(0, lastReportAt + interval - time))
    }

    /// Reports whatever accumulated since the last report, for the caller's
    /// scheduled flush. Nil when a report already drained the window.
    mutating func flush(at time: TimeInterval) -> Report? {
        reportScheduled = false
        guard let pending else { return nil }
        return take(pending, at: time)
    }

    private mutating func take(_ report: Report, at time: TimeInterval) -> Report {
        pending = nil
        lastReportAt = time
        return report
    }
}
