// SPDX-License-Identifier: GPL-3.0-or-later
//
// WireVersionRecoveryCoordinator: replacing an incompatible helper at startup,
// falling back to recovery guidance only if no compatible one answers.
//
// After a Sparkle update the bundle on disk is new and the running helper is
// old. The launchd job resolves `BundleProgram` relative to the registered
// bundle, which Sparkle replaced in place, so stopping the old helper is enough:
// the next connect demand-launches the new one from the same path. At startup
// the GUI holds no window, session, pane, or subscription, so this launching GUI
// has no state at risk. The helper is a per-user singleton, so another running
// checkout can still lose its own. A mid-session mismatch is the opposite case
// and never reaches here.
//
// Two things shape the ladder, and both are easy to get wrong.
//
// The verdict is bounded by a clock, not by an attempt count, and it reads the
// PID before the version. `daemon.shutdown` acknowledges a grace period before
// the daemon exits and SIGKILL is accepted before teardown finishes, so on the
// SUCCESSFUL path the old helper may answer at least one more ping with the old
// version. A ladder that treated that as failure would abandon the case it
// exists for.
//
// And the rungs are conditional rather than sequential. The launchd job carries
// `KeepAlive`/`SuccessfulExit false`, so a killed daemon is respawned. Killing a
// replacement that merely speaks the wrong version would make launchd start
// another exactly like it; that state is not a process refusing to die, it is a
// registration pointing at the wrong bundle, which is what the repair rung
// treats.
//
// Every dependency is injected so the whole sequence runs in tests without
// AppKit, a live connection, a real clock, or launchd.

import Foundation

@MainActor
final class WireVersionRecoveryCoordinator {
    struct Dependencies {
        /// Whether the helper that answered the mismatched ping is still the
        /// connected peer, i.e. whether the bootstrap shutdown may be sent to
        /// it.
        ///
        /// The transport was already fenced when the mismatch was detected, so
        /// this reads a decision rather than making one. Fencing at detection is
        /// what keeps the reconnect handler from acting in the gap between the
        /// handshake throwing and this ladder starting.
        var pinnedToIncompatibleHelper: @MainActor () async -> Bool
        /// Rung 1: ask the pinned helper to stop and await its acknowledgement.
        var requestShutdown: @MainActor () async -> VersionMismatchOutcome.Shutdown
        /// Rung 2: SIGKILL the pinned helper, fenced to its pid.
        var terminateHelper: @MainActor () async -> HelperTerminationOutcome
        /// Rung 3: tear the launchd registration down and stand it back up.
        /// Nil disables the rung, for a test or a transport with no repair
        /// capability. Production smoke mode never builds this coordinator at
        /// all, because the recovery path is skipped there outright.
        var repairRegistration: (@MainActor () async throws -> Void)?
        /// One bounded handshake against whatever answers now.
        var handshake: @MainActor () async -> RecoveryHandshakeOutcome
        /// Recovery succeeded: return the transport to full service.
        var finishRecovery: @MainActor () async -> Void
        /// Recovery gave up: fence the transport terminally.
        var abandonRecovery: @MainActor () async -> Void
        var sleep: @Sendable (UInt64) async -> Void
        var now: @MainActor () -> Date = { Date() }
        /// How long one rung's verdict is waited for. An allowance for launchd
        /// getting the replacement up, not an expected duration.
        var verifySeconds: TimeInterval = 3
        var verifyIntervalNanos: UInt64 = 250_000_000
        /// How long startup waits on the repair rung before abandoning it. The
        /// repair itself is not cancellable, so this bounds the WAIT and never
        /// the work; see `recover(after:)`.
        var repairWaitSeconds: TimeInterval = 8
    }

    /// What a bounded repair produced, when it produced anything in time.
    private enum RepairReport {
        case completed
        case failed(RegistrationRepairFailure)
    }

    /// Where recovery ended.
    enum Resolution: Sendable, Equatable {
        /// A compatible helper is answering; the launch continues with no UI.
        case connected
        /// Recovery could not get there. The caller surfaces this.
        case surrender(UpdateRestartSituation)
    }

    private let deps: Dependencies
    /// Every rung's own words, accumulated for the details disclosure.
    private var detail: [String] = []
    /// Whether the registration was actually torn down and stood back up.
    ///
    /// Set on completion, never on attempt. The copy it drives tells the user
    /// macOS may show a Background Activity notification, which only a completed
    /// re-registration triggers; a repair that stalled or failed before the
    /// teardown has nothing to warn about and must not claim otherwise.
    private var didReregister = false
    /// Where the unstructured repair task leaves its result. Nil while it is
    /// still running, which is what `waitBounded` polls.
    private var repairReport: RepairReport?

    /// The most recent rung's words, for a cause that carries one string.
    private var lastDetail: String { detail.last ?? "" }

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// Run the ladder. Returns `.connected` the moment a compatible helper
    /// answers, at any rung.
    func recover(after mismatch: DaemonClientError) async -> Resolution {
        detail.append("\(mismatch)")
        let pinned = await deps.pinnedToIncompatibleHelper()

        // Not pinned: the instance that answered the mismatched ping is already
        // gone, so there is nothing to ask or signal. Whatever is there now is a
        // different daemon, and the only useful question is whether it matches.
        if !pinned {
            detail.append("the incompatible daemon was replaced before it could be stopped")
            return await afterStopAttempt(canSignal: false)
        }

        let shutdown = await deps.requestShutdown()
        switch shutdown {
        case .confirmed:
            detail.append("the old helper acknowledged the shutdown request")

        case let .indeterminate(reason):
            detail.append("shutdown not acknowledged: \(reason)")
        }
        return await afterStopAttempt(canSignal: true)
    }

    /// Verify, then pick the next rung from what answered.
    private func afterStopAttempt(canSignal: Bool) async -> Resolution {
        switch await verify() {
        case .compatible:
            return await succeed()

        case .sameHelperStillAnswering:
            // A reply carrying the pinned pid, treated as the old helper still
            // answering, so the stop has not taken effect. This is the one
            // condition SIGKILL actually treats, and the only one it may run on.
            guard canSignal else { return await repairRung() }
            let outcome = await deps.terminateHelper()
            detail.append("signalled the old helper: \(describe(outcome))")
            switch await verify() {
            case .compatible:
                return await succeed()

            case .sameHelperStillAnswering, .incompatible, .unreachable:
                return await repairRung()
            }

        case .incompatible, .unreachable:
            // A different daemon answered wrong, or nothing answered. Neither is
            // a process refusing to die, so skip the signal.
            return await repairRung()
        }
    }

    /// Rung 3, and the last one. The repair is not cancellable, so this bounds
    /// the WAIT rather than the work: an independently owned task runs it to
    /// completion, clearing the persisted marker only if the transaction
    /// succeeds, while
    /// startup gives up after `repairWaitSeconds` and surrenders. A launch that
    /// awaited this outright would never reach a window if ServiceManagement
    /// stalled, and would do so again on every relaunch.
    private func repairRung() async -> Resolution {
        guard let repair = deps.repairRegistration else {
            detail.append("registration repair is unavailable on this transport")
            return await surrender(cause: .helperCouldNotBeStopped(lastDetail))
        }
        // Unstructured on purpose: it must outlive this function, and this
        // function's own cancellation, so the register leg still runs after
        // startup has stopped waiting. Its only output is the slot below and the
        // marker `repair` clears; it never touches UI, because by the time it
        // finishes the user may already have acted on a surrender.
        Task { @MainActor [weak self] in
            let report: RepairReport
            do {
                try await repair()
                report = .completed
            } catch let failure as RegistrationRepairFailure {
                report = .failed(failure)
            } catch {
                report = .failed(
                    RegistrationRepairFailure(unregistered: false, underlying: error)
                )
            }
            self?.repairReport = report
        }

        guard let report = await waitBounded() else {
            detail.append("registration repair outran its deadline and is still running")
            return await surrender(cause: .registrationRepairAbandoned(lastDetail))
        }

        switch report {
        case .completed:
            didReregister = true
            detail.append("rebuilt the helper's launchd registration")

        case let .failed(failure):
            detail.append("registration repair failed: \(failure)")
            if failure.unregistered {
                // Stopped and unregistered: a different problem from one that
                // would not stop, and the only remedy is registering again.
                return await surrender(cause: .registrationNotRestored(lastDetail))
            }
        }

        switch await verify() {
        case .compatible:
            return await succeed()

        case .sameHelperStillAnswering:
            return await surrender(cause: .helperCouldNotBeStopped(lastDetail))

        case let .incompatible(daemonVersion, _):
            return await surrender(cause: .replacementStillIncompatible(daemonVersion: daemonVersion))

        case .unreachable:
            return await surrender(cause: .replacementDidNotStart(lastDetail))
        }
    }

    /// Wait for the repair to report, up to `repairWaitSeconds`, returning nil
    /// on expiry.
    ///
    /// Polls a slot rather than awaiting the task, which is the whole point: the
    /// task is never cancelled and never awaited, because cancelling would not
    /// stop a completion-handler-backed ServiceManagement call and awaiting is
    /// the stall this exists to avoid. Polling against the injected clock also
    /// keeps the bound testable without a real one.
    private func waitBounded() async -> RepairReport? {
        let deadline = deps.now().addingTimeInterval(deps.repairWaitSeconds)
        while deps.now() < deadline {
            if let finished = repairReport { return finished }
            await deps.sleep(deps.verifyIntervalNanos)
        }
        return repairReport
    }

    /// Ask repeatedly until something decisive comes back or the clock runs out.
    ///
    /// A wall clock, not an attempt count: the ping carries its own bound, so a
    /// fixed number of attempts would multiply into a stall an order of
    /// magnitude longer than intended when the helper is silent.
    private func verify() async -> RecoveryHandshakeOutcome {
        let deadline = deps.now().addingTimeInterval(deps.verifySeconds)
        var last = RecoveryHandshakeOutcome.unreachable("no handshake attempted")
        repeat {
            last = await deps.handshake()
            switch last {
            case .compatible, .incompatible:
                return last

            case .sameHelperStillAnswering, .unreachable:
                await deps.sleep(deps.verifyIntervalNanos)
            }
        } while deps.now() < deadline
        return last
    }

    private func succeed() async -> Resolution {
        await deps.finishRecovery()
        return .connected
    }

    private func surrender(cause: UpdateRestartCause) async -> Resolution {
        await deps.abandonRecovery()
        return .surrender(
            UpdateRestartSituation(
                cause: cause,
                detail: detail.joined(separator: "\n"),
                reregistered: didReregister
            )
        )
    }

    private func describe(_ outcome: HelperTerminationOutcome) -> String {
        switch outcome {
        case let .terminated(pid):
            return "sent SIGKILL to pid \(pid)"

        case .alreadyGone:
            return "already gone"

        case .unknownPeer:
            return "no peer process to signal"

        case .alreadyRestarted:
            return "already replaced"

        case let .failed(reason):
            return "signal refused (\(reason))"
        }
    }
}
