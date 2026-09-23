// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What supervision does when a configured program exits.
///
/// Pure, so the backoff schedule and the give-up rule are testable without a
/// clock, a workspace, or a process.
///
/// Cap repeated short runs, so a program that cannot start is not retried
/// indefinitely. Reset the budget after a long run, so a program that works
/// and then occasionally exits stays recoverable.
enum AutomationRestartDecision {
    /// What supervision knows about one program's recent exits.
    struct History: Equatable, Sendable {
        /// Exits since the last run that lasted longer than `longRunNanoseconds`.
        var consecutiveExits = 0
        /// When the run that just ended began, on the caller's clock.
        var startedAtNanos: UInt64 = 0
    }

    enum Outcome: Equatable, Sendable {
        /// Re-run after this delay, carrying the updated history forward.
        case restart(delayNanoseconds: UInt64, history: History)
        /// The cap is reached: stop, mark the entry failed, say so once.
        case giveUp
        /// The entry asked not to be restarted.
        case stop
    }

    /// Doubles from one second to one minute. Unjittered, like the other
    /// backoff loops here, because each belongs to a single subject with no
    /// fleet to decorrelate.
    static let backoff = RetryPolicy(
        initialDelayNanoseconds: 1_000_000_000,
        maximumDelayNanoseconds: 60_000_000_000
    )

    /// Consecutive exits tolerated before supervision gives up.
    static let consecutiveExitCap = 10

    /// A run longer than this counts as the program having worked, and
    /// resets the consecutive-exit count to one for the exit being handled.
    /// Strictly longer: a run of exactly this length does not reset.
    static let longRunNanoseconds: UInt64 = 60_000_000_000

    /// Decide what to do about the exit that just happened.
    ///
    /// `now` and `history.startedAtNanos` come from the caller's clock, so a
    /// test supplies its own and no real time passes.
    static func afterExit(history: History, restart: Bool, now: UInt64) -> Outcome {
        guard restart else { return .stop }
        // Saturating, because a clock that went backwards between the two
        // reads should not read as a long run.
        let ranFor = now >= history.startedAtNanos ? now - history.startedAtNanos : 0
        var next = history
        next.consecutiveExits = ranFor > longRunNanoseconds ? 1 : history.consecutiveExits + 1
        guard next.consecutiveExits < consecutiveExitCap else { return .giveUp }
        // The first restart is attempt 0, so it waits the initial delay
        // rather than none: a program that exits instantly should not be
        // re-run instantly.
        return .restart(
            delayNanoseconds: backoff.delayNanoseconds(forAttempt: next.consecutiveExits - 1),
            history: next
        )
    }
}
