// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import os

private let rpcPerformanceLog = Logger(
    subsystem: "com.deviceterm",
    category: "rpc-performance"
)

/// Local unified-log timing for GUI RPC attempts.
/// Every request logs at debug level; slow replies and timeouts are also logged
/// at persisted levels. Periodic aggregates contain no request identity.
@MainActor
final class RPCPerformanceDiagnostics {
    private let clock: @MainActor () -> UInt64
    private let summaryIntervalNanoseconds: UInt64
    private var lastSummaryNanoseconds: UInt64
    private var buckets: [RPCPerformanceKey: RPCPerformanceBucket] = [:]
    private var summaryTask: Task<Void, Never>?

    init(
        summaryIntervalNanoseconds: UInt64 = 30_000_000_000,
        automaticallyEmitSummaries: Bool = true,
        clock: @escaping @MainActor () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.clock = clock
        self.summaryIntervalNanoseconds = summaryIntervalNanoseconds
        self.lastSummaryNanoseconds = clock()
        if automaticallyEmitSummaries {
            summaryTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let remaining = self?.nanosecondsUntilSummary() else {
                        return
                    }
                    do {
                        try await Task.sleep(nanoseconds: remaining)
                    } catch {
                        return
                    }
                    if let diagnostics = self {
                        diagnostics.emitSummaryIfDue(now: diagnostics.clock())
                    }
                }
            }
        }
    }

    isolated deinit { summaryTask?.cancel() }

    func now() -> UInt64 { clock() }

    func record(
        method: RPCMethod,
        lane: XPCClientLane,
        startedAtNanoseconds: UInt64,
        outcome: RPCPerformanceOutcome,
        severeDelayNanoseconds: UInt64
    ) {
        let finishedAt = clock()
        // Close the previous window before adding this request. A request
        // arriving after an idle period belongs to the new window, not the
        // stale bucket the timer should already have flushed.
        emitSummaryIfDue(now: finishedAt)
        let elapsedNanoseconds = finishedAt >= startedAtNanoseconds
            ? finishedAt - startedAtNanoseconds
            : 0
        let elapsedMilliseconds = elapsedNanoseconds / 1_000_000
        let key = RPCPerformanceKey(lane: lane, method: method)
        var bucket = buckets[key] ?? RPCPerformanceBucket()
        bucket.calls += 1
        bucket.totalMilliseconds += elapsedMilliseconds
        bucket.maximumMilliseconds = max(bucket.maximumMilliseconds, elapsedMilliseconds)
        switch outcome {
        case .reply:
            bucket.replies += 1

        case .replyError:
            bucket.replies += 1
            bucket.failures += 1

        case .timeout:
            bucket.timeouts += 1

        case .transport, .cancelled, .localFailure:
            bucket.failures += 1
        }
        buckets[key] = bucket

        rpcPerformanceLog.debug(
            """
            rpc attempt lane=\(lane.rawValue, privacy: .public) \
            method=\(method.rawValue, privacy: .public) \
            outcome=\(outcome.rawValue, privacy: .public) \
            elapsedMs=\(elapsedMilliseconds, privacy: .public)
            """
        )
        if outcome == .timeout {
            rpcPerformanceLog.error(
                """
                rpc timeout lane=\(lane.rawValue, privacy: .public) \
                method=\(method.rawValue, privacy: .public) \
                elapsedMs=\(elapsedMilliseconds, privacy: .public)
                """
            )
        } else if outcome == .reply || outcome == .replyError,
            elapsedNanoseconds >= severeDelayNanoseconds {
            rpcPerformanceLog.notice(
                """
                rpc slow reply lane=\(lane.rawValue, privacy: .public) \
                method=\(method.rawValue, privacy: .public) \
                elapsedMs=\(elapsedMilliseconds, privacy: .public)
                """
            )
        }
    }

    func record(
        method: RPCMethod,
        lane: XPCClientLane,
        startedAtNanoseconds: UInt64,
        error: (any Error)?,
        severeDelayNanoseconds: UInt64
    ) {
        let outcome: RPCPerformanceOutcome
        switch error {
        case nil:
            outcome = .reply

        case is CancellationError:
            outcome = .cancelled

        case let error as DaemonClientError:
            switch error {
            case .timedOut, .shutdownTimedOut:
                outcome = .timeout

            case .transport:
                outcome = .transport

            case .daemon, .decode, .versionMismatch, .shutdownNotAcknowledged:
                outcome = .replyError
            }

        default:
            outcome = .localFailure
        }
        record(
            method: method,
            lane: lane,
            startedAtNanoseconds: startedAtNanoseconds,
            outcome: outcome,
            severeDelayNanoseconds: severeDelayNanoseconds
        )
    }

    func bucketsForTesting() -> [String: RPCPerformanceBucket] {
        Dictionary(uniqueKeysWithValues: buckets.map { key, value in
            ("\(key.lane.rawValue):\(key.method.rawValue)", value)
        })
    }

    /// Test seam for driving the same flush the periodic task performs.
    func emitSummaryForTesting() {
        emitSummaryIfDue(now: clock())
    }

    private func nanosecondsUntilSummary() -> UInt64 {
        let now = clock()
        let elapsed = now >= lastSummaryNanoseconds ? now - lastSummaryNanoseconds : 0
        return elapsed >= summaryIntervalNanoseconds
            ? 0
            : summaryIntervalNanoseconds - elapsed
    }

    private func emitSummaryIfDue(now: UInt64) {
        let elapsed = now >= lastSummaryNanoseconds ? now - lastSummaryNanoseconds : 0
        guard elapsed >= summaryIntervalNanoseconds else { return }
        for (key, bucket) in buckets {
            let average = bucket.calls > 0
                ? bucket.totalMilliseconds / UInt64(bucket.calls)
                : 0
            rpcPerformanceLog.notice(
                """
                rpc summary lane=\(key.lane.rawValue, privacy: .public) \
                method=\(key.method.rawValue, privacy: .public) \
                calls=\(bucket.calls, privacy: .public) \
                replies=\(bucket.replies, privacy: .public) \
                timeouts=\(bucket.timeouts, privacy: .public) \
                failures=\(bucket.failures, privacy: .public) \
                averageMs=\(average, privacy: .public) \
                maximumMs=\(bucket.maximumMilliseconds, privacy: .public)
                """
            )
        }
        buckets.removeAll(keepingCapacity: true)
        lastSummaryNanoseconds = now
    }
}

private extension RPCPerformanceDiagnostics {
    struct RPCPerformanceKey: Hashable {
        let lane: XPCClientLane
        let method: RPCMethod
    }
}
