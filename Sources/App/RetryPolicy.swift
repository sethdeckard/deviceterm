// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A retry schedule: attempt number in, delay out.
///
/// Doubling from `initialDelayNanoseconds`, saturating at
/// `maximumDelayNanoseconds`. Unjittered, matching the other backoff loops in
/// the app: each of these retries belongs to one pane or one connection, so
/// there is no fleet of clients to spread out and nothing to decorrelate.
///
/// A pure value holding no attempt count of its own, because what resets the
/// count differs at every site: a delivered event, a mounted pane, expired
/// resurrection history. The caller owns the counter and asks for the delay.
struct RetryPolicy: Equatable, Sendable {
    let initialDelayNanoseconds: UInt64
    let maximumDelayNanoseconds: UInt64

    /// The delay before retry number `attempt`, counting the first retry as
    /// attempt 0. Negative attempts clamp to that first delay.
    func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        var delay = min(initialDelayNanoseconds, maximumDelayNanoseconds)
        guard attempt > 0, delay > 0 else { return delay }
        for _ in 0 ..< attempt {
            let (doubled, overflowed) = delay.multipliedReportingOverflow(by: 2)
            if overflowed || doubled >= maximumDelayNanoseconds {
                return maximumDelayNanoseconds
            }
            delay = doubled
        }
        return delay
    }
}
