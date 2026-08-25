// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// SessionManager.restoreBatch: the epoch-fenced, authoritative, all-or-none
// inventory restore. A validated GUI re-supplies its live session set to a
// fresh daemon; nothing is rehydrated from disk. These pin the semantics: atomic validation, verifier re-derivation,
// idempotent replay, fail-closed protection seeded in-turn, short-id preservation +
// collision rejection, owner capture, batch ordering, barrier release, stale/
// superseded-batch rejection via the `(epoch, revision)` fence, ghost
// reconciliation, and concurrent-restore linearizability.

/// Test gate for a controlled restore-tail interleave: the parked tail calls
/// `enterAndWait` (signalling it entered, then blocking), the test waits for
/// that signal via `awaitEntered`, drives the interleaving work, then `open`s
/// the gate to release the tail.
private actor TailGate {
    private var isOpen = false
    private var didEnter = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        didEnter = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        if isOpen { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func awaitEntered() async {
        if didEnter { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func open() {
        isOpen = true
        for waiter in openWaiters { waiter.resume() }
        openWaiters.removeAll()
    }
}

private func entry(
    capability: Capability,
    id: UUID = UUID(),
    shortId: String = ShortID.generate(),
    role: SessionRole = .agent,
    name: String? = nil,
    isProtected: Bool = false
) -> RestoreSessionEntry {
    RestoreSessionEntry(
        id: id,
        capability: capability,
        shortId: shortId,
        role: role,
        name: name,
        isProtected: isProtected
    )
}

@Test
func reinsertDuringTeardownRevokesBeforeRegistering() async throws {
    // The per-session FIFO ordering under the sharpest interleaving: a ghost
    // teardown of incarnation G is parked mid-transition; a NEWER restore
    // reinserts the SAME UUID (G+1) while G's teardown is in flight; on release,
    // G's revoke must complete BEFORE G+1's registration, so the reinserted
    // incarnation never inherits G's automation grant and becomes ready only
    // at G+1.
    let grantStore = AutomationGrantStore()
    let broker = EventBroker()
    let manager = SessionManager(
        eventBroker: broker,
        startsPendingRestoration: true,
        automationGrantStore: grantStore
    )
    await manager.setPaneRevoker { _ in }

    // Create session A (incarnation G) and grant it.
    let created = try await manager.createSession(label: nil)
    let sessionA = created.state.id
    _ = await grantStore.grant(sessionIds: [sessionA], key: GrantOrderingKey(epoch: 1, revision: 1), issuedBy: 1)
    #expect(await grantStore.hasGrant(sessionA))

    // Park every lane transition at the hook.
    let gate = TailGate()
    await manager.setTransitionEntryHook { await gate.enterAndWait() }

    // Restore 1 (epoch 2) OMITS A → ghosts it → its teardown parks at the hook.
    let ghosting = Task { _ = try? await manager.restoreBatch([], owner: nil, epoch: 2, revision: 1) }
    await gate.awaitEntered()
    #expect(await manager.contains(sessionA) == false)  // sync removal happened

    // Restore 2 (epoch 3) LISTS A → reinserts the same UUID at G+1, enqueued on
    // A's lane AFTER the parked teardown.
    let reinserting = Task {
        _ = try? await manager.restoreBatch(
            [entry(capability: created.capability, id: sessionA, shortId: created.state.shortId)],
            owner: nil,
            epoch: 3,
            revision: 1
        )
    }
    // Let restore 2's synchronous segment run (it reinserts A).
    var spins = 0
    while await manager.contains(sessionA) == false {
        spins += 1
        #expect(spins < 100_000)
        await Task.yield()
    }

    // Release the lane. G's teardown revokes A's grant, THEN G+1 registers fresh.
    await gate.open()
    _ = await ghosting.value
    _ = await reinserting.value

    // A is live again at G+1, and did NOT inherit G's grant (the teardown
    // revoked it before the fresh registration).
    guard case let .ready(reinc) = await manager.admission(for: sessionA), reinc != nil else {
        Issue.record("expected A ready at a new incarnation"); return
    }
    #expect(await grantStore.hasGrant(sessionA) == false)
    // The broker accepts the new incarnation.
    #expect(await broker.isRetired(sessionA) == false)
}

@Test
func restoreInsertsSessionsAndReDerivesVerifierFromCap() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let capA = try Capability.random()
    let capB = try Capability.random()
    let entryA = entry(capability: capA)
    let entryB = entry(capability: capB)

    let result = try await manager.restoreBatch([entryA, entryB], owner: nil, epoch: 1, revision: 1)
    #expect(result.restoredCount == 2)
    #expect(await manager.sessionCount == 2)
    // The daemon re-derived each verifier from the supplied bearer cap, so the
    // original in-tab cap still authenticates.
    await #expect(throws: Never.self) {
        _ = try await manager.validate(sessionId: entryA.id, capability: capA)
    }
    await #expect(throws: Never.self) {
        _ = try await manager.validate(sessionId: entryB.id, capability: capB)
    }
}

@Test
func emptyBatchReleasesTheRestorationBarrier() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    #expect(await manager.isRestorationComplete == false)
    let result = try await manager.restoreBatch([], owner: nil, epoch: 1, revision: 1)
    #expect(result.restoredCount == 0)
    #expect(await manager.sessionCount == 0)
    #expect(await manager.isRestorationComplete == true)
}

@Test
func replayOfTheSameSetIsAnIdempotentNoOp() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let cap = try Capability.random()
    let item = entry(capability: cap, name: "main")
    _ = try await manager.restoreBatch([item], owner: nil, epoch: 1, revision: 1)
    // Second, identical restore: no throw, no duplicate, no change.
    _ = try await manager.restoreBatch([item], owner: nil, epoch: 1, revision: 1)
    #expect(await manager.sessionCount == 1)
}

@Test
func sameVerifierReplayDoesNotRewriteNewerProtection() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let cap = try Capability.random()
    let item = entry(capability: cap, isProtected: false)
    _ = try await manager.restoreBatch([item], owner: nil, epoch: 1, revision: 1)
    // A newer authoritative protection mutation flips the session protected.
    _ = try await manager.setProtectedBatch(
        sessionIds: [item.id], isProtected: true, revision: 5, epoch: 1
    )
    #expect(await manager.isProtected(item.id) == true)
    // Replaying the ORIGINAL (unprotected) restore must NOT revert protection: its
    // lower-tier baseline key can't dominate the newer live-authority write.
    _ = try await manager.restoreBatch([item], owner: nil, epoch: 1, revision: 1)
    #expect(await manager.isProtected(item.id) == true)
}

@Test
func conflictingVerifierRejectsTheWholeBatch() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let sharedId = UUID()
    let capA = try Capability.random()
    _ = try await manager.restoreBatch([entry(capability: capA, id: sharedId)], owner: nil, epoch: 1, revision: 1)

    // A batch re-naming the live session with a DIFFERENT cap, plus a fresh
    // session, must reject in full: the fresh session is not inserted.
    let capB = try Capability.random()
    let fresh = entry(capability: try Capability.random())
    await #expect(throws: RestoreBatchError.self) {
        try await manager.restoreBatch(
            [entry(capability: capB, id: sharedId), fresh], owner: nil, epoch: 1, revision: 1
        )
    }
    #expect(await manager.sessionCount == 1)
    #expect(await manager.contains(fresh.id) == false)
    // The live session keeps its original cap.
    await #expect(throws: Never.self) {
        _ = try await manager.validate(sessionId: sharedId, capability: capA)
    }
}

@Test
func inBatchDuplicateSessionIdRejectsWholeBatch() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let dupId = UUID()
    await #expect(throws: RestoreBatchError.self) {
        try await manager.restoreBatch(
            [
                entry(capability: try Capability.random(), id: dupId),
                entry(capability: try Capability.random(), id: dupId)
            ],
            owner: nil,
            epoch: 1,
            revision: 1
        )
    }
    #expect(await manager.sessionCount == 0)
}

@Test
func inBatchDuplicateShortIdRejectsWholeBatch() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    await #expect(throws: RestoreBatchError.self) {
        try await manager.restoreBatch(
            [
                entry(capability: try Capability.random(), shortId: "abc123"),
                entry(capability: try Capability.random(), shortId: "abc123")
            ],
            owner: nil,
            epoch: 1,
            revision: 1
        )
    }
    #expect(await manager.sessionCount == 0)
}

@Test
func malformedShortIdRejectsWholeBatch() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    await #expect(throws: RestoreBatchError.self) {
        // "ILOU!!" is not well-formed (excluded letters / punctuation / length).
        try await manager.restoreBatch(
            [entry(capability: try Capability.random(), shortId: "ILOU!!")],
            owner: nil,
            epoch: 1,
            revision: 1
        )
    }
    #expect(await manager.sessionCount == 0)
}

@Test
func shortIdCollisionWithADifferentLiveSessionRejects() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    _ = try await manager.restoreBatch(
        [entry(capability: try Capability.random(), shortId: "abc123")], owner: nil, epoch: 1, revision: 1
    )
    // A NEW session claiming the same short id as a DIFFERENT live one rejects.
    await #expect(throws: RestoreBatchError.self) {
        try await manager.restoreBatch(
            [entry(capability: try Capability.random(), shortId: "abc123")], owner: nil, epoch: 1, revision: 1
        )
    }
    #expect(await manager.sessionCount == 1)
}

@Test
func sameVerifierWithDifferentMetadataReportsMismatch() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let sessionId = UUID()
    let cap = try Capability.random()
    _ = try await manager.restoreBatch(
        [entry(capability: cap, id: sessionId, shortId: "aaa111")], owner: nil, epoch: 1, revision: 1
    )
    // Same session, same verifier, but a DIFFERENT short id: restore never
    // silently rewrites immutable metadata. It reports the mismatch.
    await #expect(throws: RestoreBatchError.self) {
        try await manager.restoreBatch(
            [entry(capability: cap, id: sessionId, shortId: "bbb222")], owner: nil, epoch: 1, revision: 1
        )
    }
}

@Test
func protectedSessionIsSeededInTurnAndHiddenFromTabsList() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let item = entry(capability: try Capability.random(), isProtected: true)
    _ = try await manager.restoreBatch([item], owner: nil, epoch: 1, revision: 1)
    #expect(await manager.isProtected(item.id) == true)
    // An unauthenticated (nil) caller never sees the protected restored session.
    let visible = await manager.sessions(visibleTo: nil).map(\.id)
    #expect(visible.contains(item.id) == false)
    // Its owner sees it.
    let ownerView = await manager.sessions(visibleTo: item.id).map(\.id)
    #expect(ownerView.contains(item.id) == true)
}

@Test
func ownerIsCapturedAndDrivesLiveness() async throws {
    let owner = OwnerProcessIdentity(pid: 4_242, pidVersion: 1, euid: geteuid())
    // Owner pid reported dead → the restored session is not alive.
    let deadManager = SessionManager(isProcessAlive: { _ in false }, startsPendingRestoration: true)
    let deadItem = entry(capability: try Capability.random())
    _ = try await deadManager.restoreBatch([deadItem], owner: owner, epoch: 1, revision: 1)
    #expect(await deadManager.isAlive(deadItem.id) == false)
    #expect(await deadManager.session(id: deadItem.id)?.owner == owner)

    // Owner pid reported alive → alive. Proves the captured owner (not a nil
    // "assume alive") is what drives the liveness check.
    let liveManager = SessionManager(isProcessAlive: { _ in true }, startsPendingRestoration: true)
    let liveItem = entry(capability: try Capability.random())
    _ = try await liveManager.restoreBatch([liveItem], owner: owner, epoch: 1, revision: 1)
    #expect(await liveManager.isAlive(liveItem.id) == true)
}

@Test
func restoreEstablishesProtectionOrderingBaselineAStaleWriteCannotBeat() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    // Restore a PROTECTED session on a NEW connection (high epoch = the
    // reconnecting GUI). Restore seeds the ordering baseline (epoch 100, rev 0).
    let item = entry(capability: try Capability.random(), isProtected: true)
    _ = try await manager.restoreBatch([item], owner: nil, epoch: 100, revision: 1)
    #expect(await manager.isProtected(item.id) == true)

    // A delayed unprotect write from an OLDER connection (lower epoch) must
    // LOSE to the baseline: the just-restored-protected tab stays protected.
    let stale = try await manager.setProtectedBatch(
        sessionIds: [item.id], isProtected: false, revision: 999, epoch: 50
    )
    #expect(stale.applied == false)
    #expect(await manager.isProtected(item.id) == true)

    // A write on the SAME (restoring) connection with any revision > 0 wins.
    let fresh = try await manager.setProtectedBatch(
        sessionIds: [item.id], isProtected: false, revision: 1, epoch: 100
    )
    #expect(fresh.applied == true)
    #expect(await manager.isProtected(item.id) == false)
}

@Test
func staleBatchFromAnOlderConnectionIsRejectedAndMutatesNothing() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let keep = entry(capability: try Capability.random())
    _ = try await manager.restoreBatch([keep], owner: nil, epoch: 100, revision: 1)
    // A LATER-arriving batch from an OLDER connection (lower epoch) is stale:
    // rejected in full, nothing inserted, the live session untouched.
    let fresh = entry(capability: try Capability.random())
    await #expect(throws: RestoreBatchError.self) {
        try await manager.restoreBatch([keep, fresh], owner: nil, epoch: 50, revision: 1)
    }
    #expect(await manager.sessionCount == 1)
    #expect(await manager.contains(fresh.id) == false)
    #expect(await manager.contains(keep.id) == true)
}

@Test
func newerRestoreReconcilesAwayAnOmittedGhost() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let alpha = entry(capability: try Capability.random())
    let beta = entry(capability: try Capability.random())
    _ = try await manager.restoreBatch([alpha, beta], owner: nil, epoch: 100, revision: 1)
    #expect(await manager.sessionCount == 2)
    // A NEWER complete inventory OMITS beta (its tab was closed, the close was
    // lost). Restore is authoritative: beta is an abandoned ghost and is torn
    // down; alpha survives.
    _ = try await manager.restoreBatch([alpha], owner: nil, epoch: 200, revision: 1)
    #expect(await manager.sessionCount == 1)
    #expect(await manager.contains(alpha.id) == true)
    #expect(await manager.contains(beta.id) == false)
}

@Test
func newerRestoreUpdatesAPresentSessionsProtection() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let sessionId = UUID()
    let cap = try Capability.random()
    _ = try await manager.restoreBatch(
        [entry(capability: cap, id: sessionId, shortId: "aaa111", isProtected: false)],
        owner: nil,
        epoch: 100,
        revision: 1
    )
    #expect(await manager.isProtected(sessionId) == false)
    // A newer restore (higher epoch) carrying the authoritative protection updates
    // a matching live session: a newer inventory corrects an older value.
    _ = try await manager.restoreBatch(
        [entry(capability: cap, id: sessionId, shortId: "aaa111", isProtected: true)],
        owner: nil,
        epoch: 200,
        revision: 1
    )
    #expect(await manager.isProtected(sessionId) == true)
}

@Test
func aSessionCreatedOnThisConnectionSurvivesAnOmittingRestore() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    // A session created on connection 100 (e.g. a tab opened just before the
    // reconnect restore was built).
    let created = try await manager.createSession(label: nil, epoch: 100)
    // A restore on the SAME connection (epoch 100) whose snapshot predates the
    // create must NOT reconcile it away: its epoch is not older.
    _ = try await manager.restoreBatch([], owner: nil, epoch: 100, revision: 1)
    #expect(await manager.contains(created.state.id) == true)
    // A restore from a strictly-newer connection that omits it DOES reap it.
    _ = try await manager.restoreBatch([], owner: nil, epoch: 200, revision: 1)
    #expect(await manager.contains(created.state.id) == false)
}

@Test
func aSupersededSameConnectionRetryIsRejectedByTheRevisionFence() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let item = entry(capability: try Capability.random())
    // A newer retry (revision 2) applies first on this connection...
    _ = try await manager.restoreBatch([item], owner: nil, epoch: 100, revision: 2)
    // ...so a slower earlier retry (SAME epoch, revision 1) is stale and rejected
    // by the `(epoch, revision)` fence: equal epochs alone couldn't order these.
    await #expect(throws: RestoreBatchError.self) {
        try await manager.restoreBatch([], owner: nil, epoch: 100, revision: 1)
    }
    // The superseded batch mutated nothing: item survives.
    #expect(await manager.contains(item.id) == true)
    #expect(await manager.sessionCount == 1)
}

@Test
func concurrentRestoresLinearizeToTheHighestEpoch() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let lower = entry(capability: try Capability.random(), shortId: "xxx111")
    let higher = entry(capability: try Capability.random(), shortId: "yyy222")
    // Fire two restores concurrently: a lower-epoch {lower} and a higher-epoch
    // {higher}. Whatever the interleaving across the mutation segment's async
    // tail, the higher epoch (200) is authoritative: if it lands first the
    // lower one is fenced as stale; if it lands second it reconciles the lower
    // one's session away. The result is deterministic and never torn.
    async let first: Void = {
        _ = try? await manager.restoreBatch([lower], owner: nil, epoch: 100, revision: 1)
    }()
    async let second: Void = {
        _ = try? await manager.restoreBatch([higher], owner: nil, epoch: 200, revision: 1)
    }()
    _ = await (first, second)
    #expect(await manager.contains(higher.id) == true)
    #expect(await manager.contains(lower.id) == false)
    #expect(await manager.sessionCount == 1)
}

@Test
func aHigherRevisionRetryReapsASessionAnEarlierRetryAsserted() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let alpha = entry(capability: try Capability.random(), shortId: "aaa111")
    let beta = entry(capability: try Capability.random(), shortId: "bbb222")
    // rev1 on connection 100 asserts {alpha, beta}.
    _ = try await manager.restoreBatch([alpha, beta], owner: nil, epoch: 100, revision: 1)
    #expect(await manager.sessionCount == 2)
    // A corrected retry on the SAME connection (higher revision) drops beta.
    // Equal epochs alone could NOT reap it: the revision must participate in
    // membership ordering for a same-connection correction to take effect.
    _ = try await manager.restoreBatch([alpha], owner: nil, epoch: 100, revision: 2)
    #expect(await manager.contains(alpha.id) == true)
    #expect(await manager.contains(beta.id) == false)
    #expect(await manager.sessionCount == 1)
}

@Test
func aHigherRevisionRetryCorrectsAPresentSessionsProtection() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let sessionId = UUID()
    let cap = try Capability.random()
    // rev1 asserts the session unprotected.
    _ = try await manager.restoreBatch(
        [entry(capability: cap, id: sessionId, shortId: "aaa111", isProtected: false)],
        owner: nil,
        epoch: 100,
        revision: 1
    )
    #expect(await manager.isProtected(sessionId) == false)
    // A corrected retry on the SAME connection (higher revision) flips it
    // protected: the revision participates in the protection-ordering scheme, so a
    // same-connection correction is not collapsed to an unchangeable baseline.
    _ = try await manager.restoreBatch(
        [entry(capability: cap, id: sessionId, shortId: "aaa111", isProtected: true)],
        owner: nil,
        epoch: 100,
        revision: 2
    )
    #expect(await manager.isProtected(sessionId) == true)
}

@Test
func aLiveSetProtectedBatchBeatsASameConnectionRestoreRegardlessOfRevision() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let sessionId = UUID()
    let cap = try Capability.random()
    // A restore retry drives the RESTORE revision high (5) on connection 100.
    _ = try await manager.restoreBatch(
        [entry(capability: cap, id: sessionId, shortId: "aaa111", isProtected: false)],
        owner: nil,
        epoch: 100,
        revision: 5
    )
    // A user protection toggle on the SAME connection carries a LOWER numeric
    // revision (1) from its own independent counter, yet must WIN: a restore is
    // a lower ordering TIER than a live user action at one epoch, so the two
    // counters never collide and a post-restore toggle is never mistaken for a
    // stale write.
    let result = try await manager.setProtectedBatch(
        sessionIds: [sessionId], isProtected: true, revision: 1, epoch: 100
    )
    #expect(result.applied == true)
    #expect(await manager.isProtected(sessionId) == true)
}

@Test
func anOlderRestoreTailDoesNotRegisterASessionANewerRestoreReaped() async throws {
    // Controlled interleaving: suspend an older restore's async tail at its
    // entry hook, let a newer restore's mutation segment reap the session the
    // older one inserted, then release the older tail and prove it honors the
    // reap: it must NOT register the now-dead session in the grant store. Pins
    // the generation-safe async tail against the "older tail clobbers newer
    // state" hazard.
    let grantStore = AutomationGrantStore()
    let manager = SessionManager(
        startsPendingRestoration: true,
        automationGrantStore: grantStore
    )
    let alpha = entry(capability: try Capability.random(), shortId: "aaa111")

    let gate = TailGate()
    await manager.setTransitionEntryHook { await gate.enterAndWait() }

    // Fire the older restore (connection 100, inserts alpha) but don't await:
    // its store reconcile will park at the gate before registering alpha.
    let older = Task {
        _ = try? await manager.restoreBatch([alpha], owner: nil, epoch: 100, revision: 1)
    }
    // Wait until the older tail is parked at the hook.
    await gate.awaitEntered()

    // A newer restore (connection 200) omits alpha → reaps it in its synchronous
    // mutation segment. Fire it and wait until the reap is observable.
    let newer = Task {
        _ = try? await manager.restoreBatch([], owner: nil, epoch: 200, revision: 1)
    }
    var spins = 0
    while await manager.contains(alpha.id) {
        spins += 1
        #expect(spins < 100_000)
        await Task.yield()
    }

    // Release the older tail. It rechecks liveness and must skip registering the
    // reaped session; the newer tail (serialized after it) revokes it.
    await gate.open()
    _ = await older.value
    _ = await newer.value

    #expect(await manager.contains(alpha.id) == false)
    // The grant store must agree the session is not live: an older tail that
    // wrongly registered it would make this `.applied` instead.
    let outcome = await grantStore.grant(
        sessionIds: [alpha.id],
        key: GrantOrderingKey(epoch: 999, revision: 1),
        issuedBy: 1
    )
    #expect(outcome == .sessionNotLive)
}

@Test
func aCloseRacingARestoreTailLeavesTheStoresConsistent() async throws {
    // Cross-path ordering: a close and a restore both touch the SAME session's
    // store liveness. Suspend the restore's store reconcile at the hook, close
    // the session (removing it and scheduling a revoke behind the parked
    // reconcile), then release: the shared serial store chain plus the liveness
    // recheck must leave the store consistent with `sessions` (session gone,
    // revoked), not registered by a restore reconcile that ignored the close.
    let grantStore = AutomationGrantStore()
    let manager = SessionManager(
        startsPendingRestoration: true,
        automationGrantStore: grantStore
    )
    let cap = try Capability.random()
    let sessionA = UUID()

    let gate = TailGate()
    await manager.setTransitionEntryHook { await gate.enterAndWait() }

    // Restore inserts sessionA; its store reconcile parks at the hook.
    let restore = Task {
        _ = try? await manager.restoreBatch(
            [entry(capability: cap, id: sessionA, shortId: "aaa111")],
            owner: nil,
            epoch: 100,
            revision: 1
        )
    }
    await gate.awaitEntered()
    // The restore's synchronous segment inserted sessionA before parking.
    #expect(await manager.contains(sessionA) == true)

    // Close it concurrently: the close removes it and schedules a revoke behind
    // the parked restore reconcile.
    let close = Task {
        try? await manager.closeSession(sessionId: sessionA, capability: cap)
    }
    var spins = 0
    while await manager.contains(sessionA) {
        spins += 1
        #expect(spins < 100_000)
        await Task.yield()
    }

    // Release: the restore reconcile honors the close (session gone → revoke),
    // then the close's own revoke runs idempotently.
    await gate.open()
    _ = await restore.value
    _ = await close.value

    #expect(await manager.contains(sessionA) == false)
    let outcome = await grantStore.grant(
        sessionIds: [sessionA],
        key: GrantOrderingKey(epoch: 999, revision: 1),
        issuedBy: 1
    )
    #expect(outcome == .sessionNotLive)
}

@Test
func aRestoreDoesNotResurrectASessionClosedMidReconcile() async throws {
    // True reverse interleaving: park the close AFTER its synchronous removal +
    // tombstone but BEFORE its store reconcile completes, then submit the
    // already-captured restore (still listing the id) while the close is parked.
    // The daemon must NOT resurrect the closed session, must report it absent,
    // and the store must not re-register it, even mid-close.
    let grantStore = AutomationGrantStore()
    let manager = SessionManager(
        startsPendingRestoration: true,
        automationGrantStore: grantStore
    )
    let cap = try Capability.random()
    let sessionA = UUID()
    _ = try await manager.restoreBatch(
        [entry(capability: cap, id: sessionA, shortId: "aaa111")],
        owner: nil,
        epoch: 100,
        revision: 1
    )
    #expect(await manager.contains(sessionA) == true)

    // Park the close at its store reconcile (its sync removal + tombstone already
    // ran).
    let gate = TailGate()
    await manager.setTransitionEntryHook { await gate.enterAndWait() }
    let close = Task { try? await manager.closeSession(sessionId: sessionA, capability: cap) }
    await gate.awaitEntered()
    #expect(await manager.contains(sessionA) == false)

    // Submit the stale-captured restore (same connection, higher revision) that
    // still lists A, plus a fresh B whose insert is an observable signal the
    // restore's synchronous segment ran. Do NOT release the close yet.
    let sessionB = UUID()
    let capB = try Capability.random()
    let staleEntries = [
        entry(capability: cap, id: sessionA, shortId: "aaa111"),
        entry(capability: capB, id: sessionB, shortId: "bbb222")
    ]
    let restore = Task {
        _ = try? await manager.restoreBatch(staleEntries, owner: nil, epoch: 100, revision: 2)
    }
    var spins = 0
    while !(await manager.contains(sessionB)) {
        spins += 1
        #expect(spins < 100_000)
        await Task.yield()
    }
    // A must NOT be resurrected even while the close is mid-reconcile.
    #expect(await manager.contains(sessionA) == false)

    // Release: the close reconcile revokes A, then the restore reconcile
    // registers B.
    await gate.open()
    _ = await close.value
    _ = await restore.value

    #expect(await manager.contains(sessionA) == false)
    #expect(await manager.contains(sessionB) == true)
    #expect(
        await grantStore.grant(
            sessionIds: [sessionA],
            key: GrantOrderingKey(epoch: 999, revision: 1),
            issuedBy: 1
        ) == .sessionNotLive
    )
    #expect(
        await grantStore.grant(
            sessionIds: [sessionB],
            key: GrantOrderingKey(epoch: 999, revision: 2),
            issuedBy: 1
        ) == .applied
    )
}

@Test
func nonRestorableChurnNeverTombstonesAndCannotEvictAFence() async throws {
    // A restorable (GUI) session's close is fenced. Heavy churn of NON-restorable
    // sessions (an attacker calling create/close, or an agent closing its own
    // UDS session) must NOT tombstone at all, so it can neither grow the set nor
    // evict the fence. There is no eviction to race: the set holds only the one
    // restorable tombstone throughout, and the fenced id stays unresurrectable.
    let manager = SessionManager(startsPendingRestoration: true)
    let cap = try Capability.random()
    let sessionX = UUID()
    // A restored session IS restorable; close it → it tombstones.
    _ = try await manager.restoreBatch(
        [entry(capability: cap, id: sessionX, shortId: "aaa111")],
        owner: nil,
        epoch: 100,
        revision: 1
    )
    try await manager.closeSession(sessionId: sessionX, capability: cap)
    #expect(await manager.contains(sessionX) == false)
    #expect(await manager.closeTombstoneCount == 1)

    // Churn a large pool of NON-restorable sessions (default `restorable: false`).
    for _ in 0..<3_000 {
        let session = try await manager.createSession(label: nil, epoch: 100)
        try await manager.closeSession(
            sessionId: session.state.id,
            capability: session.capability
        )
    }
    // The set did not grow: only the one restorable tombstone remains.
    #expect(await manager.closeTombstoneCount == 1)

    // The fence still holds: a stale restore listing X does not resurrect it.
    let result = try await manager.restoreBatch(
        [entry(capability: cap, id: sessionX, shortId: "aaa111")],
        owner: nil,
        epoch: 100,
        revision: 2
    )
    #expect(await manager.contains(sessionX) == false)
    #expect(result.sessionIds.contains(sessionX.uuidString) == false)
}

@Test
func aRestoreParkedBeforeTheManagerDoesNotResurrectDespiteChurn() async throws {
    // A restore listing A is captured while A is live, then DELAYED (as if parked
    // in XPC validation / actor scheduling) while A closes and further restorable
    // open/close churn happens. When it finally lands it must NOT resurrect A:
    // the ONLY reclaim is a restore that OMITS A, and none ran, so A's tombstone
    // survives the churn. (An unsound transition-count expiry would have let the
    // churn expire the tombstone and the parked restore resurrect A.)
    let grantStore = AutomationGrantStore()
    let manager = SessionManager(
        startsPendingRestoration: true,
        automationGrantStore: grantStore
    )
    let capA = try Capability.random()
    let sessionA = UUID()
    _ = try await manager.restoreBatch(
        [entry(capability: capA, id: sessionA, shortId: "aaa111")],
        owner: nil,
        epoch: 100,
        revision: 1
    )
    // The delayed restore's inventory, captured NOW while A is live (lists A).
    let parkedEntries = [entry(capability: capA, id: sessionA, shortId: "aaa111")]

    // A closes (tombstone), then further restorable open/close churn.
    try await manager.closeSession(sessionId: sessionA, capability: capA)
    for _ in 0..<50 {
        let session = try await manager.createSession(label: nil, epoch: 100, restorable: true)
        try await manager.closeSession(
            sessionId: session.state.id,
            capability: session.capability
        )
    }

    // The parked restore finally lands: it must not resurrect A.
    let result = try await manager.restoreBatch(parkedEntries, owner: nil, epoch: 100, revision: 2)
    #expect(await manager.contains(sessionA) == false)
    #expect(result.sessionIds.isEmpty)
    #expect(
        await grantStore.grant(
            sessionIds: [sessionA],
            key: GrantOrderingKey(epoch: 999, revision: 1),
            issuedBy: 1
        ) == .sessionNotLive
    )
}

@Test
func aValidatedInventoryConfirmsAnExistingSessionAsRestorable() async throws {
    // A session created NON-restorable (e.g. minted while validation was
    // momentarily unavailable) becomes restorable when a validated inventory
    // LISTS it (present, not inserted), so its later close leaves a tombstone
    // and a stale inventory can't resurrect it.
    let manager = SessionManager(startsPendingRestoration: true)
    let created = try await manager.createSession(label: nil, epoch: 100, restorable: false)
    let sessionId = created.state.id
    let listed = RestoreSessionEntry(
        id: sessionId,
        capability: created.capability,
        shortId: created.state.shortId,
        role: .agent,
        name: nil,
        isProtected: false
    )
    _ = try await manager.restoreBatch([listed], owner: nil, epoch: 100, revision: 1)

    // Its close now tombstones (confirmed restorable), and a stale restore
    // listing it does not resurrect it.
    try await manager.closeSession(sessionId: sessionId, capability: created.capability)
    #expect(await manager.closeTombstoneCount == 1)
    let result = try await manager.restoreBatch([listed], owner: nil, epoch: 100, revision: 2)
    #expect(await manager.contains(sessionId) == false)
    #expect(result.sessionIds.isEmpty)
}

@Test
func aStaleOlderConnectionBatchCannotReclaimATombstone() async throws {
    // An older connection's batch arriving after a newer one must not reclaim a
    // close tombstone (or resurrect anything): it is stale-rejected and mutates
    // nothing, so a later non-stale restore listing the closed session is still
    // fenced.
    let manager = SessionManager(startsPendingRestoration: true)
    let capA = try Capability.random()
    let sessionA = UUID()
    _ = try await manager.restoreBatch(
        [entry(capability: capA, id: sessionA, shortId: "aaa111")],
        owner: nil,
        epoch: 100,
        revision: 1
    )
    try await manager.closeSession(sessionId: sessionA, capability: capA)

    // A stale older-connection batch that OMITS A must NOT reclaim A's tombstone.
    await #expect(throws: RestoreBatchError.self) {
        try await manager.restoreBatch([], owner: nil, epoch: 50, revision: 1)
    }

    // A non-stale restore listing A is still fenced: the tombstone survived.
    let result = try await manager.restoreBatch(
        [entry(capability: capA, id: sessionA, shortId: "aaa111")],
        owner: nil,
        epoch: 100,
        revision: 2
    )
    #expect(await manager.contains(sessionA) == false)
    #expect(result.sessionIds.isEmpty)
}

@Test
func aRestorableCreatedSessionTombstonesOnCloseAndFences() async throws {
    // A session the validated GUI mints (restorable) tombstones on close and
    // fences a stale restore; a restore that OMITS it reclaims the tombstone.
    let manager = SessionManager(startsPendingRestoration: true)
    let created = try await manager.createSession(label: nil, epoch: 100, restorable: true)
    let sessionId = created.state.id
    try await manager.closeSession(sessionId: sessionId, capability: created.capability)
    #expect(await manager.closeTombstoneCount == 1)

    // A stale restore listing it does not resurrect it.
    let stale = RestoreSessionEntry(
        id: sessionId,
        capability: created.capability,
        shortId: created.state.shortId,
        role: .agent,
        name: nil,
        isProtected: false
    )
    let result = try await manager.restoreBatch([stale], owner: nil, epoch: 100, revision: 1)
    #expect(await manager.contains(sessionId) == false)
    #expect(result.sessionIds.isEmpty)

    // A later inventory that OMITS it reclaims the tombstone.
    let fresh = entry(capability: try Capability.random(), shortId: "bbb222")
    _ = try await manager.restoreBatch([fresh], owner: nil, epoch: 100, revision: 2)
    #expect(await manager.closeTombstoneCount == 0)
    #expect(await manager.contains(fresh.id) == true)
}

@Test
func batchOrderDefinesTabsListOrdering() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let first = entry(capability: try Capability.random(), shortId: "aaa111")
    let second = entry(capability: try Capability.random(), shortId: "bbb222")
    let third = entry(capability: try Capability.random(), shortId: "ccc333")
    _ = try await manager.restoreBatch([first, second, third], owner: nil, epoch: 1, revision: 1)
    // allSessions() is createdAt-sorted; restore stamps strictly-increasing
    // createdAt in batch order, so the listing preserves the batch order.
    let order = await manager.allSessions().map(\.id)
    #expect(order == [first.id, second.id, third.id])
}
