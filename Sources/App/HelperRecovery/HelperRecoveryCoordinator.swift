// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Getting out of a wedged helper without a
/// terminal.
///
/// The helper is launchd demand-launched, so stopping it makes the next
/// request start a replacement, and the reconnect that follows re-supplies the
/// session inventory. This coordinator is the part around that: it decides
/// when to propose a restart, runs it, and keeps a proposal the user declined
/// from coming straight back.
///
/// Two things it deliberately does not do. It does not report per-pane
/// results, because each pane reports its own outcome in its own slot and a
/// modal summary would say it later and less precisely. And it does not
/// promise the helper is gone: `terminate` says whether the signal landed,
/// which is a different claim, and the outcomes the GUI can't act on are
/// surfaced rather than smoothed over.
///
/// Every dependency is injected so the whole sequence runs in tests without
/// AppKit, a live connection, or a real clock.
@MainActor
final class HelperRecoveryCoordinator {
    struct Dependencies {
        /// Put the prompt on screen and return the answer. Runs the modal, so
        /// it does not return until the user picks.
        var prompt: @MainActor (HelperRestartReason) -> HelperRestartChoice
        /// Stop the helper. Nil targets the currently connected peer with no
        /// generation fence.
        var terminate: @MainActor (Int?) async -> HelperTerminationOutcome
        /// Attempt an immediate reconnect, so recovery starts now rather
        /// than at whatever backoff something else is on.
        var reconnect: @MainActor () async -> Void
        /// Surface an outcome that didn't confirm the helper was stopped.
        var report: @MainActor (HelperTerminationOutcome) -> Void
        /// Recovery that has to happen before the helper is stopped, run once
        /// the user has confirmed and before the termination.
        ///
        /// This slot exists for the CoreSimulator restart, and the ordering is
        /// why it is a slot rather than something a caller does either side of
        /// this type. The launchd job carries `KeepAlive`/`SuccessfulExit
        /// false`, so a SIGKILLed helper is respawned at once, and a helper
        /// registers its CoreSimulator notifier as it starts. Stopping the
        /// service after the helper would hand that replacement a registration
        /// whose other end is already gone, which it then keeps for its whole
        /// life, since nothing re-registers one.
        ///
        /// Stopping the service first inverts that: when the stop succeeds,
        /// whichever helper outlives this sequence started after the service
        /// did, so its handles are to the replacement launchd demand-launches
        /// rather than to a corpse. Nothing here confirms the service exited,
        /// and a stop that fails does not abort the sequence, so the guarantee
        /// is over the order of the attempts rather than over the outcome.
        ///
        /// The cost is that a termination which then fails leaves a live
        /// helper holding dead handles. `report` surfaces that, with the
        /// remedy the outcome earns: a refused signal advises logging out, an
        /// unreported peer advises retrying and then reopening deviceterm.
        var beforeHelperStopped: @MainActor (HelperRestartReason) async -> Void = { _ in }
        /// Ask the detector to diagnose this connection again. It reports a
        /// silent connection once, so every verdict this coordinator doesn't
        /// act on has to be handed back or nothing asks again.
        var rearmDetection: @MainActor () -> Void = {}
        var now: @MainActor () -> Date = { Date() }
        /// How long the automatic prompt stays quiet after Keep Waiting or a
        /// restart attempt. Long enough that a user who decided
        /// to wait isn't asked again while they wait, or that a replacement
        /// helper gets a chance to come up, and short enough that either of
        /// them being wrong doesn't strand the user with only the menu item.
        /// It gates prompting, not the signal, so nothing fires when it
        /// lapses: the next unanswered call is what asks again.
        var quietSeconds: TimeInterval = 120
    }

    private let deps: Dependencies
    /// True from the moment a prompt is raised until its sequence finishes.
    /// The sequence rearms the detector when it ends, so without this a
    /// verdict arriving mid-sequence would stack a second prompt on the first;
    /// the restart is several awaits long on top of however long the user
    /// takes to read.
    private var isPrompting = false
    /// When the detector may propose a restart again.
    private var quietUntil: Date?

    /// Test seam: whether a prompt or restart is currently in flight.
    var isBusy: Bool { isPrompting }

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// The helper has stopped answering on `connection`, the transport
    /// generation the unanswered calls were going to. Propose a restart unless
    /// one is already being proposed, or the user recently said they'd wait.
    ///
    /// The connection arrives with the signal rather than being read here.
    /// Reading it would be an actor hop, and the diagnosed connection can be
    /// replaced across one, which would aim the kill at a peer nothing was
    /// ever diagnosed about.
    ///
    /// A verdict declined for the quiet window is handed straight back, so the
    /// helper is diagnosed again a moment later and the window ends in a fresh
    /// prompt rather than in silence. A verdict declined because a sequence is
    /// already running needs no hand-back: that sequence rearms when it ends.
    func helperStoppedAnswering(connection: Int) {
        guard !isPrompting else { return }
        if let quietUntil, deps.now() < quietUntil {
            deps.rearmDetection()
            return
        }
        begin(reason: .unresponsive, connection: connection)
    }

    /// The user asked for a restart. Never snoozed: they went looking for
    /// this, so the answer to "should we ask?" is that they already did.
    func restartRequested() {
        guard !isPrompting else { return }
        begin(reason: .requested, connection: nil)
    }

    /// The user asked to restart CoreSimulator. Runs the same sequence as a
    /// requested helper restart, with the service stopped first, before the
    /// helper is terminated; `tally` is what the prompt names as the cost.
    ///
    /// Like `restartRequested`, never snoozed and never fenced to a
    /// connection: the user went looking for this, and there is no diagnosis
    /// here that a replacement helper could make stale.
    func coreSimulatorRestartRequested(tally: CoreSimulatorRestartDecision.Tally) {
        guard !isPrompting else { return }
        begin(reason: .coreSimulator(tally), connection: nil)
    }

    private func begin(reason: HelperRestartReason, connection: Int?) {
        isPrompting = true
        Task { @MainActor [weak self] in
            await self?.run(reason: reason, connection: connection)
        }
    }

    /// `connection` is the generation a diagnosis was made against, and nil
    /// for a restart the user asked for outright. The fence exists because the
    /// prompt sits on screen for as long as the user takes: a helper that dies
    /// on its own in that window must not get its replacement killed in its
    /// place. A requested restart has no diagnosis to go stale, and refusing
    /// it because the connection changed since the menu opened would just fail
    /// what the user asked for.
    private func run(reason: HelperRestartReason, connection: Int?) async {
        // The detector reports a silent connection once, and this sequence
        // consumed that report. Hand it back on the way out so a helper that is
        // still wedged can be diagnosed again, whichever way the user answered:
        // the quiet window is what decides when the next verdict becomes a
        // prompt, not whether one is ever made.
        defer {
            isPrompting = false
            deps.rearmDetection()
        }
        switch deps.prompt(reason) {
        case .keepWaiting:
            quietUntil = deps.now().addingTimeInterval(deps.quietSeconds)
            return

        case .cancel:
            // A cancelled deliberate restart is a dismissal, not a judgement
            // about the helper, so it must not quiet a diagnosis the user
            // never saw.
            return

        case .restart:
            break
        }
        // Acting is its own reason not to re-diagnose immediately. Calls that
        // were already in flight against the old helper keep expiring, and a
        // replacement needs a moment to come up, so without this the very next
        // expiry would ask again seconds after the user said yes.
        quietUntil = deps.now().addingTimeInterval(deps.quietSeconds)
        // Before the termination, not after it: launchd respawns a SIGKILLed
        // helper immediately, and the replacement takes its CoreSimulator
        // handles as it starts. Anything this stops has to be stopped while
        // the only helper holding handles is the one about to be killed.
        await deps.beforeHelperStopped(reason)
        switch await deps.terminate(connection) {
        case .terminated, .alreadyGone, .alreadyRestarted:
            // None of these needs an alert: the signal landed, there was no
            // process to signal, or the connection it was aimed at had already
            // been superseded. Only the first is this call's doing, and saying
            // so would be a modal about a non-event; the panes coming back is
            // the feedback that matters.
            break

        case let .failed(detail):
            // The helper is still running and still wedged. Nothing further
            // in this sequence changes that, so say so instead of going on to
            // reconnect to the same process.
            deps.report(.failed(detail))
            return

        case .unknownPeer:
            deps.report(.unknownPeer)
            return
        }
        // Reconnecting is what drives session restore and, behind it, pane
        // recovery. The prompt promised those, so drive them now rather than
        // leaving them to whatever retries next.
        await deps.reconnect()
    }
}
