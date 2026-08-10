// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// `OrchestratorGrantStore`: the in-memory lease ledger with `(epoch,
// revision)` ordering and live-session membership. Issued/revoked by
// validated-GUI handlers, read by the orchestrator scope check. Nothing is
// persisted. A grant target must be a registered live session; removal drops
// it so a late grant is rejected however long delayed.

private func key(_ epoch: UInt64, _ revision: Int) -> GrantOrderingKey {
    GrantOrderingKey(epoch: epoch, revision: revision)
}

/// Register `ids` as live sessions and return them.
private func live(_ store: OrchestratorGrantStore, _ ids: UUID...) async -> [UUID] {
    for id in ids { await store.registerSession(id) }
    return ids
}

@Test
func grantThenHasGrant() async {
    let store = OrchestratorGrantStore()
    let session = UUID()
    #expect(await store.hasGrant(session) == false)
    _ = await live(store, session)
    #expect(await store.grant(sessionIds: [session], key: key(1, 1), issuedBy: 1) == .applied)
    #expect(await store.hasGrant(session))
    #expect(await store.count == 1)
}

@Test
func grantForUnregisteredSessionIsRejected() async {
    // A target that was never registered live is not grantable.
    let store = OrchestratorGrantStore()
    #expect(await store.grant(sessionIds: [UUID()], key: key(1, 1), issuedBy: 1) == .sessionNotLive)
}

@Test
func revokeWithDominatingKeyRemovesGrant() async {
    let store = OrchestratorGrantStore()
    let session = UUID()
    _ = await live(store, session)
    _ = await store.grant(sessionIds: [session], key: key(1, 1), issuedBy: 1)
    _ = await store.revoke(sessionIds: [session], key: key(1, 2))
    #expect(await store.hasGrant(session) == false)
}

@Test
func staleGrantExecutedAfterNewerRevokeDoesNotResurrect() async {
    // The non-FIFO hazard: a revoke (higher revision) runs first, then a
    // stale grant (lower revision) runs. The grant must lose, dominance
    // check fails, so authority stays revoked.
    let store = OrchestratorGrantStore()
    let session = UUID()
    _ = await live(store, session)
    _ = await store.revoke(sessionIds: [session], key: key(1, 2))
    #expect(await store.grant(sessionIds: [session], key: key(1, 1), issuedBy: 1) == .notApplied)
    #expect(await store.hasGrant(session) == false)
}

@Test
func newerGrantAfterRevokeRegrants() async {
    let store = OrchestratorGrantStore()
    let session = UUID()
    _ = await live(store, session)
    _ = await store.revoke(sessionIds: [session], key: key(1, 1))
    #expect(await store.grant(sessionIds: [session], key: key(1, 2), issuedBy: 1) == .applied)
    #expect(await store.hasGrant(session))
}

@Test
func staleEpochGrantLosesToNewerConnection() async {
    let store = OrchestratorGrantStore()
    let session = UUID()
    _ = await live(store, session)
    _ = await store.grant(sessionIds: [session], key: key(20, 1), issuedBy: 20)
    _ = await store.grant(sessionIds: [session], key: key(10, 99), issuedBy: 10)
    #expect(await store.hasGrant(session))  // still the epoch-20 grant
    await store.revokeAll(issuedBy: 10)
    #expect(await store.hasGrant(session))
}

@Test
func revokeAllByConnectionRevokesOnlyThatConnectionsGrants() async {
    let store = OrchestratorGrantStore()
    let ownedByOne = UUID()
    let ownedByTwo = UUID()
    _ = await live(store, ownedByOne, ownedByTwo)
    _ = await store.grant(sessionIds: [ownedByOne], key: key(1, 1), issuedBy: 1)
    _ = await store.grant(sessionIds: [ownedByTwo], key: key(2, 1), issuedBy: 2)
    await store.revokeAll(issuedBy: 1)
    #expect(await store.hasGrant(ownedByOne) == false)
    #expect(await store.hasGrant(ownedByTwo))
}

@Test
func reissuedGrantOwnedByNewerConnectionSurvivesOldTeardown() async {
    let store = OrchestratorGrantStore()
    let session = UUID()
    _ = await live(store, session)
    _ = await store.grant(sessionIds: [session], key: key(10, 1), issuedBy: 10)
    _ = await store.grant(sessionIds: [session], key: key(20, 1), issuedBy: 20)
    await store.revokeAll(issuedBy: 10)
    #expect(await store.hasGrant(session))
}

@Test
func lateGrantFromClosedIssuerIsRejected() async {
    let store = OrchestratorGrantStore()
    let session = UUID()
    _ = await live(store, session)
    await store.revokeAll(issuedBy: 5)
    #expect(await store.grant(sessionIds: [session], key: key(5, 9), issuedBy: 5) == .notApplied)
    #expect(await store.hasGrant(session) == false)
    #expect(await store.grant(sessionIds: [session], key: key(6, 1), issuedBy: 6) == .applied)
    #expect(await store.hasGrant(session))
}

@Test
func removedSessionRejectsAnyLateGrantRegardlessOfChurn() async {
    // The removed-session fence is live-session membership, not a time/count
    // window: a target removed BEFORE 300 further removals is still rejected.
    let store = OrchestratorGrantStore()
    let target = UUID()
    _ = await live(store, target)
    await store.revokeForRemovedSession(target)
    for _ in 0..<300 {
        let other = UUID()
        await store.registerSession(other)
        await store.revokeForRemovedSession(other)
    }
    #expect(await store.grant(sessionIds: [target], key: key(1, 1), issuedBy: 1) == .sessionNotLive)
    #expect(await store.hasGrant(target) == false)
}

@Test
func revokeForNonLiveTargetStoresNoTombstone() async {
    // A revoke for a session that was removed (or never registered) must
    // NOT recreate a permanent entry: a late/arbitrary revoke recreating
    // tombstones is unbounded ledger growth. `entries` stays empty; a stale
    // grant is already fenced by the liveness gate, not a tombstone.
    let store = OrchestratorGrantStore()
    let removed = UUID()
    _ = await live(store, removed)
    await store.revokeForRemovedSession(removed)
    // Revoke the already-removed session and a never-live UUID: both no-op.
    #expect(await store.revoke(sessionIds: [removed, UUID()], key: key(9, 9)))
    #expect(await store.entryCount == 0)
    // Churn many more spurious revokes: the ledger must not grow.
    for _ in 0..<300 {
        _ = await store.revoke(sessionIds: [UUID()], key: key(1, 1))
    }
    #expect(await store.entryCount == 0)
    // And a stale grant for the removed session is still rejected on liveness.
    #expect(await store.grant(sessionIds: [removed], key: key(1, 1), issuedBy: 1) == .sessionNotLive)
}

@Test
func removedSessionRevokeDropsAnExistingGrant() async {
    let store = OrchestratorGrantStore()
    let session = UUID()
    _ = await live(store, session)
    _ = await store.grant(sessionIds: [session], key: key(1, 1), issuedBy: 1)
    #expect(await store.count == 1)
    await store.revokeForRemovedSession(session)
    #expect(await store.hasGrant(session) == false)
}

@Test
func staleBatchAppliesToNoneAndReportsNotApplied() async {
    // All-or-none: a batch whose key dominates one target but not another
    // (a mixed-staleness batch) must mutate NOTHING and report .notApplied.
    let store = OrchestratorGrantStore()
    let fresh = UUID()
    let alreadyHigher = UUID()
    _ = await live(store, fresh, alreadyHigher)
    _ = await store.grant(sessionIds: [alreadyHigher], key: key(2, 5), issuedBy: 2)
    let outcome = await store.grant(sessionIds: [fresh, alreadyHigher], key: key(2, 3), issuedBy: 2)
    #expect(outcome == .notApplied)
    #expect(await store.hasGrant(fresh) == false)   // not partially granted
    #expect(await store.hasGrant(alreadyHigher))    // its prior grant intact
}

@Test
func mixedBatchWithOneNonLiveTargetIsRejected() async {
    // If any target isn't live, the whole batch is .sessionNotLive: none
    // granted (all-or-none).
    let store = OrchestratorGrantStore()
    let liveOne = UUID()
    _ = await live(store, liveOne)
    let outcome = await store.grant(sessionIds: [liveOne, UUID()], key: key(1, 1), issuedBy: 1)
    #expect(outcome == .sessionNotLive)
    #expect(await store.hasGrant(liveOne) == false)
}
