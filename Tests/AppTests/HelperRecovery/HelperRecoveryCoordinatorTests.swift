// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

/// When a restart is proposed, and what
/// running it actually does.
///
/// The interesting behavior here is all about restraint, and about who holds
/// the thread. The client reports a silent connection once and then waits to be
/// asked again, so every verdict this coordinator doesn't act on has to be
/// handed back or nothing ever asks; a user who says they'll wait has made a
/// judgement that should outlast the next few seconds of silence; and a restart
/// aimed at one wedged helper must not land on its healthy replacement.
@MainActor
struct HelperRecoveryCoordinatorTests {
    /// Records what the coordinator asked for, and scripts what it gets back.
    @MainActor
    private final class Harness {
        var generation = 7
        var answer: HelperRestartChoice = .restart
        var outcome: HelperTerminationOutcome = .terminated(pid: 42)
        var clock = Date(timeIntervalSince1970: 1_000)

        private(set) var prompts: [HelperRestartReason] = []
        private(set) var terminations: [Int?] = []
        private(set) var reconnects = 0
        private(set) var reports: [HelperTerminationOutcome] = []
        private(set) var rearms = 0
        private(set) var preStopReasons: [HelperRestartReason] = []
        private(set) var logs: [String] = []
        /// How many steps had run when each line was logged, so a line's place
        /// in the sequence is assertable without the lines becoming steps.
        private(set) var logStepCounts: [Int] = []
        /// The sequence in the order it happened. The CoreSimulator restart is
        /// only correct in one order, so which steps ran isn't enough to
        /// assert on: it has to be when.
        private(set) var steps: [String] = []

        func makeCoordinator(
            quietSeconds: TimeInterval = 120
        ) -> HelperRecoveryCoordinator {
            HelperRecoveryCoordinator(
                HelperRecoveryCoordinator.Dependencies(
                    prompt: { [self] reason in
                        prompts.append(reason)
                        return answer
                    },
                    terminate: { [self] expected in
                        terminations.append(expected)
                        steps.append("terminate")
                        return outcome
                    },
                    reconnect: { [self] in
                        reconnects += 1
                        steps.append("reconnect")
                    },
                    report: { [self] outcome in reports.append(outcome) },
                    beforeHelperStopped: { [self] reason in
                        preStopReasons.append(reason)
                        steps.append("beforeHelperStopped")
                    },
                    rearmDetection: { [self] in rearms += 1 },
                    log: { [self] line in
                        logs.append(line)
                        logStepCounts.append(steps.count)
                    },
                    now: { [self] in clock },
                    quietSeconds: quietSeconds
                )
            )
        }
    }

    /// Let the coordinator's sequence (prompt, terminate, reconnect) finish;
    /// every seam is instant, so a couple of turns is enough.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    @Test
    func anUnresponsiveHelperIsRestartedAgainstTheConnectionItWasDiagnosedOn() async {
        // The whole point of capturing the generation is that the prompt sits
        // on screen for as long as the user takes: fencing the kill to the
        // connection the diagnosis was made against is what stops a
        // replacement being killed in the wedged helper's place.
        let harness = Harness()
        let coordinator = harness.makeCoordinator()
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.prompts == [.unresponsive])
        #expect(harness.terminations == [7])
        #expect(harness.reconnects == 1)
        #expect(harness.reports.isEmpty)
    }

    @Test
    func aRequestedRestartNamesNoConnection() async {
        // A requested restart targets the connected peer without pinning a
        // generation. There is no diagnosis to go stale, and refusing because
        // the connection changed since the menu was opened would just fail the
        // user's request.
        let harness = Harness()
        let coordinator = harness.makeCoordinator()
        coordinator.restartRequested()
        await settle()
        #expect(harness.prompts == [.requested])
        #expect(harness.terminations == [nil])
        #expect(harness.reconnects == 1)
    }

    @Test
    func keepWaitingHoldsOffTheNextSignalAndThenAsksAgain() async {
        // A helper that has stopped answering is diagnosed again as soon as
        // the verdict is handed back, so without the quiet window the user's
        // answer would survive seconds. It has to lapse, too: the same silence
        // is what asks again, and a window that never ended would leave only
        // the menu item.
        let harness = Harness()
        harness.answer = .keepWaiting
        let coordinator = harness.makeCoordinator(quietSeconds: 120)
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.prompts.count == 1)
        #expect(harness.terminations.isEmpty)

        harness.clock = harness.clock.addingTimeInterval(60)
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.prompts.count == 1, "still inside the quiet window")

        harness.clock = harness.clock.addingTimeInterval(61)
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.prompts.count == 2, "the quiet window has passed")
    }

    @Test
    func actingAlsoQuietsTheDetectorSoTheReplacementGetsAChance() async {
        // Calls already in flight against the stopped helper keep expiring,
        // and the replacement takes a moment to answer, so the signal arrives
        // again almost immediately after a restart. Asking again then would
        // put a second prompt in front of a user who just said yes to the
        // first.
        let harness = Harness()
        let coordinator = harness.makeCoordinator(quietSeconds: 120)
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.terminations.count == 1)

        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.prompts.count == 1, "still inside the quiet window")

        // If the restart didn't take, the user still gets asked again rather
        // than being left with a permanently silent helper.
        harness.clock = harness.clock.addingTimeInterval(121)
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.prompts.count == 2)
    }

    @Test
    func keepWaitingDoesNotSuppressAskingForARestart() async {
        // Snoozing is about the app's own diagnosis, not about the user. One
        // who declines the offer and then goes to the menu has changed their
        // mind, and finding the menu item inert would be the worst possible
        // reading of "recovery is always reachable".
        let harness = Harness()
        harness.answer = .keepWaiting
        let coordinator = harness.makeCoordinator()
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        harness.answer = .restart
        coordinator.restartRequested()
        await settle()
        #expect(harness.prompts == [.unresponsive, .requested])
        #expect(harness.terminations == [nil])
    }

    @Test
    func cancellingARequestedRestartChangesNothing() async {
        let harness = Harness()
        harness.answer = .cancel
        let coordinator = harness.makeCoordinator()
        coordinator.restartRequested()
        await settle()
        #expect(harness.terminations.isEmpty)
        #expect(harness.reconnects == 0)
        // Cancel is an ordinary dismissal, not a judgement about the helper,
        // so it must not quiet the detector the way Keep Waiting does.
        harness.answer = .restart
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.prompts == [.requested, .unresponsive])
    }

    @Test
    func aSecondSignalDoesNotStackAPromptOnTheOneOnScreen() async {
        // The restart is several awaits long on top of however long the user
        // takes to read, and the menu item stays live throughout, so a second
        // signal can arrive while the first prompt is up. It needs no hand-back
        // either: the sequence rearms when it ends.
        let harness = Harness()
        let coordinator = harness.makeCoordinator()
        coordinator.helperStoppedAnswering(connection: harness.generation)
        coordinator.helperStoppedAnswering(connection: harness.generation)
        coordinator.restartRequested()
        await settle()
        #expect(harness.prompts == [.unresponsive])
    }

    @Test
    func aVerdictDeclinedInsideTheQuietWindowIsHandedBack() async {
        // The detector reports a silent connection once. A verdict this
        // coordinator drops for the quiet window is therefore the last one it
        // gets unless it says otherwise, and the window would end in silence
        // rather than in the prompt it promised.
        let harness = Harness()
        harness.answer = .keepWaiting
        let coordinator = harness.makeCoordinator(quietSeconds: 120)
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.rearms == 1, "the sequence hands back the verdict it consumed")

        harness.clock = harness.clock.addingTimeInterval(60)
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.prompts.count == 1, "still inside the quiet window")
        #expect(harness.rearms == 2, "declined, not consumed")
    }

    @Test
    func aRestartSequenceHandsTheVerdictBackWhenItEnds() async {
        // Whichever way the user answered, and whatever the termination
        // reported, the helper may still be wedged. Nothing about the sequence
        // ending says otherwise, so it must leave the detector able to say so.
        let harness = Harness()
        let coordinator = harness.makeCoordinator()
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.terminations == [7])
        #expect(harness.rearms == 1)
    }

    @Test
    func aHelperThatCouldNotBeStoppedIsReportedAndNotReconnectedTo() async {
        // The helper is still running and still wedged, and nothing further
        // in the sequence changes that: reconnecting would just rejoin the
        // same stuck process while the prompt implied it had been replaced.
        let harness = Harness()
        harness.outcome = .failed("Operation not permitted")
        let coordinator = harness.makeCoordinator()
        coordinator.restartRequested()
        await settle()
        #expect(harness.reports == [.failed("Operation not permitted")])
        #expect(harness.reconnects == 0)
        #expect(harness.logs.last == "helper termination reason=requested outcome=failed(Operation not permitted)")
    }

    @Test
    func aPeerWithNoReportedProcessIsReportedToo() async {
        let harness = Harness()
        harness.outcome = .unknownPeer
        let coordinator = harness.makeCoordinator()
        coordinator.restartRequested()
        await settle()
        #expect(harness.reports == [.unknownPeer])
        #expect(harness.reconnects == 0)
    }

    @Test(arguments: [HelperTerminationOutcome.alreadyGone, .alreadyRestarted])
    func aSupersededOrAbsentTerminationNeedsNoAlert(
        outcome: HelperTerminationOutcome
    ) async {
        // Neither is this call's doing: one had no connected peer, or a pid
        // that had already exited; the other found a superseding connection.
        // Both still leave the
        // GUI holding nothing it needs to stop, so the reconnect goes ahead. A
        // modal about that would be a modal about a non-event; the recovery it
        // drives is the feedback that matters.
        let harness = Harness()
        harness.outcome = outcome
        let coordinator = harness.makeCoordinator()
        coordinator.restartRequested()
        await settle()
        #expect(harness.reports.isEmpty)
        #expect(harness.reconnects == 1)
    }

    /// The CoreSimulator restart is only correct in this order, and the
    /// tempting one is wrong. The launchd job carries
    /// `KeepAlive`/`SuccessfulExit false`, so a SIGKILLed helper is respawned
    /// at once and registers its CoreSimulator notifier as it starts. Stopping
    /// the service after the termination hands that replacement a dead
    /// registration, which nothing re-registers, so the restart produces the
    /// exact state it exists to clear.
    @Test
    func coreSimulatorIsStoppedBeforeTheHelperIsTerminated() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()
        let tally = CoreSimulatorRestartDecision.Tally(booted: 2, owned: 1)
        coordinator.coreSimulatorRestartRequested(tally: tally)
        await settle()
        #expect(harness.prompts == [.coreSimulator(tally)])
        #expect(harness.steps == ["beforeHelperStopped", "terminate", "reconnect"])
        #expect(harness.preStopReasons == [.coreSimulator(tally)])
    }

    /// A restart the user cancelled must not stop the service. The prompt is
    /// the only thing standing between the menu item and every simulator on
    /// the login, so a decline has to stop the sequence before the window
    /// opens at all.
    @Test
    func aCancelledCoreSimulatorRestartStopsNothing() async {
        let harness = Harness()
        harness.answer = .cancel
        let coordinator = harness.makeCoordinator()
        coordinator.coreSimulatorRestartRequested(tally: .unknown)
        await settle()
        #expect(harness.steps.isEmpty)
        #expect(harness.preStopReasons.isEmpty)
    }

    /// The acknowledged cost of stopping the service first: a termination that
    /// then fails leaves a live helper holding handles into a service that is
    /// already gone. The sequence stops rather than reconnecting, and `report`
    /// is what tells the user, with the remedy the outcome earns: a refused
    /// signal advises logging out, an unreported peer advises retrying and
    /// then reopening deviceterm.
    ///
    /// Pinned because it is the one state this ordering is worse in, and a
    /// future change that silently reconnected here would paper over it.
    @Test(arguments: [
        HelperTerminationOutcome.failed("refused"),
        .unknownPeer
    ])
    func aFailedHelperStopHaltsWithTheServiceAlreadyStopped(
        outcome: HelperTerminationOutcome
    ) async {
        let harness = Harness()
        harness.outcome = outcome
        let coordinator = harness.makeCoordinator()
        coordinator.coreSimulatorRestartRequested(tally: .unknown)
        await settle()
        #expect(harness.steps == ["beforeHelperStopped", "terminate"])
        #expect(harness.reports == [outcome])
    }

    /// The `xpc` line written for the kill names a pid and a generation and
    /// cannot say who asked. These two lines are the only record of that, and
    /// of what the user answered, so a log read after an incident can tell a
    /// diagnosis from a menu choice.
    @Test(arguments: [
        (HelperRestartReason.unresponsive, "unresponsive"),
        (.requested, "requested"),
        (.coreSimulator(CoreSimulatorRestartDecision.Tally(booted: 2, owned: 1)), "coreSimulator")
    ])
    func aRestartLogsItsReasonWhenPromptedAndWhenTerminating(
        reason: HelperRestartReason,
        label: String
    ) async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()
        switch reason {
        case .unresponsive:
            coordinator.helperStoppedAnswering(connection: harness.generation)

        case .requested:
            coordinator.restartRequested()

        case let .coreSimulator(tally):
            coordinator.coreSimulatorRestartRequested(tally: tally)
        }
        await settle()
        #expect(harness.logs == [
            "helper restart prompted reason=\(label) choice=restart",
            "helper termination reason=\(label) outcome=terminated pid=42"
        ])
        #expect(
            harness.logStepCounts == [0, 2],
            "the prompt line precedes the sequence; the termination line follows the stop and the kill"
        )
    }

    /// A declined prompt still leaves a line, so a log full of silence after
    /// an unanswered call reads as a user choosing to wait, not as a detector
    /// that never fired.
    @Test
    func keepWaitingLogsThePromptAndNothingElse() async {
        let harness = Harness()
        harness.answer = .keepWaiting
        let coordinator = harness.makeCoordinator()
        coordinator.helperStoppedAnswering(connection: harness.generation)
        await settle()
        #expect(harness.logs == ["helper restart prompted reason=unresponsive choice=keepWaiting"])
    }

    /// The window is reason-scoped: an ordinary helper restart opens it too,
    /// and whoever is wired into it has to be able to tell the two apart, or
    /// Restart Helper… would quietly become the destructive one.
    @Test
    func anOrdinaryRestartOpensTheWindowWithItsOwnReason() async {
        let harness = Harness()
        let coordinator = harness.makeCoordinator()
        coordinator.restartRequested()
        await settle()
        #expect(harness.preStopReasons == [.requested])
    }
}
