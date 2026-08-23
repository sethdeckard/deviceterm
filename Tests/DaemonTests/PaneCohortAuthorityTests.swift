// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneCohortAuthorityTests: cohort authority as `PaneCoordinator` enforces it.
//
// Membership and pane records live in one actor, so a transition commits
// membership and bindings together. These tests work at that boundary, where a
// split design could leave the two halves disagreeing: a pane bound to a
// cohort that was never installed, a sibling refused because the pane carried
// someone else's incarnation, a removed member still holding a live stream.

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

struct PaneCohortAuthorityTests {
    // MARK: - Helpers

    private func member(_ sessionId: UUID, _ incarnation: UInt64) -> CohortMember {
        CohortMember(sessionId: sessionId, incarnation: incarnation)
    }

    private func key(_ revision: Int) -> ProtectionOrderingKey {
        ProtectionOrderingKey(epoch: 1, revision: revision)
    }

    /// A pane owned by `owner` at `incarnation`, the way a production create
    /// stamps it.
    private func pane(
        _ coordinator: PaneCoordinator,
        udid: String,
        owner: UUID,
        incarnation: UInt64
    ) async throws -> PaneCreateResult {
        try await coordinator.createPane(
            target: .sim(udid: udid),
            sessionId: owner,
            ownerIncarnation: incarnation,
            acquire: {
                PaneCoordinator.AcquiredBackend(
                    backend: MockDeviceBackend(),
                    family: "phone",
                    deviceType: "iPhone"
                )
            }
        )
    }

    /// Register sessions as live, which is what the reducer's commit-time
    /// liveness check reads.
    private func activate(_ coordinator: PaneCoordinator, _ members: [CohortMember]) async {
        for member in members {
            await coordinator.noteSessionActive(member.sessionId, incarnation: member.incarnation)
        }
    }

    /// Install a cohort over one freshly created pane and bind it.
    @discardableResult
    private func installCohort(
        _ coordinator: PaneCoordinator,
        cohortId: UUID,
        members: [CohortMember],
        created: PaneCreateResult,
        revision: Int = 1
    ) async -> CohortTransition {
        await coordinator.reconcileCohort(
            cohortId: cohortId,
            members: members,
            representative: members[0].sessionId,
            replaces: nil,
            requested: [
                SessionCohortBinding(
                    paneId: created.paneId.uuidString,
                    expectedAttachment: created.attachment
                )
            ],
            key: key(revision)
        )
    }

    // MARK: - Authorization

    @Test("every member of a cohort drives its pane, at its own incarnation")
    func siblingsDriveTheCohortsPane() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let cohort = UUID()
        await activate(coordinator, [alice, bob])
        let created = try await pane(
            coordinator,
            udid: "udid-a",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        let transition = await installCohort(
            coordinator,
            cohortId: cohort,
            members: [alice, bob],
            created: created
        )
        #expect(transition.applied)

        // Incarnations are daemon-global, so bob's differs from the one stamped
        // on the pane. Judging him against that stamp would refuse every
        // sibling in the tab.
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: bob.sessionId,
                incarnation: bob.incarnation
            )
        )
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: alice.sessionId,
                incarnation: alice.incarnation
            )
        )
        // The ABA gate still holds, against the member's own incarnation: bob
        // restored at a new one is a different member.
        #expect(
            !(await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: bob.sessionId,
                incarnation: 9
            ))
        )
    }

    @Test("a rejected reconcile leaves no pane bound to it")
    func rejectedReconcileBindsNothing() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let cohort = UUID()
        await activate(coordinator, [alice])
        let created = try await pane(
            coordinator,
            udid: "udid-b",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        // Refused on the representative, which is checked before anything
        // commits. Validate before binding: binding first would leave a pane
        // pointing at a cohort that was never installed.
        let transition = await coordinator.reconcileCohort(
            cohortId: cohort,
            members: [alice],
            representative: UUID(),
            replaces: nil,
            requested: [
                SessionCohortBinding(
                    paneId: created.paneId.uuidString,
                    expectedAttachment: created.attachment
                )
            ],
            key: key(1)
        )
        #expect(!transition.applied)
        // Still answers to its own session, because it was never rebound.
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: alice.sessionId,
                incarnation: alice.incarnation
            )
        )
    }

    @Test("a member that closed before the commit is refused, and binds nothing")
    func deadMemberIsRefused() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let ghost = member(UUID(), 4)
        let cohort = UUID()
        // Only alice is activated; the caller resolved ghost's incarnation
        // before it closed.
        await activate(coordinator, [alice])
        let created = try await pane(
            coordinator,
            udid: "udid-c",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        let transition = await installCohort(
            coordinator,
            cohortId: cohort,
            members: [alice, ghost],
            created: created
        )
        #expect(transition.rejection == .memberNotLive)
        #expect(await coordinator.panesBound(toCohort: cohort).isEmpty)
    }

    // MARK: - Membership removal

    @Test("a replacement revokes the dropped member's stream, not the kept one's")
    func replacementRevokesDroppedSubscriptions() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let old = UUID()
        let new = UUID()
        await activate(coordinator, [alice, bob])
        let created = try await pane(
            coordinator,
            udid: "udid-e",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: old, members: [alice, bob], created: created)
        // Both tuples are used through to the end of the test: dropping a
        // returned stream terminates its subscription, which is exactly the
        // teardown this test must not trigger by accident.
        let aliceSub = try await coordinator.subscribe(
            paneId: created.paneId,
            as: .session(alice.sessionId, incarnation: alice.incarnation)
        )
        let bobSub = try await coordinator.subscribe(
            paneId: created.paneId,
            as: .session(bob.sessionId, incarnation: bob.incarnation)
        )
        #expect(await coordinator.subscriberCount(paneId: created.paneId) == 2)

        // The replacement drops alice while she is still alive. The commit
        // withdraws her authorization per-request; this pins that her
        // already-admitted stream is torn down too, instead of receiving
        // frames indefinitely.
        let transition = await coordinator.reconcileCohort(
            cohortId: new,
            members: [bob],
            representative: bob.sessionId,
            replaces: old,
            requested: [],
            key: key(2)
        )
        #expect(transition.applied)
        // Drains to completion only because the revocation finished it.
        for await _ in aliceSub.stream {}
        #expect(await coordinator.subscriberCount(paneId: created.paneId) == 1)
        #expect(
            !(await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: alice.sessionId,
                incarnation: alice.incarnation
            ))
        )
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: bob.sessionId,
                incarnation: bob.incarnation
            )
        )
        // A real use after the assertions, so bob's stream cannot be released
        // (and its subscription torn down) before the count above is taken.
        await coordinator.unsubscribe(paneId: created.paneId, subscriptionId: bobSub.subscriptionId)
    }

    @Test("binding into a cohort revokes a non-member owner's stream")
    func bindingRevokesANonMemberOwnersStream() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let cohort = UUID()
        await activate(coordinator, [alice, bob])
        let created = try await pane(
            coordinator,
            udid: "udid-g",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        // Alice subscribes while the pane is unbound, on her own-session
        // compatibility authority.
        let aliceSub = try await coordinator.subscribe(
            paneId: created.paneId,
            as: .session(alice.sessionId, incarnation: alice.incarnation)
        )
        // The cohort that takes the pane does not include her. Membership is
        // now the only authority, so her admitted stream must fall with her
        // per-request access, not linger because no membership "removed" her.
        let transition = await installCohort(
            coordinator,
            cohortId: cohort,
            members: [bob],
            created: created
        )
        #expect(transition.applied)
        for await _ in aliceSub.stream {}
        #expect(await coordinator.subscriberCount(paneId: created.paneId) == 0)
        #expect(
            !(await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: alice.sessionId,
                incarnation: alice.incarnation
            ))
        )
    }

    @Test("a binding cannot take a pane another live cohort holds")
    func bindingRefusesAForeignLiveCohortsPane() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let cohortA = UUID()
        let cohortB = UUID()
        await activate(coordinator, [alice, bob])
        let created = try await pane(
            coordinator,
            udid: "udid-h",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: cohortA, members: [alice], created: created)
        // The attachment still matches, and cohort B's key is only ordered
        // against B's own history, so without the cohort fence this delayed
        // or misdirected request would move the pane out from under A.
        let transition = await installCohort(
            coordinator,
            cohortId: cohortB,
            members: [bob],
            created: created,
            revision: 2
        )
        #expect(transition.applied)
        #expect(transition.bindings.allSatisfy { !$0.bound })
        #expect(await coordinator.panesBound(toCohort: cohortA) == [created.paneId])
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: alice.sessionId,
                incarnation: alice.incarnation
            )
        )
        #expect(
            !(await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: bob.sessionId,
                incarnation: bob.incarnation
            ))
        )
    }

    @Test("a replacement that would take a foreign cohort's pane is refused whole")
    func replacementRefusesAForeignLiveCohortsPane() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let cohortA = UUID()
        let cohortB = UUID()
        let cohortC = UUID()
        await activate(coordinator, [alice, bob])
        let created = try await pane(
            coordinator,
            udid: "udid-i",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: cohortA, members: [alice], created: created)
        _ = await coordinator.reconcileCohort(
            cohortId: cohortB,
            members: [bob],
            representative: bob.sessionId,
            replaces: nil,
            requested: [],
            key: key(2)
        )
        // Replacement bindings are all-or-nothing, so the foreign pane does
        // not report per-pane failure: the whole request is refused and B
        // stays as it was.
        let transition = await coordinator.reconcileCohort(
            cohortId: cohortC,
            members: [bob],
            representative: bob.sessionId,
            replaces: cohortB,
            requested: [
                SessionCohortBinding(
                    paneId: created.paneId.uuidString,
                    expectedAttachment: created.attachment
                )
            ],
            key: key(3)
        )
        #expect(!transition.applied)
        #expect(await coordinator.panesBound(toCohort: cohortA) == [created.paneId])
        #expect(await coordinator.panesBound(toCohort: cohortC).isEmpty)
    }

    @Test("tearing down a sibling removes only that sibling's access")
    func teardownRemovesOnlyTheDepartingMember() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let cohort = UUID()
        await activate(coordinator, [alice, bob])
        let created = try await pane(
            coordinator,
            udid: "udid-d",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: cohort, members: [alice, bob], created: created)
        await coordinator.tearDownSession(bob.sessionId, incarnation: bob.incarnation)
        #expect(
            !(await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: bob.sessionId,
                incarnation: bob.incarnation
            ))
        )
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: alice.sessionId,
                incarnation: alice.incarnation
            )
        )
    }

    @Test("a torn-down member cannot be reinstalled by an in-flight reconcile")
    func teardownClearsLivenessInTheSameTurn() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let cohort = UUID()
        await activate(coordinator, [alice, bob])
        let created = try await pane(
            coordinator,
            udid: "udid-f",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: cohort, members: [alice, bob], created: created)
        // The teardown clears the producer-local active incarnation in its own
        // actor turn, so a reconcile whose handler resolved bob's incarnation
        // before the close fails its commit-time liveness check instead of
        // reinstalling the departed member.
        await coordinator.tearDownSession(bob.sessionId, incarnation: bob.incarnation)
        let transition = await coordinator.reconcileCohort(
            cohortId: cohort,
            members: [alice, bob],
            representative: alice.sessionId,
            replaces: nil,
            requested: [],
            key: key(2)
        )
        #expect(transition.rejection == .memberNotLive)
    }

    @Test("an unbound pane still answers to its own session")
    func unboundPaneKeepsLegacyOwner() async throws {
        let coordinator = PaneCoordinator()
        let alice = UUID()
        let created = try await coordinator.createMockPane(
            udid: "udid-unbound",
            sessionId: alice,
            backend: MockDeviceBackend()
        )
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: alice,
                incarnation: nil
            )
        )
        #expect(
            !(await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: UUID(),
                incarnation: nil
            ))
        )
    }

    // MARK: - Auto-bind at admission

    @Test("a create binds the pane to its owner's cohort in the same turn")
    func createBindsToTheOwnersCohortAtAdmission() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let cohort = UUID()
        await activate(coordinator, [alice, bob])
        let transition = await coordinator.reconcileCohort(
            cohortId: cohort,
            members: [alice, bob],
            representative: alice.sessionId,
            replaces: nil,
            requested: [],
            key: key(1)
        )
        #expect(transition.applied)

        // No binding request anywhere: the create itself must bind, so a
        // sibling can drive the pane before any reconcile carries it.
        let created = try await pane(
            coordinator,
            udid: "udid-autobind",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: bob.sessionId,
                incarnation: bob.incarnation
            )
        )
    }

    @Test("a create whose owner is in no cohort stays unbound")
    func createStaysUnboundWhenOwnerIsNoMember() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let carol = member(UUID(), 3)
        let cohort = UUID()
        await activate(coordinator, [alice, bob, carol])
        _ = await coordinator.reconcileCohort(
            cohortId: cohort,
            members: [alice, bob],
            representative: alice.sessionId,
            replaces: nil,
            requested: [],
            key: key(1)
        )

        // Carol is live but belongs to no cohort, so her pane takes the
        // own-session compatibility path: hers alone, nothing borrowed from
        // the cohort that happens to exist beside her.
        let created = try await pane(
            coordinator,
            udid: "udid-nonmember",
            owner: carol.sessionId,
            incarnation: carol.incarnation
        )
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: carol.sessionId,
                incarnation: carol.incarnation
            )
        )
        #expect(
            !(await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: alice.sessionId,
                incarnation: alice.incarnation
            ))
        )
    }

    @Test("adoption rebinds the pane to the adopter's cohort")
    func adoptionRebindsToTheAdoptersCohort() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let carol = member(UUID(), 3)
        let oldCohort = UUID()
        let newCohort = UUID()
        await activate(coordinator, [alice, bob, carol])
        let created = try await pane(
            coordinator,
            udid: "udid-adopt",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(
            coordinator,
            cohortId: oldCohort,
            members: [alice],
            created: created
        )
        _ = await coordinator.reconcileCohort(
            cohortId: newCohort,
            members: [bob, carol],
            representative: bob.sessionId,
            replaces: nil,
            requested: [],
            key: key(1)
        )

        // Alice is dead; bob adopts her orphan. The cohort must ride with
        // the ownership: carol (bob's sibling) drives it, alice's cohort
        // does not reach it any more.
        let adopted = try await coordinator.createPane(
            target: .sim(udid: "udid-adopt"),
            sessionId: bob.sessionId,
            ownerIncarnation: bob.incarnation,
            isOwnerSessionAlive: { _ in false },
            acquire: {
                PaneCoordinator.AcquiredBackend(
                    backend: MockDeviceBackend(),
                    family: "phone",
                    deviceType: "iPhone"
                )
            }
        )
        #expect(adopted.paneId == created.paneId)
        #expect(
            await coordinator.canSessionDrive(
                paneId: adopted.paneId,
                session: carol.sessionId,
                incarnation: carol.incarnation
            )
        )
        #expect(
            !(await coordinator.canSessionDrive(
                paneId: adopted.paneId,
                session: alice.sessionId,
                incarnation: alice.incarnation
            ))
        )
    }

    @Test("adoption revokes the outgoing cohort's already-open streams")
    func adoptionRevokesTheOutgoingCohortsStreams() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let carol = member(UUID(), 3)
        let cohort = UUID()
        await activate(coordinator, [alice, bob, carol])
        let created = try await pane(
            coordinator,
            udid: "udid-adopt-sweep",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: cohort, members: [alice, bob], created: created)
        let bobSub = try await coordinator.subscribe(
            paneId: created.paneId,
            as: .session(bob.sessionId, incarnation: bob.incarnation)
        )
        #expect(await coordinator.subscriberCount(paneId: created.paneId) == 1)

        // Alice is dead and carol, a member of no cohort, adopts her orphan.
        // Bob's admission came from the outgoing cohort; authorization
        // already refuses his next request, and his already-open stream must
        // not keep receiving frames across the cohort change either.
        let adopted = try await coordinator.createPane(
            target: .sim(udid: "udid-adopt-sweep"),
            sessionId: carol.sessionId,
            ownerIncarnation: carol.incarnation,
            isOwnerSessionAlive: { _ in false },
            acquire: {
                PaneCoordinator.AcquiredBackend(
                    backend: MockDeviceBackend(),
                    family: "phone",
                    deviceType: "iPhone"
                )
            }
        )
        #expect(adopted.paneId == created.paneId)
        // Drains to completion only because the adoption sweep finished it.
        for await _ in bobSub.stream {}
        #expect(await coordinator.subscriberCount(paneId: created.paneId) == 0)
    }

    // MARK: - Close verdicts and device effects

    /// Wire a capturing sink, returning the box the coordinator emits into.
    /// Emission is synchronous inside the coordinator's commit turns, so once
    /// an operation returns, its effects are all here.
    private func captureEffects(_ coordinator: PaneCoordinator) async -> EffectBox {
        let box = EffectBox()
        await coordinator.setDeviceEffectSink { box.append($0) }
        return box
    }

    @Test("a close decided by beginClose is emitted once, and the successor survives the sweeps")
    func beginCloseEmitsOnceAcrossEveryClosePath() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let cohort = UUID()
        await activate(coordinator, [alice, bob])
        let box = await captureEffects(coordinator)
        let created = try await pane(
            coordinator,
            udid: "udid-close-a",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: cohort, members: [alice, bob], created: created)

        let commit = await coordinator.beginCohortClose(
            cohortId: cohort,
            transitionId: UUID(),
            leaving: [alice.sessionId],
            mode: .shutdown,
            key: key(2)
        )
        #expect(commit.outcome == .promote(successor: bob.sessionId.uuidString))
        // The explicit close and the teardown both follow, as they do in
        // production. Neither may decide again: deciding fresh here is the
        // shape that once demoted a committed promotion to detach/shutdown.
        await coordinator.recordCloseVerdict(
            sessionId: alice.sessionId,
            incarnation: alice.incarnation,
            mode: .shutdown
        )
        await coordinator.tearDownSession(alice.sessionId, incarnation: alice.incarnation)
        await coordinator.revokeSubscriptions(forSession: alice.sessionId)

        #expect(box.effects.count == 1)
        guard case let .close(close) = box.effects.first else {
            Issue.record("expected a close effect, got \(box.effects)")
            return
        }
        #expect(close.sessionId == alice.sessionId)
        #expect(close.incarnation == alice.incarnation)
        #expect(close.outcome == .promote(successor: bob.sessionId.uuidString))
        // The re-homing is what keeps bob able to drive the pane he
        // inherited: the revocation sweep raises `ownerRevoked` on records
        // still naming the departed session.
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: bob.sessionId,
                incarnation: bob.incarnation
            )
        )
        #expect(
            !(await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: alice.sessionId,
                incarnation: alice.incarnation
            ))
        )
    }

    @Test("beginClose tears down the leaving member's stream before replying")
    func beginCloseRevokesTheLeavingMembersStream() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let cohort = UUID()
        await activate(coordinator, [alice, bob])
        let created = try await pane(
            coordinator,
            udid: "udid-close-b",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: cohort, members: [alice, bob], created: created)
        let aliceSub = try await coordinator.subscribe(
            paneId: created.paneId,
            as: .session(alice.sessionId, incarnation: alice.incarnation)
        )
        let bobSub = try await coordinator.subscribe(
            paneId: created.paneId,
            as: .session(bob.sessionId, incarnation: bob.incarnation)
        )
        _ = await coordinator.beginCohortClose(
            cohortId: cohort,
            transitionId: UUID(),
            leaving: [alice.sessionId],
            mode: .detach,
            key: key(2)
        )
        // Drains to completion only because the revocation finished it.
        for await _ in aliceSub.stream {}
        #expect(await coordinator.subscriberCount(paneId: created.paneId) == 1)
        await coordinator.unsubscribe(paneId: created.paneId, subscriptionId: bobSub.subscriptionId)
    }

    @Test("a reaped member of a live tab hands its pane to the survivor")
    func reapWithSurvivorPromotes() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let cohort = UUID()
        await activate(coordinator, [alice, bob])
        let box = await captureEffects(coordinator)
        let created = try await pane(
            coordinator,
            udid: "udid-reap-a",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: cohort, members: [alice, bob], created: created)
        // A restore-batch reap: no beginClose, no explicit close. The
        // teardown seam is the only thing standing between bob and an
        // `ownerRevoked` pane.
        await coordinator.tearDownSession(alice.sessionId, incarnation: alice.incarnation)
        await coordinator.revokeSubscriptions(forSession: alice.sessionId)
        #expect(box.effects.count == 1)
        guard case let .close(close) = box.effects.first else {
            Issue.record("expected a close effect, got \(box.effects)")
            return
        }
        #expect(close.outcome == .promote(successor: bob.sessionId.uuidString))
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: bob.sessionId,
                incarnation: bob.incarnation
            )
        )
    }

    @Test("a terminal reap dispositions nothing")
    func terminalReapEmitsNoEffect() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let cohort = UUID()
        await activate(coordinator, [alice])
        let box = await captureEffects(coordinator)
        let created = try await pane(
            coordinator,
            udid: "udid-reap-b",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: cohort, members: [alice], created: created)
        // Only an explicit close carries a user's choice; a reap of the last
        // member leaves device state to GUI recovery.
        await coordinator.tearDownSession(alice.sessionId, incarnation: alice.incarnation)
        #expect(box.effects.isEmpty)
    }

    @Test("an explicit close outside any cohort emits the terminal verdict")
    func nonCohortCloseEmitsTerminalEffect() async {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        await activate(coordinator, [alice])
        let box = await captureEffects(coordinator)
        await coordinator.recordCloseVerdict(
            sessionId: alice.sessionId,
            incarnation: alice.incarnation,
            mode: .shutdown
        )
        #expect(box.effects.count == 1)
        guard case let .close(close) = box.effects.first else {
            Issue.record("expected a close effect, got \(box.effects)")
            return
        }
        #expect(close.outcome == .shutdown)
        #expect(close.incarnation == alice.incarnation)
    }

    @Test("a close-decided member cannot be reconciled back to the pane")
    func closedMemberCannotBeReconciledBackToThePane() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let cohort = UUID()
        await activate(coordinator, [alice, bob])
        let created = try await pane(
            coordinator,
            udid: "udid-revive",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: cohort, members: [alice, bob], created: created)
        _ = await coordinator.beginCohortClose(
            cohortId: cohort,
            transitionId: UUID(),
            leaving: [alice.sessionId],
            mode: .detach,
            key: key(2)
        )
        // Alice is still live (her session.close is in flight) and her active
        // incarnation still resolves, so a dominating reconcile listing her
        // would otherwise revive the authorization the close withdrew.
        let revived = await coordinator.reconcileCohort(
            cohortId: cohort,
            members: [alice, bob],
            representative: bob.sessionId,
            replaces: nil,
            requested: [],
            key: key(3)
        )
        #expect(revived.rejection == .memberClosed)
        #expect(
            !(await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: alice.sessionId,
                incarnation: alice.incarnation
            ))
        )
    }

    @Test("a replacement's dropped member produces a targeted transfer")
    func replacementEmitsATargetedTransfer() async throws {
        let coordinator = PaneCoordinator()
        let alice = member(UUID(), 1)
        let bob = member(UUID(), 2)
        let old = UUID()
        let new = UUID()
        await activate(coordinator, [alice, bob])
        let box = await captureEffects(coordinator)
        let created = try await pane(
            coordinator,
            udid: "udid-transfer",
            owner: alice.sessionId,
            incarnation: alice.incarnation
        )
        _ = await installCohort(coordinator, cohortId: old, members: [alice, bob], created: created)
        // The replacement drops alice while she is still alive. Only the pane
        // she actually held may change hands; a close-shaped sweep of
        // everything she owns is broader than this authorizes.
        let transition = await coordinator.reconcileCohort(
            cohortId: new,
            members: [bob],
            representative: bob.sessionId,
            replaces: old,
            requested: [],
            key: key(2)
        )
        #expect(transition.applied)
        #expect(box.effects.count == 1)
        guard case let .transfer(transfer) = box.effects.first else {
            Issue.record("expected a transfer effect, got \(box.effects)")
            return
        }
        #expect(transfer.previousOwner == alice)
        #expect(transfer.successor == bob)
        #expect(transfer.targets == [.sim(udid: "udid-transfer")])
        // The record moved with the membership, so bob drives what he now
        // owns.
        #expect(
            await coordinator.canSessionDrive(
                paneId: created.paneId,
                session: bob.sessionId,
                incarnation: bob.incarnation
            )
        )
    }
}

/// Effects captured off the coordinator's synchronous sink.
private final class EffectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CohortDeviceEffect] = []

    var effects: [CohortDeviceEffect] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ effect: CohortDeviceEffect) {
        lock.lock()
        storage.append(effect)
        lock.unlock()
    }
}
