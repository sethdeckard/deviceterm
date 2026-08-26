// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Finishing a registration repair that an earlier
/// process was terminated in the middle of, before this launch registers or
/// connects.
///
/// A marker means some previous run started a registration repair and may not
/// have finished it. It is written before the teardown, so that run may have
/// died before mutating anything or after tearing the job down. Registering or connecting on top of that half-state
/// would race a teardown that is still in flight, so this runs first.
///
/// It replays the WHOLE transaction rather than the register leg alone. The
/// marker records that a repair was interrupted, not which phase it reached, and
/// the phases need opposite handling: teardown may be in flight, may have failed
/// before mutating anything, or may have completed. Replaying converges from all
/// of them, because the unregister tolerates job-not-found.
///
/// The wait is bounded but the work is not. `SMAppService.unregister()` is
/// completion-handler-backed and honours no cancellation, so a replay that stalls
/// cannot be stopped. A launch that awaited one outright would never reach a
/// window, and would repeat that on every relaunch with nothing on screen to
/// explain it. So an independently owned task runs the replay to completion while
/// startup stops waiting, exactly as the recovery ladder's own repair rung does.
///
/// Every dependency is injected, because none of these states can be reached
/// against the real ServiceManagement without mutating the login session.
@MainActor
final class InterruptedRepairReconciler {
    struct Dependencies {
        /// The repair lock, already held by the launch for its whole critical
        /// section. Passed in rather than acquired here: `flock` is per open
        /// file description, so taking a second one inside this process would
        /// fail against our own hold, and releasing it at the end of the
        /// reconciliation would leave the registration and connect that follow
        /// unprotected.
        var heldLock: RegistrationRepairLock.Handle?
        /// Whether a repair was started and not finished. Throws rather than
        /// answering false on a lookup it could not complete.
        var isRepairUnderway: @MainActor () throws -> Bool
        /// Replay the whole repair, under the lock. Throws
        /// `RegistrationRepairFailure`.
        var repair: @MainActor (RegistrationRepairLock.Handle) async throws -> Void
        var now: @MainActor () -> Date = { Date() }
        /// `@MainActor` rather than `@Sendable` so a caller that does not
        /// actually suspend produces no hop. The wait must be able to run to its
        /// deadline without yielding, because that is the case where the replay
        /// has not started and the reconciler is released underneath it.
        var sleep: @MainActor (UInt64) async -> Void
        /// How long the launch waits before giving up on the replay. An
        /// allowance rather than an expected duration: the cost of giving up
        /// early is a screen the user did not need to see.
        var waitSeconds: TimeInterval = 10
        var pollIntervalNanos: UInt64 = 250_000_000
    }

    /// What the launch should do next.
    enum Outcome: Sendable, Equatable {
        /// No repair was interrupted.
        case nothingToDo
        /// The replay finished and the registration is whole.
        case reconciled
        /// The registration is not known to be in a working state, so the launch
        /// should say so rather than register or connect. Every failed replay
        /// ends here, whatever stage it reached.
        case surrender(UpdateRestartSituation)
    }

    /// What a bounded replay produced, when it produced anything in time.
    private enum Report {
        case completed
        case failed(RegistrationRepairFailure)
    }

    private let deps: Dependencies
    /// Where the unstructured replay leaves its result. Nil while it is still
    /// running, which is what the wait polls.
    private var report: Report?

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    func reconcile() async -> Outcome {
        guard let handle = deps.heldLock else {
            // The launch owns the lock, so arriving without one is a wiring
            // error rather than contention. Fail closed.
            let reason = "the startup repair lock is not held"
            return .surrender(
                UpdateRestartSituation(
                    cause: .registrationStateUnknown(reason),
                    detail: reason
                )
            )
        }

        let underway: Bool
        do {
            underway = try deps.isRepairUnderway()
        } catch {
            // The marker could not be read. Skipping on that basis is the one
            // reading that can strand a helper, so treat it as work to do.
            return await replay(holding: handle)
        }
        guard underway else { return .nothingToDo }
        return await replay(holding: handle)
    }

    /// Replay the whole repair under the lock the launch is holding.
    ///
    /// The handle is passed to the repair rather than released here. The launch
    /// holds it through registration and the version handshake, so a replay that
    /// is still running keeps every other process out for that whole window,
    /// which is what stops one of them registering over an unfinished teardown.
    private func replay(holding handle: RegistrationRepairLock.Handle) async -> Outcome {
        // Unstructured on purpose: it must outlive this function and its
        // cancellation, so the register leg still runs after startup has stopped
        // waiting. It never touches UI.
        //
        // The closure is captured BEFORE the spawn, deliberately. Reaching it
        // through `self?` would tie the repair itself to this object's lifetime,
        // and the wait can exhaust without ever yielding, which releases the
        // reconciler and would make the child task skip the repair entirely.
        // That is the guarantee this type exists for. Only the reporting is
        // weak, which is correct: if nothing is waiting, nothing needs told.
        let repair = deps.repair
        Task { @MainActor [weak self] in
            do {
                try await repair(handle)
                self?.report = .completed
            } catch let failure as RegistrationRepairFailure {
                self?.report = .failed(failure)
            } catch {
                self?.report = .failed(
                    RegistrationRepairFailure(unregistered: false, underlying: error)
                )
            }
        }

        guard let finished = await waitBounded() else {
            let stalled = "macOS has not finished rebuilding the helper's registration"
            return .surrender(
                UpdateRestartSituation(
                    cause: .registrationRepairStalled(stalled),
                    detail: stalled
                )
            )
        }

        switch finished {
        case .completed:
            return .reconciled

        case let .failed(failure):
            // Any failed replay blocks the launch. The stage explains what
            // happened; it does not decide whether to proceed.
            //
            // `unregistered` describes THIS attempt, and the marker exists
            // because an EARLIER one was interrupted. So a replay that stopped
            // before its own unregister proves nothing about whether the helper
            // is still registered: the previous transaction may have torn it
            // down already. Proceeding would register or connect over a teardown
            // that may still be in flight.
            //
            // `reregistered` stays false either way, because the rebuild is
            // exactly what did not happen.
            let cause: UpdateRestartCause = failure.unregistered
                ? .registrationNotRestored(
                    "the helper was unregistered and could not be registered again"
                )
                : .registrationStateUnknown(
                    "the replay stopped before its own teardown, so the earlier repair's "
                        + "state is unknown"
                )
            return .surrender(
                UpdateRestartSituation(cause: cause, detail: "\(failure)")
            )
        }
    }

    /// Poll the slot until the replay reports or the clock runs out. Polls
    /// rather than awaiting the task, because awaiting is the stall this exists
    /// to avoid, and polling against the injected clock keeps the bound
    /// testable without a real one.
    private func waitBounded() async -> Report? {
        let deadline = deps.now().addingTimeInterval(deps.waitSeconds)
        while deps.now() < deadline {
            if let finished = report { return finished }
            await deps.sleep(deps.pollIntervalNanos)
        }
        return report
    }
}
