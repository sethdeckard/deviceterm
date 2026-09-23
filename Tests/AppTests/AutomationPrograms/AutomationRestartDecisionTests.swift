// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// AutomationRestartDecisionTests: what supervision does when a program exits.
//
// Two rules pull against each other and both matter: repeated short runs
// are capped rather than retried forever, and a long run resets the budget.

private let second: UInt64 = 1_000_000_000

private func exit(
    after exits: Int,
    ranFor: UInt64 = 0,
    restart: Bool = true
) -> AutomationRestartDecision.Outcome {
    AutomationRestartDecision.afterExit(
        history: .init(consecutiveExits: exits, startedAtNanos: 0),
        restart: restart,
        now: ranFor
    )
}

// MARK: - Backoff

/// One second doubling to a minute, then holding there.
@Test(
    "the backoff doubles from a second and saturates at a minute",
    arguments: [
        (0, 1 * second),
        (1, 2 * second),
        (2, 4 * second),
        (3, 8 * second),
        (4, 16 * second),
        (5, 32 * second),
        (6, 60 * second),
        (7, 60 * second),
        (8, 60 * second)
    ]
)
func backoffSchedule(priorExits: Int, expected: UInt64) {
    guard case let .restart(delay, _) = exit(after: priorExits) else {
        Issue.record("expected a restart")
        return
    }
    #expect(delay == expected)
}

/// A program that exits instantly must not be re-run instantly.
@Test("the first restart still waits the initial delay")
func firstRestartWaits() {
    guard case let .restart(delay, history) = exit(after: 0) else {
        Issue.record("expected a restart")
        return
    }
    #expect(delay == second)
    #expect(history.consecutiveExits == 1)
}

// MARK: - The cap

@Test("the ninth consecutive exit still restarts")
func restartsBelowTheCap() {
    #expect(exit(after: 8) != .giveUp)
}

@Test("the tenth consecutive exit gives up")
func givesUpAtTheCap() {
    #expect(exit(after: 9) == .giveUp)
}

/// The cap counts consecutive exits, so a run that worked clears it. Without
/// this a long-lived program that crashed once a week would eventually stop
/// coming back.
@Test("a run longer than a minute resets the count")
func longRunResetsTheCount() {
    guard case let .restart(delay, history) = exit(after: 8, ranFor: 61 * second) else {
        Issue.record("expected a restart")
        return
    }
    #expect(history.consecutiveExits == 1)
    #expect(delay == second)
}

@Test("a run of exactly a minute is not long enough to reset")
func exactlyAMinuteDoesNotReset() {
    guard case let .restart(_, history) = exit(after: 3, ranFor: 60 * second) else {
        Issue.record("expected a restart")
        return
    }
    #expect(history.consecutiveExits == 4)
}

/// A clock that went backwards between the two reads must not read as a long
/// run, which would hand out an unearned budget reset.
@Test("a backwards clock does not count as a long run")
func backwardsClockDoesNotReset() {
    let outcome = AutomationRestartDecision.afterExit(
        history: .init(consecutiveExits: 3, startedAtNanos: 100 * second),
        restart: true,
        now: 1 * second
    )
    guard case let .restart(_, history) = outcome else {
        Issue.record("expected a restart")
        return
    }
    #expect(history.consecutiveExits == 4)
}

// MARK: - Opting out

@Test("restart false stops instead of restarting")
func restartFalseStops() {
    #expect(exit(after: 0, restart: false) == .stop)
}

@Test("restart false stops even where the cap would have been hit")
func restartFalseStopsAtTheCap() {
    #expect(exit(after: 99, restart: false) == .stop)
}
