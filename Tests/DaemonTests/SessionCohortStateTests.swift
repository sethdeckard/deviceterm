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
        state.tearDown(member: member(10))
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
        state.tearDown(member: member(10, incarnation: 1))
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
        state.tearDown(member: member(10))
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
}
