// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeadlineTests: the rule that makes a bounded wait safe for a call that
// creates something.
//
// Racing a call against a sleep and cancelling the loser silently discards
// whatever the loser was carrying. For a daemon call that mints a session or
// a pane, the reply IS the only name for what was minted, so discarding it
// strands the thing. `Deadline.wait` keeps the call running and routes an
// unclaimed value to a cleanup, and these tests pin that: every ordering
// either returns the value or delivers it to `late`, exactly once.

@testable import App
import Foundation
import Testing

@MainActor
struct DeadlineTests {
    private enum Failure: Error, Equatable {
        case expired
        case work
    }

    /// Records values handed to `late`, so a test can assert what the cleanup
    /// was actually given rather than only that the wait ended.
    private final class Reaped {
        private(set) var values: [Int] = []

        func record(_ value: Int) { values.append(value) }
    }

    /// Poll until `values` has an entry, so a test never hangs waiting on a
    /// cleanup that isn't coming.
    private func settle(_ reaped: Reaped, within seconds: Double = 2.0) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, reaped.values.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test
    func aValueArrivingInTimeIsReturnedAndNotReaped() async throws {
        let reaped = Reaped()
        let value = try await Deadline.wait(
            nanos: 2_000_000_000,
            expired: Failure.expired,
            late: { reaped.record($0) },
            work: { 7 }
        )
        #expect(value == 7)
        // Give a stray cleanup a chance to run before asserting it didn't.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(reaped.values.isEmpty)
    }

    @Test
    func anExpiredWaitThrowsAndHandsTheLateValueToTheCleanup() async {
        let reaped = Reaped()
        do {
            _ = try await Deadline.wait(
                nanos: 20_000_000,
                expired: Failure.expired,
                late: { reaped.record($0) },
                work: {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    return 7
                }
            )
            Issue.record("expected the deadline to fire")
        } catch let error as Failure {
            #expect(error == .expired)
        } catch {
            Issue.record("expected the supplied expiry error, got \(error)")
        }
        // The call was not cancelled by the expiry: it ran to completion and
        // its value reached the cleanup. Without that, the caller's timeout
        // would be the last anyone heard of it.
        await settle(reaped)
        #expect(reaped.values == [7])
    }

    @Test
    func aCancelledWaitAlsoHandsTheLateValueToTheCleanup() async {
        let reaped = Reaped()
        let task = Task { @MainActor in
            try await Deadline.wait(
                nanos: 5_000_000_000,
                expired: Failure.expired,
                late: { reaped.record($0) },
                work: {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    return 7
                }
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // The caller stops waiting immediately...
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        // ...and the work still lands somewhere accountable.
        await settle(reaped)
        #expect(reaped.values == [7])
    }

    @Test
    func aFailingCallReportsItsErrorAndReapsNothing() async {
        let reaped = Reaped()
        do {
            _ = try await Deadline.wait(
                nanos: 2_000_000_000,
                expired: Failure.expired,
                late: { reaped.record($0) },
                work: { throw Failure.work }
            )
            Issue.record("expected the call's own error")
        } catch let error as Failure {
            // The call's error, not the expiry: a throw means nothing was
            // created, so there's nothing to clean up either.
            #expect(error == .work)
        } catch {
            Issue.record("expected the work error, got \(error)")
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(reaped.values.isEmpty)
    }
}
