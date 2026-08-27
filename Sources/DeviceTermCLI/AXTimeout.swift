// SPDX-License-Identifier: GPL-3.0-or-later

/// Response timeouts for the `ax` verbs, whose reads all queue on one
/// serial accessibility queue per pane and so can wait on each other
/// there.
///
/// A namespace rather than top-level constants in `main.swift`: a
/// top-level `let` holds its zero-initialized value until top-level code
/// reaches it, which makes the budget correct only by statement order and
/// leaves it reading zero, an instant timeout, anywhere that order does
/// not hold. Under the test harness top-level code never runs at all, so
/// no test can assert a budget declared that way.
///
/// Both values mirror the daemon's sweep deadline as a literal, the same
/// way `notReadyCode` does in `main.swift`, because the CLI links
/// `DaemonProtocol` and not the daemon's `AXSweep.maxDurationMs`.
enum AXTimeout {
    /// Response timeout for `ax sweep`, whose grid walk the daemon runs
    /// under a deadline of its own and then answers with what it found.
    /// The legal step range reaches grids that take far longer than the
    /// default wait, so without this a caller asking for a fine step got a
    /// bare transport timeout instead of the partial answer the daemon was
    /// about to send.
    ///
    /// The daemon's 10-second scheduling budget plus five seconds of
    /// headroom for dispatch, a final in-flight bridge call, and response
    /// delivery.
    static let sweep: Double = 10 + 5

    /// Response timeout for `ax tree` and `ax point`, which walk no grid
    /// but share the pane's accessibility queue with `ax sweep`. A sweep
    /// can occupy the queue until its scheduling deadline, and an
    /// in-flight bridge call may extend that wait. A read queued behind a
    /// long-running sweep can spend most of its wait queued and time out
    /// before its own walk begins.
    ///
    /// Five seconds beyond the sweep's 10-second budget, covering that
    /// overrun, the query, and response delivery. Kept separate from
    /// `sweep` because the budgets cover different work: the sweep's own
    /// walk versus another request's queue wait.
    static let query: Double = 10 + 5
}
