// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// The shared backoff schedule behind the GUI's reconnect retries.
struct RetryPolicyTests {
    private static let policy = RetryPolicy(
        initialDelayNanoseconds: 500_000_000,
        maximumDelayNanoseconds: 8_000_000_000
    )

    @Test("doubling to the cap", arguments: [
        (0, UInt64(500_000_000)),
        (1, UInt64(1_000_000_000)),
        (2, UInt64(2_000_000_000)),
        (3, UInt64(4_000_000_000)),
        (4, UInt64(8_000_000_000)),
        (5, UInt64(8_000_000_000)),
        (99, UInt64(8_000_000_000))
    ])
    func doublesUntilItReachesTheCap(attempt: Int, expected: UInt64) {
        #expect(Self.policy.delayNanoseconds(forAttempt: attempt) == expected)
    }

    @Test
    func aNegativeAttemptClampsToTheFirstDelay() {
        #expect(Self.policy.delayNanoseconds(forAttempt: -1) == 500_000_000)
    }

    @Test
    func aCapBelowTheInitialDelayWins() {
        // Tests build degenerate policies to take the waiting out of a test, so
        // the two bounds crossing must clamp rather than surprise.
        let policy = RetryPolicy(initialDelayNanoseconds: 5, maximumDelayNanoseconds: 2)
        #expect(policy.delayNanoseconds(forAttempt: 0) == 2)
        #expect(policy.delayNanoseconds(forAttempt: 7) == 2)
    }

    @Test
    func aZeroInitialDelayStaysZero() {
        // Doubling never leaves zero, so this is the one schedule whose loop
        // has no growth to terminate on. A far-out attempt proves it answers
        // without walking there.
        let policy = RetryPolicy(initialDelayNanoseconds: 0, maximumDelayNanoseconds: 1_000)
        #expect(policy.delayNanoseconds(forAttempt: 1_000_000) == 0)
    }

    @Test
    func aCapBeyondReachSaturatesRatherThanOverflowing() {
        let policy = RetryPolicy(
            initialDelayNanoseconds: 1_000_000_000,
            maximumDelayNanoseconds: .max
        )
        #expect(policy.delayNanoseconds(forAttempt: 1_000) == .max)
    }
}
