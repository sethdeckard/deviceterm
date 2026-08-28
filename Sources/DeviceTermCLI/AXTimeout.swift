// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// Response timeout for the `ax` verbs, whose reads all queue on one
/// serial accessibility queue per pane and so can wait on each other
/// there.
///
/// A namespace rather than a top-level constant in `main.swift`: a
/// top-level `let` holds its zero-initialized value until top-level code
/// reaches it, which makes the budget correct only by statement order and
/// leaves it reading zero, an instant timeout, anywhere that order does
/// not hold. Under the test harness top-level code never runs at all, so
/// no test can assert a budget declared that way.
enum AXTimeout {
    /// Slack beyond the daemon-side work: dispatch, one in-flight bridge
    /// call no deadline can interrupt, and delivery of the response.
    private static let headroomSeconds: Double = 5

    /// The wait `ax tree`, `ax point`, and `ax sweep` all get.
    ///
    /// One number for the three because they resolve to the same bound. Each
    /// queues on the pane's single serial accessibility queue, so any of them
    /// can wait out another caller's sweep before its own work starts, and
    /// `AXSweepBudget.maxMs` is the longest walk the daemon will honor.
    ///
    /// A sweep's own budget does not add to that wait. Its deadline starts
    /// when the request arrives rather than when it reaches the queue, so
    /// time spent queued is spent out of the budget instead of deferring it:
    /// a sweep behind a full-ceiling one finds its deadline gone and answers
    /// truncated the moment the queue frees. The worst case is
    /// `max(queue wait, own budget)`, and the same ceiling caps both terms,
    /// which is why `--budget` needs no matching client arithmetic.
    ///
    /// Nor do several sweeps ahead each add a budget. The queue is FIFO and a
    /// sweep takes its deadline before enqueueing, so every sweep already
    /// waiting when a request arrives took its deadline earlier still, and all
    /// of them stop working by that request's arrival plus the ceiling.
    /// Sweeps arriving afterwards queue behind it. Running in sequence
    /// overlaps their deadlines rather than summing their budgets.
    ///
    /// What this does not bound is an `ax tree` or `ax point` ahead in the
    /// queue: those carry no deadline and hold it for however long their
    /// bridge call takes. Nor the one in-flight call each sweep may overrun
    /// by, which the headroom absorbs unless it hangs. Reaching this timeout
    /// means reissue, not that the daemon is dead.
    static let response: Double = Double(AXSweepBudget.maxMs) / 1_000.0 + headroomSeconds
}
