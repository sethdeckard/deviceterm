// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionCohortStateTests: the cohort reducer, exercised directly.
//
// The reducer is a value type with no clock, no actor and no I/O, so every
// ordering and lifecycle rule is testable without racing anything. What these
// pin is the arithmetic of membership: who may drive a pane, who a reconcile
// removed, and which ids are dead for good.
//
// The rules that keep coming back wrong, and so get explicit coverage:
// "the cohort is gone" must never read as "this pane never had one"; a retired
// id must stay retired however fresh the request; an emptied id must stay
// *revivable*, because the GUI retains one id per tab across restores; and a
// verdict about a member is keyed to an exact incarnation.

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

struct SessionCohortStateTests {
    // MARK: - Helpers

    /// Every member live, which is the ordinary case.
    private let allLive: (CohortMember) -> Bool = { _ in true }

    private func uuid(_ seed: Int) -> UUID {
        let value = UInt32(truncatingIfNeeded: seed)
        return UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ))
    }

    private func member(_ seed: Int, incarnation: UInt64 = 1) -> CohortMember {
        CohortMember(sessionId: uuid(seed), incarnation: incarnation)
    }

    private func key(_ revision: Int, epoch: UInt64 = 1) -> ProtectionOrderingKey {
        ProtectionOrderingKey(epoch: epoch, revision: revision)
    }

    @discardableResult
    private func install(
        _ state: inout SessionCohortState,
        cohortId: UUID,
        members: [CohortMember],
        revision: Int = 1,
        replaces: UUID? = nil,
        isLive: ((CohortMember) -> Bool)? = nil,
        bindingsSucceed: Bool = true
    ) -> CohortTransition {
        state.reconcile(
            cohortId: cohortId,
            members: members,
            representative: members[0].sessionId,
            replaces: replaces,
            key: key(revision),
            isLive: isLive ?? allLive,
            bindingsSucceed: bindingsSucceed
        )
    }

    // MARK: - Authorization resolution

    @Test("an unbound record falls back, a live cohort admits its members")
    func resolvesUnboundAndLive() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        #expect(state.resolve(cohortId: nil) == .unbound)
        #expect(
            state.resolve(cohortId: cohort)
                == .live(members: [member(10), member(11)], representative: uuid(10))
        )
    }

    @Test("a record naming an unknown cohort is denied, never unbound")
    func deniesUnknownCohort() {
        let state = SessionCohortState()
        #expect(state.resolve(cohortId: uuid(99)) == .denied)
    }

    @Test("a record naming a retired cohort is denied, never unbound")
    func deniesRetiredCohort() {
        var state = SessionCohortState()
        install(&state, cohortId: uuid(1), members: [member(10)])
        install(&state, cohortId: uuid(2), members: [member(10)], revision: 2, replaces: uuid(1))
        #expect(state.resolve(cohortId: uuid(1)) == .denied)
    }

    // MARK: - Reconcile

    @Test("a representative outside the submitted members is refused")
    func refusesForeignRepresentative() {
        var state = SessionCohortState()
        let transition = state.reconcile(
            cohortId: uuid(1),
            members: [member(10)],
            representative: uuid(11),
            replaces: nil,
            key: key(1),
            isLive: allLive,
            bindingsSucceed: true
        )
        #expect(transition.rejection == .representativeNotAMember)
    }

    @Test("a stale key does not replace a live cohort")
    func refusesStaleKey() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10)], revision: 5)
        let transition = install(
            &state,
            cohortId: cohort,
            members: [member(10), member(11)],
            revision: 4
        )
        #expect(transition.rejection == .staleKey)
        #expect(
            state.resolve(cohortId: cohort)
                == .live(members: [member(10)], representative: uuid(10))
        )
    }

    @Test("a member cannot join a second cohort without naming the first")
    func refusesCrossCohortPlacement() {
        var state = SessionCohortState()
        install(&state, cohortId: uuid(1), members: [member(10)])
        let transition = install(&state, cohortId: uuid(2), members: [member(10)])
        #expect(transition.rejection == .memberInForeignCohort)
    }

    @Test("a member that closed before the commit is not installed")
    func refusesADeadMember() {
        var state = SessionCohortState()
        // Liveness is resolved by the caller before the handler runs, so the
        // reducer re-checks it at commit: a session that closed in between must
        // not be installed, or it sits in the cohort with authority it no
        // longer holds.
        let transition = state.reconcile(
            cohortId: uuid(1),
            members: [member(10), member(11)],
            representative: uuid(10),
            replaces: nil,
            key: key(1),
            isLive: { $0.sessionId != self.uuid(11) },
            bindingsSucceed: true
        )
        #expect(transition.rejection == .memberNotLive)
    }

    @Test("a replacement is ordered against the outgoing cohort too")
    func replacementRespectsTheOutgoingKey() {
        var state = SessionCohortState()
        install(&state, cohortId: uuid(1), members: [member(10)], revision: 9)
        // A fresh cohort id has no stored key of its own, so ordering has to
        // come from the cohort being retired.
        let transition = install(
            &state,
            cohortId: uuid(2),
            members: [member(10)],
            revision: 4,
            replaces: uuid(1)
        )
        #expect(transition.rejection == .staleKey)
        #expect(state.cohortId(forMember: member(10)) == uuid(1))
    }

    @Test("a replacement that cannot rebind every pane is refused whole")
    func replacementRejectsRefusedBindings() {
        var state = SessionCohortState()
        install(&state, cohortId: uuid(1), members: [member(10)])
        let transition = install(
            &state,
            cohortId: uuid(2),
            members: [member(10)],
            revision: 2,
            replaces: uuid(1),
            bindingsSucceed: false
        )
        #expect(transition.rejection == .bindingRefused)
        #expect(state.cohortId(forMember: member(10)) == uuid(1))
    }

    @Test("a replacement strips the members it does not keep")
    func replacementStripsDroppedMembers() {
        var state = SessionCohortState()
        install(&state, cohortId: uuid(1), members: [member(10), member(11)])
        // Keeps only 11. From this commit on, 10 belongs to no cohort and is
        // free to be placed elsewhere; the coordinator's post-commit sweep is
        // what tears down any stream it still held.
        let transition = state.reconcile(
            cohortId: uuid(2),
            members: [member(11)],
            representative: uuid(11),
            replaces: uuid(1),
            key: key(2),
            isLive: allLive,
            bindingsSucceed: true
        )
        #expect(transition.applied)
        #expect(state.cohortId(forMember: member(10)) == nil)
        #expect(
            state.resolve(cohortId: uuid(2))
                == .live(members: [member(11)], representative: uuid(11))
        )
    }

    @Test("a same-id resubmission strips the members it omits")
    func shrinkStripsOmittedMembers() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        let transition = install(&state, cohortId: cohort, members: [member(10)], revision: 2)
        #expect(transition.applied)
        #expect(state.cohortId(forMember: member(11)) == nil)
        #expect(
            state.resolve(cohortId: cohort)
                == .live(members: [member(10)], representative: uuid(10))
        )
    }

    @Test("a retired id can never be reconciled again")
    func retiredIdStaysRetired() {
        var state = SessionCohortState()
        install(&state, cohortId: uuid(1), members: [member(10)])
        install(&state, cohortId: uuid(2), members: [member(10)], revision: 2, replaces: uuid(1))
        // Nothing remembers a deleted cohort's ordering key, so without the
        // tombstone this delayed request would face no staleness check at all
        // and could rebuild the cohort its replacement retired.
        let asTarget = install(&state, cohortId: uuid(1), members: [member(11)], revision: 99)
        #expect(asTarget.rejection == .cohortRetired)
        let asReplaces = install(
            &state,
            cohortId: uuid(3),
            members: [member(11)],
            revision: 99,
            replaces: uuid(1)
        )
        #expect(asReplaces.rejection == .cohortRetired)
        #expect(state.resolve(cohortId: uuid(1)) == .denied)
    }

    @Test("a restored session at a new incarnation is a different member")
    func incarnationDistinguishesMembers() {
        var state = SessionCohortState()
        install(&state, cohortId: uuid(1), members: [member(10, incarnation: 1)])
        #expect(state.cohortId(forMember: member(10, incarnation: 2)) == nil)
    }

    // MARK: - Teardown

    @Test("teardown removes the member and reattributes the representative")
    func tearDownRemovesTheMember() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11), member(12)])
        _ = state.tearDown(member: member(10), now: 1_000)
        #expect(
            state.resolve(cohortId: cohort)
                == .live(members: [member(11), member(12)], representative: uuid(11))
        )
        #expect(state.cohortId(forMember: member(10)) == nil)
    }

    @Test("teardown of an old incarnation leaves the restored member alone")
    func tearDownIsExactOnIncarnation() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10, incarnation: 2), member(11)])
        // A delayed teardown of incarnation 1 arrives after the same UUID was
        // restored and reconciled at incarnation 2. Evicting by session id
        // would remove the member the GUI just verified.
        _ = state.tearDown(member: member(10, incarnation: 1), now: 1_000)
        #expect(
            state.resolve(cohortId: cohort)
                == .live(
                    members: [member(10, incarnation: 2), member(11)],
                    representative: uuid(10)
                )
        )
    }

    @Test("an emptied id refuses sessions, keeps its key, and stays revivable")
    func emptiedCohortSurvivesForReuse() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10)], revision: 5)
        _ = state.tearDown(member: member(10), now: 1_000)
        // Empty membership admits nobody, but the id is not dead: the GUI
        // retains one cohort id per tab across restores, so a reap that
        // empties it must not brick the tab's next reconcile.
        #expect(state.resolve(cohortId: cohort) == .live(members: [], representative: uuid(10)))
        let stale = install(&state, cohortId: cohort, members: [member(11)], revision: 4)
        #expect(stale.rejection == .staleKey)
        let revived = install(&state, cohortId: cohort, members: [member(11)], revision: 6)
        #expect(revived.applied)
        #expect(
            state.resolve(cohortId: cohort)
                == .live(members: [member(11)], representative: uuid(11))
        )
    }

    // MARK: - Close verdicts

    @Test("a departing member's verdict promotes to the first survivor in order")
    func beginClosePromotesInMemberOrder() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11), member(12)])
        let commit = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .shutdown,
            key: key(2),
            now: 1_000
        )
        #expect(commit.applied)
        #expect(commit.outcome == .promote(successor: uuid(11).uuidString))
        #expect(commit.closed == [member(10)])
        #expect(commit.successor == member(11))
        #expect(
            state.resolve(cohortId: cohort)
                == .live(members: [member(11), member(12)], representative: uuid(11))
        )
    }

    @Test("the last members out take the requested mode", arguments: [
        (PaneCloseMode.detach, CohortCloseOutcome.detach),
        (PaneCloseMode.shutdown, CohortCloseOutcome.shutdown)
    ])
    func beginCloseTerminalTakesRequestedMode(mode: PaneCloseMode, expected: CohortCloseOutcome) {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        let commit = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(10), uuid(11)],
            mode: mode,
            key: key(2),
            now: 1_000
        )
        #expect(commit.outcome == expected)
        #expect(commit.closed.count == 2)
        #expect(commit.successor == nil)
        // Emptied, not retired: the id keeps its key and stays revivable.
        #expect(state.resolve(cohortId: cohort) == .live(members: [], representative: uuid(10)))
    }

    @Test("a repeated transition id replays the verdict without removing again")
    func beginCloseIsIdempotent() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        let transition = uuid(500)
        let first = state.beginClose(
            cohortId: cohort,
            transitionId: transition,
            leaving: [uuid(10)],
            mode: .detach,
            key: key(2),
            now: 1_000
        )
        // The retry arrives after the cohort has already lost that member and
        // carries a fresh revision, as a post-loss retry would.
        let retry = state.beginClose(
            cohortId: cohort,
            transitionId: transition,
            leaving: [uuid(10)],
            mode: .detach,
            key: key(3),
            now: 1_000
        )
        #expect(first.outcome == .promote(successor: uuid(11).uuidString))
        #expect(retry.applied)
        #expect(retry.outcome == first.outcome)
        // Nothing left for the caller to re-home or emit.
        #expect(retry.closed.isEmpty)
        #expect(
            state.resolve(cohortId: cohort)
                == .live(members: [member(11)], representative: uuid(11))
        )
    }

    @Test("a transition naming no member of the cohort is not a close")
    func beginCloseRejectsATransitionWithNoMembers() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        // Reporting an applied verdict would claim a close that removed
        // nobody, and burn the transition id so a corrected retry could not
        // repair it.
        let commit = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(77)],
            mode: .detach,
            key: key(2),
            now: 1_000
        )
        #expect(!commit.applied)
        let corrected = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .detach,
            key: key(3),
            now: 1_000
        )
        #expect(corrected.outcome == .promote(successor: uuid(11).uuidString))
    }

    @Test("a stale key rejects a close without recording anything")
    func beginCloseRefusesStaleKey() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)], revision: 5)
        let commit = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .detach,
            key: key(4),
            now: 1_000
        )
        #expect(!commit.applied)
        #expect(
            state.resolve(cohortId: cohort)
                == .live(members: [member(10), member(11)], representative: uuid(10))
        )
    }

    @Test("a close for an unknown or retired cohort still yields a verdict")
    func beginCloseOnAGoneCohortJournalsTheMode() {
        var state = SessionCohortState()
        let commit = state.beginClose(
            cohortId: uuid(9),
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .shutdown,
            key: key(1),
            now: 1_000
        )
        // The GUI still needs an authoritative answer to proceed with the
        // close, and there are no members left to decide for.
        #expect(commit.applied)
        #expect(commit.outcome == .shutdown)
        #expect(commit.closed.isEmpty)
    }

    @Test("an explicit close derives the same promotion beginClose would")
    func recordCloseVerdictPromotes() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        let decision = state.recordCloseVerdict(member: member(10), mode: .shutdown, now: 1_000)
        #expect(
            decision
                == .decided(
                    outcome: .promote(successor: uuid(11).uuidString),
                    successor: member(11)
                )
        )
        #expect(
            state.resolve(cohortId: cohort)
                == .live(members: [member(11)], representative: uuid(11))
        )
    }

    @Test("an explicit close after beginClose decides nothing twice")
    func recordCloseVerdictConsumesTheRecordedVerdict() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        _ = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .detach,
            key: key(2),
            now: 1_000
        )
        // Deciding again here is the shape that once demoted a committed
        // promotion to detach because the member was no longer in the cohort.
        #expect(
            state.recordCloseVerdict(member: member(10), mode: .detach, now: 1_000)
                == .alreadyRecorded
        )
    }

    @Test("a member of no cohort takes the terminal mode")
    func recordCloseVerdictOutsideACohortIsTerminal() {
        var state = SessionCohortState()
        let decision = state.recordCloseVerdict(member: member(10), mode: .shutdown, now: 1_000)
        #expect(decision == .decided(outcome: .shutdown, successor: nil))
    }

    // MARK: - Teardown dispositions

    @Test("teardown after a recorded verdict owes nothing")
    func tearDownConsumesARecordedVerdict() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        _ = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .detach,
            key: key(2),
            now: 1_000
        )
        #expect(state.tearDown(member: member(10), now: 1_000) == .alreadyDecided)
        #expect(
            state.resolve(cohortId: cohort)
                == .live(members: [member(11)], representative: uuid(11))
        )
    }

    @Test("a reaped member of a live tab promotes to the survivors")
    func tearDownWithSurvivorsPromotes() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        #expect(
            state.tearDown(member: member(10), now: 1_000)
                == .promoted(successor: member(11))
        )
    }

    @Test("a reaped last member is terminal, and a stranger is too")
    func tearDownWithoutSurvivorsIsTerminal() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10)])
        #expect(state.tearDown(member: member(10), now: 1_000) == .terminal)
        #expect(state.tearDown(member: member(99), now: 1_000) == .terminal)
    }

    @Test("a restored incarnation cannot consume the old one's verdict")
    func restoredIncarnationDoesNotInheritAVerdict() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10, incarnation: 1), member(11)])
        _ = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .detach,
            key: key(2),
            now: 1_000
        )
        // Same UUID, new incarnation, in no cohort: its close decides fresh
        // rather than replaying the promotion an earlier incarnation earned.
        #expect(
            state.recordCloseVerdict(member: member(10, incarnation: 7), mode: .shutdown, now: 1_000)
                == .decided(outcome: .shutdown, successor: nil)
        )
    }

    @Test("verdicts and journal entries expire on the boot-claim lease")
    func verdictsExpireOnTheLease() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        _ = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .detach,
            key: key(2),
            now: 1_000
        )
        let past = 1_000 &+ SessionCohortState.retentionNanoseconds &+ 1
        // Past retention, the journal no longer replays: a same-id request is
        // judged fresh, and here it names a member the cohort no longer has.
        let late = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .detach,
            key: key(3),
            now: past
        )
        #expect(!late.applied)
    }

    // MARK: - Close and reconcile interlock

    @Test("a close-decided member cannot be reconciled back in")
    func closedMemberCannotBeReconciledBack() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        _ = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .detach,
            key: key(2),
            now: 1_000
        )
        // Between beginClose and the actual session.close the member is still
        // live, so liveness alone would admit it. Its verdict is committed
        // and possibly applied; reinstalling would revive the authorization
        // the close withdrew.
        let revived = install(
            &state,
            cohortId: cohort,
            members: [member(10), member(11)],
            revision: 3
        )
        #expect(revived.rejection == .memberClosed)
        // The next incarnation carries no verdict and installs freely.
        let restored = install(
            &state,
            cohortId: cohort,
            members: [member(10, incarnation: 2), member(11)],
            revision: 4
        )
        #expect(restored.applied)
    }

    @Test("a duplicated member is refused")
    func duplicateMembersAreRefused() {
        var state = SessionCohortState()
        let transition = install(&state, cohortId: uuid(1), members: [member(10), member(10)])
        #expect(transition.rejection == .duplicateMember)
    }

    @Test("beginClose is all-or-none over the named ids")
    func beginCloseIsAllOrNoneOverTheNamedIds() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        // One named id is foreign. A partial commit would return one verdict
        // as the authoritative answer for a session it never decided.
        let commit = state.beginClose(
            cohortId: cohort,
            transitionId: uuid(500),
            leaving: [uuid(10), uuid(77)],
            mode: .detach,
            key: key(2),
            now: 1_000
        )
        #expect(!commit.applied)
        #expect(
            state.resolve(cohortId: cohort)
                == .live(members: [member(10), member(11)], representative: uuid(10))
        )
    }

    @Test("a journal replay answers only the request that earned it")
    func journalReplayIsBoundToItsRequest() {
        var state = SessionCohortState()
        let cohort = uuid(1)
        install(&state, cohortId: cohort, members: [member(10), member(11)])
        let transition = uuid(500)
        _ = state.beginClose(
            cohortId: cohort,
            transitionId: transition,
            leaving: [uuid(10)],
            mode: .detach,
            key: key(2),
            now: 1_000
        )
        // Same id, different member set: reporting the old verdict as
        // applied would record the wrong answer for 11.
        let differentLeaving = state.beginClose(
            cohortId: cohort,
            transitionId: transition,
            leaving: [uuid(11)],
            mode: .detach,
            key: key(3),
            now: 1_000
        )
        #expect(!differentLeaving.applied)
        let differentMode = state.beginClose(
            cohortId: cohort,
            transitionId: transition,
            leaving: [uuid(10)],
            mode: .shutdown,
            key: key(4),
            now: 1_000
        )
        #expect(!differentMode.applied)
        let exact = state.beginClose(
            cohortId: cohort,
            transitionId: transition,
            leaving: [uuid(10)],
            mode: .detach,
            key: key(5),
            now: 1_000
        )
        #expect(exact.applied)
        #expect(exact.outcome == .promote(successor: uuid(11).uuidString))
    }

    @Test("a retired cohort's close cannot decide for relocated members")
    func retiredCohortCloseCannotDecideForRelocatedMembers() {
        var state = SessionCohortState()
        install(&state, cohortId: uuid(1), members: [member(10)])
        install(&state, cohortId: uuid(2), members: [member(10)], revision: 2, replaces: uuid(1))
        // The delayed close names the retired cohort, but 10 now lives in the
        // replacement. A terminal verdict here would disagree with the
        // promotion its real close derives there.
        let stale = state.beginClose(
            cohortId: uuid(1),
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .shutdown,
            key: key(3),
            now: 1_000
        )
        #expect(!stale.applied)
        // The transition id was not burned: the corrected request decides.
        let corrected = state.beginClose(
            cohortId: uuid(2),
            transitionId: uuid(500),
            leaving: [uuid(10)],
            mode: .shutdown,
            key: key(4),
            now: 1_000
        )
        #expect(corrected.applied)
        #expect(corrected.outcome == .shutdown)
    }
}
