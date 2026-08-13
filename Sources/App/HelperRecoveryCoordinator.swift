// SPDX-License-Identifier: GPL-3.0-or-later
//
// HelperRecoveryCoordinator: getting out of a wedged helper without a
// terminal.
//
// The helper is launchd demand-launched, so stopping it makes the next
// request start a replacement, and the reconnect that follows re-supplies the
// session inventory. This coordinator is the part around that: it decides
// when to propose a restart, runs it, and keeps a proposal the user declined
// from coming straight back.
//
// Two things it deliberately does not do. It does not report per-pane
// results, because each pane reports its own outcome in its own slot and a
// modal summary would say it later and less precisely. And it does not
// promise the helper is gone: `terminate` says whether the signal landed,
// which is a different claim, and the outcomes the GUI can't act on are
// surfaced rather than smoothed over.
//
// Every dependency is injected so the whole sequence runs in tests without
// AppKit, a live connection, or a real clock.

import Foundation

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
    /// A helper that has stopped answering reports every unanswered call from
    /// the threshold on, so without this the prompt would stack on itself
    /// within seconds; the restart is several awaits long on top of however
    /// long the user takes to read.
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
    func helperStoppedAnswering(connection: Int) {
        guard !isPrompting else { return }
        if let quietUntil, deps.now() < quietUntil { return }
        begin(reason: .unresponsive, connection: connection)
    }

    /// The user asked for a restart. Never snoozed: they went looking for
    /// this, so the answer to "should we ask?" is that they already did.
    func restartRequested() {
        guard !isPrompting else { return }
        begin(reason: .requested, connection: nil)
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
        defer { isPrompting = false }
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
