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
        // commits. Binding first and deciding afterwards is what used to leave
        // a pane pointing at a cohort that was never installed.
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
        // Alice subscribes while the pane is unbound, on her legacy-owner
        // authority.
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
}
