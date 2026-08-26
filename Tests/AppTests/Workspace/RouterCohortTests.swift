// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

/// Router cohort curation against the fake daemon: eager reconciles on tab
/// and terminal creation, `beginClose` ahead of session closes, the verdict
/// landing in the boot-claim tombstone, and the reap-race fallback.
@MainActor
struct RouterCohortTests {
    /// A far-future relay deadline so the claim outlives the assertion.
    private var relayDeadline: UInt64 {
        DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    }

    /// Let the serial drain and the off-drain cohort tasks run (the fake
    /// daemon is instant).
    private func settle(nanoseconds: UInt64 = 50_000_000) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func makeRouter(_ fake: FakeDaemonClient) -> (Router, WorkspaceViewModel) {
        let workspace = WorkspaceViewModel()
        let router = Router(
            workspace: workspace,
            daemon: fake,
            detectWorktreeName: { nil }
        )
        return (router, workspace)
    }

    private func shimClaim() -> BootClaimEvidence {
        BootClaimEvidence(
            attemptId: UUID().uuidString,
            udid: "33333333-3333-3333-3333-333333333333",
            source: .shim,
            observedState: .booting
        )
    }

    /// Open a window whose tab holds two terminals, S1 (primary) and S2.
    private func makeTwoTerminalTab(
        _ fake: FakeDaemonClient
    ) async -> (Router, WorkspaceViewModel) {
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        return (router, workspace)
    }

    @Test
    func newTabReconcilesItsCohort() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tab = workspace.windows.first?.tabs.tabs.first
        #expect(fake.setCohortCalls.count == 1)
        let call = fake.setCohortCalls.first
        #expect(call?.operation == .reconcile)
        #expect(call?.cohortId == tab?.cohortId.uuidString)
        #expect(call?.members == ["S"])
        #expect(call?.representative == "S")
        #expect(call?.replaces == nil)
        #expect(call?.bindings?.isEmpty == true)
    }

    @Test
    func addedTerminalJoinsTheCohortInOrder() async {
        let fake = FakeDaemonClient()
        let (_, workspace) = await makeTwoTerminalTab(fake)
        let calls = fake.setCohortCalls
        #expect(calls.count == 2)
        // Complete ordered membership, primary first: the array order is the
        // daemon's inheritance order, so it must equal the GUI's own
        // terminals[0] promotion rule.
        #expect(calls.last?.operation == .reconcile)
        #expect(calls.last?.members == ["S1", "S2"])
        #expect(calls.last?.representative == "S1")
        // One cohort id for the tab's whole life, fresh revision per send.
        #expect(calls.first?.cohortId == calls.last?.cohortId)
        #expect(calls.count == 2 && calls[1].revision > calls[0].revision)
        #expect(
            workspace.windows.first?.tabs.tabs.first?.cohortId.uuidString
                == calls.first?.cohortId
        )
    }

    @Test
    func rejectedReconcileRetriesFromLiveState() async {
        let fake = FakeDaemonClient()
        fake.setCohortApplied = [false, true]
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle(nanoseconds: 1_000_000_000)
        let calls = fake.setCohortCalls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.operation == .reconcile })
        // Same request re-derived, never a replayed revision.
        #expect(calls.count == 2 && calls[1].revision > calls[0].revision)
        #expect(calls.first?.members == calls.last?.members)
    }

    @Test
    func closingATerminalCommitsThePromotionFirst() async {
        let fake = FakeDaemonClient()
        fake.reconcileBootClaimStatus = .pending
        let (router, workspace) = await makeTwoTerminalTab(fake)
        fake.setCohortOutcomes = [.promote(successor: "S1")]
        guard let terminal = workspace.windows.first?.tabs.tabs.first?.terminals.last else {
            Issue.record("expected a second terminal")
            return
        }
        router.dispatch(
            .closeTerminalPane(tab: TabID(value: 1), terminal: terminal.id, mode: .detach)
        )
        await settle()

        // Exactly one beginClose, after the two membership reconciles; a
        // terminal close triggers no reconcile of its own (the daemon
        // already converged the membership when it committed the verdict).
        #expect(fake.setCohortCalls.count == 3)
        let begin = fake.setCohortCalls.last
        #expect(begin?.operation == .beginClose)
        #expect(begin?.leaving == ["S2"])
        #expect(begin?.mode == .detach)
        #expect(begin?.transitionId != nil)
        #expect(fake.closeSessionCalls.map(\.sessionId) == ["S2"])

        // The tombstone recorded the daemon's verdict: a claim naming the
        // closed session follows the successor, still attaching.
        router.acceptBootClaim(
            sessionId: "S2",
            claim: shimClaim(),
            deadlineNanoseconds: relayDeadline
        )
        await settle()
        let sent = fake.reconcileBootClaimCalls.last
        #expect(sent?.sessionId == "S1")
        #expect(sent?.claim.disposition == .attach)
    }

    @Test
    func closeTabSendsOneBeginCloseNamingEveryTerminal() async {
        let fake = FakeDaemonClient()
        fake.reconcileBootClaimStatus = .pending
        let (router, _) = await makeTwoTerminalTab(fake)
        router.dispatch(
            .closeTab(WindowID(value: 1), TabID(value: 1), mode: .shutdown)
        )
        await settle()

        let begins = fake.setCohortCalls.filter { $0.operation == .beginClose }
        #expect(begins.count == 1)
        #expect(begins.first?.leaving == ["S1", "S2"])
        #expect(begins.first?.mode == .shutdown)
        #expect(fake.closeSessionCalls.map(\.sessionId) == ["S1", "S2"])

        // Whole membership leaving: the verdict is terminal, and a late
        // claim naming either session takes the shutdown disposition.
        router.acceptBootClaim(
            sessionId: "S1",
            claim: shimClaim(),
            deadlineNanoseconds: relayDeadline
        )
        await settle()
        let sent = fake.reconcileBootClaimCalls.last
        #expect(sent?.sessionId == nil)
        #expect(sent?.claim.disposition == .shutdown)
    }

    @Test
    func refusedBeginCloseProceedsOnTheBinaryTombstone() async {
        let fake = FakeDaemonClient()
        fake.reconcileBootClaimStatus = .pending
        let (router, workspace) = await makeTwoTerminalTab(fake)
        // The reap race: the daemon already tore the named session down, so
        // beginClose answers applied: false. The close must proceed anyway.
        fake.setCohortApplied = [false]
        guard let terminal = workspace.windows.first?.tabs.tabs.first?.terminals.last else {
            Issue.record("expected a second terminal")
            return
        }
        router.dispatch(
            .closeTerminalPane(tab: TabID(value: 1), terminal: terminal.id, mode: .detach)
        )
        await settle()

        #expect(fake.closeSessionCalls.map(\.sessionId) == ["S2"])
        #expect(workspace.windows.first?.tabs.tabs.first?.terminals.count == 1)

        // Degraded but recorded: the fallback maps detach mode directly to
        // the detach disposition.
        router.acceptBootClaim(
            sessionId: "S2",
            claim: shimClaim(),
            deadlineNanoseconds: relayDeadline
        )
        await settle()
        let sent = fake.reconcileBootClaimCalls.last
        #expect(sent?.sessionId == nil)
        #expect(sent?.claim.disposition == .detach)
    }

    @Test
    func indeterminateBeginCloseRetriesTheSameTransition() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = await makeTwoTerminalTab(fake)
        fake.setCohortFailures = [
            DaemonClientError.transport("lost"),
            DaemonClientError.transport("lost"),
            nil
        ]
        fake.setCohortOutcomes = [.promote(successor: "S1")]
        guard let terminal = workspace.windows.first?.tabs.tabs.first?.terminals.last else {
            Issue.record("expected a second terminal")
            return
        }
        router.dispatch(
            .closeTerminalPane(tab: TabID(value: 1), terminal: terminal.id, mode: .detach)
        )
        // Two backoffs (200ms, 400ms) sit between the three sends.
        await settle(nanoseconds: 1_500_000_000)

        let begins = fake.setCohortCalls.filter { $0.operation == .beginClose }
        #expect(begins.count == 3)
        // One transitionId for the gesture, so the daemon's journal can
        // answer a retry; revisions stay fresh per send.
        #expect(Set(begins.map(\.transitionId)).count == 1)
        #expect(begins.map(\.revision) == begins.map(\.revision).sorted())
        #expect(Set(begins.map(\.revision)).count == 3)
        #expect(fake.closeSessionCalls.map(\.sessionId) == ["S2"])
    }

    @Test
    func exhaustedBeginCloseFallsBackAndCloses() async {
        let fake = FakeDaemonClient()
        fake.reconcileBootClaimStatus = .pending
        let (router, workspace) = await makeTwoTerminalTab(fake)
        router.cohortCloseDeadlineNanos = 300_000_000
        fake.setCohortFailures = Array(
            repeating: DaemonClientError.transport("lost"),
            count: 8
        )
        guard let terminal = workspace.windows.first?.tabs.tabs.first?.terminals.last else {
            Issue.record("expected a second terminal")
            return
        }
        router.dispatch(
            .closeTerminalPane(tab: TabID(value: 1), terminal: terminal.id, mode: .detach)
        )
        // Twice the 300ms deadline: this settle is the wall-clock pin. The
        // backoff between failed sends is capped to the remaining budget,
        // so the close cannot overrun the deadline by a backoff step.
        await settle(nanoseconds: 600_000_000)

        // The gesture is bounded: the daemon never answered, the close ran
        // anyway, and the binary tombstone stands in for the verdict.
        #expect(fake.closeSessionCalls.map(\.sessionId) == ["S2"])
        router.acceptBootClaim(
            sessionId: "S2",
            claim: shimClaim(),
            deadlineNanoseconds: relayDeadline
        )
        await settle()
        let sent = fake.reconcileBootClaimCalls.last
        #expect(sent?.sessionId == nil)
        #expect(sent?.claim.disposition == .detach)
    }

    @Test
    func mountedPaneRekicksTheReconcileWithItsBinding() async {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            attachment: 7,
            family: "phone"
        )
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()

        // A successful mount re-kicks the tab's reconcile so a pane that
        // raced the cohort install still gets a binding carried for it.
        #expect(fake.setCohortCalls.count == 2)
        let last = fake.setCohortCalls.last
        #expect(last?.operation == .reconcile)
        #expect(last?.bindings == [SessionCohortBinding(paneId: "P1", expectedAttachment: 7)])
    }

    @Test
    func refusedBindingIsCarriedAgainOnTheNextSend() async {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            attachment: 7,
            family: "phone"
        )
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        // The mount's reconcile answers applied with the pane's binding
        // refused; the Router must treat that as not-yet-converged and
        // resend rather than accepting the applied reply as complete.
        fake.setCohortRefusedBindings = [["P1"]]
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle(nanoseconds: 1_000_000_000)

        let reconciles = fake.setCohortCalls.filter { $0.operation == .reconcile }
        #expect(reconciles.count == 3)
        #expect(reconciles.last?.bindings == [
            SessionCohortBinding(paneId: "P1", expectedAttachment: 7)
        ])
        #expect(
            reconciles.count == 3
                && reconciles[2].revision > reconciles[1].revision
        )
    }

    @Test
    func stalledBeginCloseDoesNotHoldTheClose() async {
        let fake = FakeDaemonClient()
        fake.reconcileBootClaimStatus = .pending
        let (router, workspace) = await makeTwoTerminalTab(fake)
        router.cohortCloseDeadlineNanos = 200_000_000
        fake.armSetCohortBarrier()
        guard let terminal = workspace.windows.first?.tabs.tabs.first?.terminals.last else {
            Issue.record("expected a second terminal")
            return
        }
        router.dispatch(
            .closeTerminalPane(tab: TabID(value: 1), terminal: terminal.id, mode: .detach)
        )
        await settle(nanoseconds: 800_000_000)

        // The request never answered and is still parked, and the close
        // proceeded on the fallback at the deadline instead of waiting out
        // the client's own request bound.
        #expect(fake.setCohortsWaiting == 1)
        #expect(fake.closeSessionCalls.map(\.sessionId) == ["S2"])
        router.acceptBootClaim(
            sessionId: "S2",
            claim: shimClaim(),
            deadlineNanoseconds: relayDeadline
        )
        await settle()
        let sent = fake.reconcileBootClaimCalls.last
        #expect(sent?.sessionId == nil)
        #expect(sent?.claim.disposition == .detach)
        fake.releaseSetCohort()
    }

    @Test
    func reconcileAllCohortsReinstallsEveryTab() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        let creationCalls = fake.setCohortCalls.count
        let cohortIds = workspace.windows
            .flatMap { $0.tabs.tabs.map(\.cohortId.uuidString) }

        await router.reconcileAllCohorts()

        // One awaited send per tab, addressed to each tab's retained cohort
        // id: the same ids the creation-time reconciles installed, which is
        // what revives the emptied records after a daemon restart.
        let replays = fake.setCohortCalls.dropFirst(creationCalls)
        #expect(replays.count == 2)
        #expect(replays.allSatisfy { $0.operation == .reconcile })
        #expect(replays.map(\.cohortId).sorted() == cohortIds.sorted())
    }
}
