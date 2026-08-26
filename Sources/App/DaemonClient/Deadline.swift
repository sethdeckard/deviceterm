// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Bound a wait without abandoning what it was waiting on.
///
/// The usual way to bound an async call races it against a sleep and cancels
/// the loser. That's right for a read: giving up loses nothing. It's wrong for
/// a call that creates something daemon-side, because the reply is where the
/// new thing's identity lives, and cancelling the wait throws that identity
/// away while the daemon goes on to create it anyway: a session whose one-time
/// capability nobody holds, a pane no window shows and nothing can name.
///
/// Cancelling the wait doesn't cancel the daemon, so "stop waiting" and "stop
/// caring about the result" are separable, and only the first is safe. This
/// separates them: the caller stops waiting on time, the call keeps running,
/// and whichever side loses the race the value is still accounted for, either
/// returned or handed to a cleanup.
@MainActor
enum Deadline {
    /// Wait up to `nanos` for `work`, and account for its value either way.
    ///
    /// Returns the value when it arrives in time. Otherwise throws `expired`
    /// and, whenever `work` does finish, hands its value to `late` to
    /// reconcile. `work` is never cancelled: it holds the only reference to
    /// whatever the daemon made.
    ///
    /// Caller cancellation is an expiry with `CancellationError`: the caller
    /// stops waiting at once, and a value arriving afterwards still reaches
    /// `late`.
    ///
    /// `late` runs for a value nobody claimed, so it must be safe against the
    /// world having moved on: the same target may have been attached again,
    /// the tab may be gone. It does not run when `work` throws, since there is
    /// then nothing to reconcile.
    ///
    /// A `work` that never returns keeps its task alive for the life of the
    /// process, so this belongs on calls whose transport guarantees
    /// termination (a dropped connection fails every pending request).
    static func wait<T: Sendable>(
        nanos: UInt64,
        expired: @autoclosure @escaping @Sendable () -> Error,
        late: @escaping @Sendable @MainActor (T) async -> Void,
        work: @escaping @Sendable @MainActor () async throws -> T
    ) async throws -> T {
        let claim = Claim<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Both tasks are spawned from inside this body, which runs
                // synchronously on this actor, so neither can reach `settle`
                // before the continuation is installed.
                claim.install(continuation)
                claim.timer = Task { @MainActor in
                    // A cancelled sleep means the wait was already settled;
                    // `try?` would turn that into a spurious expiry.
                    do { try await Task.sleep(nanoseconds: nanos) } catch { return }
                    claim.fail(expired())
                }
                Task { @MainActor in
                    do {
                        let value = try await work()
                        if !claim.settle(value) { await late(value) }
                    } catch {
                        claim.fail(error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in claim.fail(CancellationError()) }
        }
    }
}

private extension Deadline {
    /// The single-resume guard the call, the timer, and cancellation all race for.
    @MainActor
    final class Claim<T: Sendable> {
        var timer: Task<Void, Never>?
        private var continuation: CheckedContinuation<T, Error>?

        func install(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        /// Hand the waiter `value`, and report whether this call is the one that
        /// resumed it. A `false` tells a caller carrying a value that nobody took
        /// it, so it's theirs to clean up.
        func settle(_ value: T) -> Bool {
            guard let continuation = take() else { return false }
            continuation.resume(returning: value)
            return true
        }

        /// Fail the waiter, reporting single-resume the same way. Errors need no
        /// cleanup, so the result is discarded at every call site.
        @discardableResult
        func fail(_ error: any Error) -> Bool {
            guard let continuation = take() else { return false }
            continuation.resume(throwing: error)
            return true
        }

        /// Claim the continuation for this caller, retiring the timer with it.
        private func take() -> CheckedContinuation<T, Error>? {
            guard let continuation else { return nil }
            self.continuation = nil
            timer?.cancel()
            timer = nil
            return continuation
        }
    }
}
