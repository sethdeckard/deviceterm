// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import IOSurface
import Testing

// Hermetic tests for the acknowledged leased surface pool. Tests register
// tokens directly to exercise the grant, watermark, and epoch behavior
// without a live device or GPU.

private func surfaceID(_ published: PublishedSurface) -> IOSurfaceID {
    published.surface.withRef { IOSurfaceGetID($0) }
}

/// Acquire one slot, failing the test if the pool is exhausted.
///
/// Returns a non-optional so `#require` actually unwraps: requiring straight
/// into a `PublishedSurface?` variable types the macro's result as the
/// optional itself, which makes it a no-op passthrough. The callers that
/// free a slot by dropping their reference need that optional variable *and*
/// need to hold the only reference to it, so the unwrap happens here rather
/// than through a second binding at the call site.
private func acquireOne(
    _ pool: LeasedSurfacePool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> PublishedSurface {
    try #require(await pool.acquire(width: 8, height: 8), sourceLocation: sourceLocation)
}

/// Poll until the pool reports at least `count` free slots (the
/// daemon-current release runs asynchronously from `LeasedSurface.deinit`).
private func waitForFreeSlots(_ pool: LeasedSurfacePool, atLeast count: Int) async -> Int {
    for _ in 0..<200 {
        let free = await pool.freeSlotCount()
        if free >= count { return free }
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return await pool.freeSlotCount()
}

@Test("slot count clamps to the documented range")
func slotCountClamps() async {
    let low = LeasedSurfacePool(slotCount: 1)
    let lowHeld = await low.acquire(width: 8, height: 8)
    // 1 clamps up to 3, so after one acquire two remain free.
    #expect(await low.freeSlotCount() == 2)

    let high = LeasedSurfacePool(slotCount: 99)
    let highHeld = await high.acquire(width: 8, height: 8)
    #expect(await high.freeSlotCount() == 7)
    _ = (lowHeld, highHeld)
}

@Test("acquire exhausts to nil and counts the drop")
func acquireExhaustsToNil() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    var held: [PublishedSurface] = []
    for _ in 0..<3 { held.append(try #require(await pool.acquire(width: 8, height: 8))) }
    #expect(await pool.freeSlotCount() == 0)
    #expect(await pool.acquire(width: 8, height: 8) == nil)
    #expect(await pool.snapshotCounters().exhaustionDrops == 1)
    _ = held
}

@Test("generations are monotonic and never repeat across reuse")
func generationsAreMonotonic() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    var generations: [UInt64] = []
    for _ in 0..<3 {
        var published: PublishedSurface? = try await acquireOne(pool)
        generations.append(try #require(published?.lease).generation)
        published = nil
        _ = await waitForFreeSlots(pool, atLeast: 3)
    }
    #expect(generations == [1, 2, 3])
}

@Test("dropping the published surface frees the slot")
func daemonCurrentReleaseFreesSlot() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    var published: PublishedSurface? = try await acquireOne(pool)
    _ = published
    #expect(await pool.freeSlotCount() == 2)
    published = nil
    #expect(await waitForFreeSlots(pool, atLeast: 3) == 3)
}

@Test("free selection is least-recently-freed")
func leastRecentlyFreedReuse() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    var frameA: PublishedSurface? = try await acquireOne(pool)
    var frameB: PublishedSurface? = try await acquireOne(pool)
    let frameC = try #require(await pool.acquire(width: 8, height: 8))
    let idA = surfaceID(try #require(frameA))
    let idB = surfaceID(try #require(frameB))
    // Free A first, then B. The next acquire reuses A (freed least
    // recently), not B.
    frameA = nil
    _ = await waitForFreeSlots(pool, atLeast: 1)
    frameB = nil
    _ = await waitForFreeSlots(pool, atLeast: 2)
    let reused = try #require(await pool.acquire(width: 8, height: 8))
    #expect(surfaceID(reused) == idA)
    #expect(surfaceID(reused) != idB)
    _ = frameC
}

@Test("resize retires the epoch, bumps it, and never re-acquires retired surfaces")
func resizeRetiresEpoch() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let first = try #require(await pool.acquire(width: 10, height: 20))
    let firstID = surfaceID(first)
    #expect(await pool.activeEpoch() == 1)
    // A different size rotates to a fresh epoch; the held first frame keeps
    // epoch 1 quarantined.
    var held: [PublishedSurface] = []
    for _ in 0..<3 { held.append(try #require(await pool.acquire(width: 30, height: 40))) }
    #expect(await pool.activeEpoch() == 2)
    #expect(await pool.quarantinedEpochCount() == 1)
    // No epoch-2 acquire returns the retired epoch-1 surface.
    #expect(held.allSatisfy { surfaceID($0) != firstID })
    _ = first
}

@Test("quarantine budget caps retained retired epochs")
func quarantineBudgetCaps() async throws {
    let pool = LeasedSurfacePool(slotCount: 3, quarantineBudget: 2)
    // Hold a live frame in each epoch so pruning can't reclaim them.
    let frameA = try #require(await pool.acquire(width: 8, height: 8))
    #expect(await pool.retireAll() == true)
    let frameB = try #require(await pool.acquire(width: 9, height: 9))
    #expect(await pool.retireAll() == true)
    let frameC = try #require(await pool.acquire(width: 10, height: 10))
    // Two retired epochs are held; a third retire exceeds the budget.
    #expect(await pool.retireAll() == false)
    #expect(await pool.snapshotCounters().quarantineBudgetExceeded == 1)
    _ = (frameA, frameB, frameC)
}

// MARK: - Grant lifecycle

@Test("a committed hold survives the Grant value going out of scope")
func committedHoldSurvivesValueDrop() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    do {
        let grant = try #require(await lease.acquireHold(token))
        #expect(await grant.commit() == true)
    }
    // Grant dropped; the committed subscription hold remains.
    let holders = await pool.holders(epoch: lease.epoch, generation: lease.generation)
    #expect(holders.contains(.subscription(token)))
    _ = published
}

@Test("cancel removes a provisional hold; a later higher commit still works")
func cancelThenHigherCommit() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let first = try #require(await pool.acquire(width: 8, height: 8))
    let second = try #require(await pool.acquire(width: 8, height: 8))
    let leaseFirst = try #require(first.lease)
    let leaseSecond = try #require(second.lease)
    let holdFirst = try #require(await leaseFirst.acquireHold(token))
    await holdFirst.cancel()
    let heldFirst = await pool.holders(epoch: leaseFirst.epoch, generation: leaseFirst.generation)
    #expect(!heldFirst.contains(.subscription(token)))
    let holdSecond = try #require(await leaseSecond.acquireHold(token))
    #expect(await holdSecond.commit() == true)
    _ = (first, second)
}

@Test("cancel of the final provisional grant closes a draining token")
func cancelOfFinalProvisionalClosesDrainingToken() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let grant = try #require(await published.lease?.acquireHold(token))
    await pool.beginDrain(token)
    #expect(await pool.tokenState(token) == .draining)
    // The only hold is the never-committed top reservation; cancelling it
    // must let the token close (it can't wedge in draining).
    await grant.cancel()
    #expect(await pool.tokenState(token) == nil)
    _ = published
}

@Test("commit rejects a non-active token")
func commitRejectsNonActiveToken() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let grant = try #require(await published.lease?.acquireHold(token))
    await pool.beginDrain(token)
    #expect(await grant.commit() == false)
    await grant.cancel()
    #expect(await pool.tokenState(token) == nil)
    _ = published
}

@Test("revoke removes a committed-but-unexposed hold")
func revokeRemovesCommittedUnexposedHold() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    let grant = try #require(await lease.acquireHold(token))
    #expect(await grant.commit() == true)
    await grant.revoke()
    let holders = await pool.holders(epoch: lease.epoch, generation: lease.generation)
    #expect(!holders.contains(.subscription(token)))
    _ = published
}

@Test("a draining token closes only when no provisional and no committed hold remains")
func drainingClosesOnlyWhenFullyReleased() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 7)
    let first = try #require(await pool.acquire(width: 8, height: 8))
    let second = try #require(await pool.acquire(width: 8, height: 8))
    let leaseFirst = try #require(first.lease)
    let leaseSecond = try #require(second.lease)
    let holdFirst = try #require(await leaseFirst.acquireHold(token))
    #expect(await holdFirst.commit() == true)
    let holdSecond = try #require(await leaseSecond.acquireHold(token))  // provisional
    await pool.beginDrain(token)
    // Committed first + provisional second → not closed.
    #expect(await pool.tokenState(token) == .draining)
    // Release the committed one; the provisional still blocks close.
    let accepted = await pool.applyWatermark(
        token: token,
        epoch: leaseFirst.epoch,
        lowestHeld: leaseSecond.generation,
        connectionId: 7
    )
    #expect(accepted)
    #expect(await pool.tokenState(token) == .draining)
    // Cancel the outstanding reservation → fully released → closed.
    await holdSecond.cancel()
    #expect(await pool.tokenState(token) == nil)
    _ = (first, second)
}

@Test("unregisterTokenIfUnused returns false while a grant exists")
func unregisterTokenIfUnusedRespectsHolds() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let grant = try #require(await published.lease?.acquireHold(token))
    #expect(await pool.unregisterTokenIfUnused(token) == false)
    await grant.cancel()
    #expect(await pool.unregisterTokenIfUnused(token) == true)
    _ = published
}

// MARK: - Watermark acknowledgement

@Test("watermark rejects a mismatched connection id")
func watermarkRejectsWrongConnection() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    let grant = try #require(await lease.acquireHold(token))
    #expect(await grant.commit() == true)
    // Foreign connection is rejected and counted; the hold survives.
    let foreign = await pool.applyWatermark(
        token: token,
        epoch: lease.epoch,
        lowestHeld: lease.generation + 1,
        connectionId: 2
    )
    #expect(foreign == false)
    #expect(await pool.snapshotCounters().rejectedWrongConnection == 1)
    let stillHeld = await pool.holders(epoch: lease.epoch, generation: lease.generation)
    #expect(stillHeld.contains(.subscription(token)))
    // The registering connection releases it.
    let owned = await pool.applyWatermark(
        token: token,
        epoch: lease.epoch,
        lowestHeld: lease.generation + 1,
        connectionId: 1
    )
    #expect(owned)
    let released = await pool.holders(epoch: lease.epoch, generation: lease.generation)
    #expect(!released.contains(.subscription(token)))
    _ = published
}

@Test("acquireHold rejects at-most-once and below-frontier generations")
func acquireHoldRejectBoundaries() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    _ = try #require(await lease.acquireHold(token))
    // Re-reserving the same generation is a duplicate → nil.
    #expect(await lease.acquireHold(token) == nil)
    #expect(await pool.snapshotCounters().rejectedAtMostOnce == 1)
    _ = published
}

@Test("watermark releases strictly below and admits a later grant at the frontier")
func watermarkBoundaryAdmitsNextGeneration() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let first = try #require(await pool.acquire(width: 8, height: 8))
    let leaseFirst = try #require(first.lease)
    let holdFirst = try #require(await leaseFirst.acquireHold(token))
    #expect(await holdFirst.commit() == true)
    // Watermark one past the first generation releases it and raises the
    // frontier.
    let accepted = await pool.applyWatermark(
        token: token,
        epoch: leaseFirst.epoch,
        lowestHeld: leaseFirst.generation + 1,
        connectionId: 1
    )
    #expect(accepted)
    let released = await pool.holders(epoch: leaseFirst.epoch, generation: leaseFirst.generation)
    #expect(!released.contains(.subscription(token)))
    // The next generation (== the frontier) is still grantable.
    let second = try #require(await pool.acquire(width: 8, height: 8))
    let leaseSecond = try #require(second.lease)
    #expect(leaseSecond.generation == leaseFirst.generation + 1)
    let holdSecond = try #require(await leaseSecond.acquireHold(token))
    #expect(await holdSecond.commit() == true)
    _ = (first, second)
}

@Test("watermark below the accepted frontier rejects a later reservation")
func belowFrontierReservationRejected() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    // Force the frontier far above the small live generations.
    let accepted = await pool.applyWatermark(
        token: token,
        epoch: lease.epoch,
        lowestHeld: 100,
        connectionId: 1
    )
    #expect(accepted)
    #expect(await lease.acquireHold(token) == nil)
    #expect(await pool.snapshotCounters().rejectedBelowFrontier == 1)
    _ = published
}

@Test("orphaned token closes once its committed hold is acked")
func orphanedClosesAfterAck() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 4)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    let grant = try #require(await lease.acquireHold(token))
    #expect(await grant.commit() == true)
    await pool.orphan(token)
    #expect(await pool.tokenState(token) == .orphaned)
    // A late ack still drains the orphaned hold → closed.
    let accepted = await pool.applyWatermark(
        token: token,
        epoch: lease.epoch,
        lowestHeld: lease.generation + 1,
        connectionId: 4
    )
    #expect(accepted)
    #expect(await pool.tokenState(token) == nil)
    _ = published
}

@Test("diagnoseDelinquent flags a hold older than the threshold under an injected clock")
func diagnoseDelinquentUsesInjectedClock() async throws {
    let base: UInt64 = 1_000
    let pool = LeasedSurfacePool(
        slotCount: 3,
        now: { base },
        delinquencyThresholdNs: 2_000_000_000
    )
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    _ = try #require(await lease.acquireHold(token))
    // One second later: under threshold → nothing flagged.
    #expect(await pool.diagnoseDelinquent(now: base + 1_000_000_000).isEmpty)
    // Three seconds later: over threshold → flagged, diagnosis only.
    let delinquent = await pool.diagnoseDelinquent(now: base + 3_000_000_000)
    #expect(delinquent.count == 1)
    #expect(delinquent.first?.token == token)
    // Diagnosis never reclaims: the hold still stands.
    let holders = await pool.holders(epoch: lease.epoch, generation: lease.generation)
    #expect(holders.contains(.subscription(token)))
    _ = published
}

/// A movable clock so a test can age one hold past another on the same
/// slot. `@unchecked Sendable` is sound because every access is serialized
/// by the pool's actor hops: the test mutates `nanoseconds` only while
/// suspended at an `await` on a pool call, and the pool reads it (through
/// the injected `now` closure) only while running that call, so a read and
/// a write never overlap.
private final class ClockBox: @unchecked Sendable {
    var nanoseconds: UInt64
    init(_ nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
}

@Test("delinquency ages per subscription, not per slot")
func delinquencyIsPerSubscription() async throws {
    let clock = ClockBox(1_000)
    let pool = LeasedSurfacePool(
        slotCount: 3,
        now: { clock.nanoseconds },
        delinquencyThresholdNs: 2_000_000_000
    )
    let early = UUID()
    let late = UUID()
    await pool.registerToken(early, connectionId: 1)
    await pool.registerToken(late, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    // The early subscriber takes its hold, then time advances, then the
    // late subscriber takes a hold on the same slot/generation.
    _ = try #require(await lease.acquireHold(early))
    clock.nanoseconds = 1_000 + 3_000_000_000
    _ = try #require(await lease.acquireHold(late))
    // Half a second past the late hold: the early hold (3.5s old) is
    // delinquent; the late hold (0.5s old) is not, so no false positive.
    let delinquent = await pool.diagnoseDelinquent(now: clock.nanoseconds + 500_000_000)
    #expect(delinquent.map(\.token) == [early])
    _ = published
}

@Test("controlled recovery is one-shot: retire once, then exhausted")
func recoveryIsOneShot() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    _ = try #require(await pool.acquire(width: 4, height: 4))
    #expect(await pool.recoverFromExhaustion() == .recovered)
    #expect(await pool.recoverFromExhaustion() == .exhausted)
}

@Test("recovery never re-hands a held (orphaned) generation")
func recoveryDoesNotReuseHeldSurfaces() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)

    // Fill every slot with a committed subscription hold, then orphan the
    // token so those holds are pinned (never force-freed).
    var heldGenerations: Set<UInt64> = []
    for _ in 0..<3 {
        let published = try #require(await pool.acquire(width: 4, height: 4))
        let lease = try #require(published.lease)
        heldGenerations.insert(lease.generation)
        let grant = try #require(await lease.acquireHold(token))
        #expect(await grant.commit())
    }
    await pool.orphan(token)

    // Sustained exhaustion → one recovery: the active epoch (with its
    // pinned holds) is quarantined. Recovery itself allocates nothing: the
    // replacement epoch is allocated lazily by the next `acquire` below.
    #expect(await pool.recoverFromExhaustion() == .recovered)

    // Every post-recovery frame is a brand-new generation from the freshly
    // allocated epoch, so no held surface from the quarantined epoch is ever
    // handed back out.
    for _ in 0..<3 {
        let published = try #require(await pool.acquire(width: 4, height: 4))
        let generation = try #require(published.lease?.generation)
        #expect(!heldGenerations.contains(generation))
    }
    // The orphaned epoch is still retained (its holds pinned), not pruned.
    #expect(await pool.quarantinedEpochCount() == 1)
}
