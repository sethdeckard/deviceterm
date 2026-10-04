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

@Test("slot ceiling clamps to the documented range", arguments: [(1, 3), (99, 8)])
func slotCeilingClamps(configured: Int, ceiling: Int) async throws {
    let pool = LeasedSurfacePool(slotCount: configured)
    var held: [PublishedSurface] = []
    for _ in 0..<ceiling { held.append(try await acquireOne(pool)) }
    #expect(await pool.allocatedSlotCount() == ceiling)
    #expect(await pool.acquire(width: 8, height: 8) == nil)
    #expect(await pool.snapshotCounters().exhaustionDrops == 1)
    _ = held
}

@Test("an epoch allocates nothing until acquired, then one slot per concurrent hold")
func slotsAllocateOnDemand() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    #expect(await pool.allocatedSlotCount() == 0)
    let first = try await acquireOne(pool)
    #expect(await pool.allocatedSlotCount() == 1)
    let second = try await acquireOne(pool)
    #expect(await pool.allocatedSlotCount() == 2)
    #expect(await pool.snapshotCounters().slotsAllocated == 2)
    #expect(await pool.allocatedHighWater() == 2)
    _ = (first, second)
}

@Test("releasing each frame before the next reuses one slot")
func oneHoldAtATimeReusesOneSlot() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    for _ in 0..<5 {
        var published: PublishedSurface? = try await acquireOne(pool)
        _ = published
        published = nil
        _ = await waitForFreeSlots(pool, atLeast: 1)
    }
    #expect(await pool.allocatedSlotCount() == 1)
    #expect(await pool.allocatedHighWater() == 1)
}

@Test("while allocations succeed, a free slot still in use is grown past and reused only at the ceiling")
func inUseSlotIsReusedOnlyAtTheCeiling() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    var first: PublishedSurface? = try await acquireOne(pool)
    let warm = try #require(first).surface.withRef { $0 }
    let warmID = IOSurfaceGetID(warm)
    // A consumer's use count outliving the slot's release.
    IOSurfaceIncrementUseCount(warm)
    defer { IOSurfaceDecrementUseCount(warm) }
    first = nil
    _ = await waitForFreeSlots(pool, atLeast: 1)

    let second = try await acquireOne(pool)
    let third = try await acquireOne(pool)
    #expect(surfaceID(second) != warmID)
    #expect(surfaceID(third) != warmID)
    #expect(await pool.snapshotCounters().reuseWhileInUse == 0)

    // At the ceiling the in-use slot is the only one left, so it is reused
    // and counted.
    let fourth = try await acquireOne(pool)
    #expect(surfaceID(fourth) == warmID)
    #expect(await pool.snapshotCounters().reuseWhileInUse == 1)
    _ = (second, third, fourth)
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
        _ = await waitForFreeSlots(pool, atLeast: 1)
    }
    #expect(generations == [1, 2, 3])
}

@Test("dropping the published surface frees the slot")
func daemonCurrentReleaseFreesSlot() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    var published: PublishedSurface? = try await acquireOne(pool)
    _ = published
    #expect(await pool.freeSlotCount() == 0)
    published = nil
    #expect(await waitForFreeSlots(pool, atLeast: 1) == 1)
}

@Test("free selection is least-recently-freed")
func leastRecentlyFreedReuse() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    var frameA: PublishedSurface? = try await acquireOne(pool)
    var frameB: PublishedSurface? = try await acquireOne(pool)
    let frameC = try #require(await pool.acquire(width: 8, height: 8))
    let idA = surfaceID(try #require(frameA))
    let idB = surfaceID(try #require(frameB))
    // All three slots are allocated. Free A first, then B. The next acquire
    // reuses A (freed least recently), not B, and allocates nothing new.
    frameA = nil
    _ = await waitForFreeSlots(pool, atLeast: 1)
    frameB = nil
    _ = await waitForFreeSlots(pool, atLeast: 2)
    let reused = try #require(await pool.acquire(width: 8, height: 8))
    #expect(surfaceID(reused) == idA)
    #expect(surfaceID(reused) != idB)
    #expect(await pool.allocatedSlotCount() == 3)
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
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .recovered)
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .exhausted)
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
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .recovered)

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

// MARK: - Idle reclaim

/// Poll until the active epoch has exactly `count` slots allocated (a
/// daemon-current release reaches the pool asynchronously).
private func waitForAllocated(_ pool: LeasedSurfacePool, exactly count: Int) async -> Int {
    for _ in 0..<200 {
        let allocated = await pool.allocatedSlotCount()
        if allocated == count { return allocated }
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return await pool.allocatedSlotCount()
}

@Test("going idle frees unheld slots and keeps held ones")
func idleFreesUnheldSlots() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    let held = try await acquireOne(pool)
    var released: [PublishedSurface]? = [try await acquireOne(pool), try await acquireOne(pool)]
    _ = released
    released = nil
    _ = await waitForFreeSlots(pool, atLeast: 2)
    #expect(await pool.allocatedSlotCount() == 3)

    await pool.setIdle(true, serial: 1)
    #expect(await pool.allocatedSlotCount() == 1)
    #expect(await pool.snapshotCounters().slotsAllocated == 1)
    _ = held
}

@Test("a hold released while idle frees its slot")
func idleReleaseShrinksThePool() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    var held: PublishedSurface? = try await acquireOne(pool)
    await pool.setIdle(true, serial: 1)
    #expect(await pool.allocatedSlotCount() == 1)
    _ = held
    held = nil
    #expect(await waitForAllocated(pool, exactly: 0) == 0)
}

@Test("a subscription hold acked while idle frees its slot")
func idleWatermarkShrinksThePool() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    var published: PublishedSurface? = try await acquireOne(pool)
    let lease = try #require(published?.lease)
    let grant = try #require(await lease.acquireHold(token))
    #expect(await grant.commit())
    published = nil
    await pool.setIdle(true, serial: 1)
    // Wait for the daemon-current release, so only the subscription hold
    // keeps the slot.
    for _ in 0..<200 {
        if await pool.holders(epoch: lease.epoch, generation: lease.generation) == [.subscription(token)] {
            break
        }
        try? await Task.sleep(nanoseconds: 500_000)
    }
    #expect(await pool.holders(epoch: lease.epoch, generation: lease.generation) == [.subscription(token)])
    #expect(await pool.allocatedSlotCount() == 1)
    await pool.applyWatermark(
        token: token,
        epoch: lease.epoch,
        lowestHeld: lease.generation + 1,
        connectionId: 1
    )
    #expect(await pool.allocatedSlotCount() == 0)
}

@Test("leaving idle grows the pool back and restores reuse")
func leavingIdleRestoresReuse() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    await pool.setIdle(true, serial: 1)
    await pool.setIdle(false, serial: 2)
    for _ in 0..<3 {
        var published: PublishedSurface? = try await acquireOne(pool)
        _ = published
        published = nil
        _ = await waitForFreeSlots(pool, atLeast: 1)
    }
    #expect(await pool.allocatedSlotCount() == 1)
}

@Test("a demand change older than one already applied is ignored")
func staleIdleChangeIsIgnored() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    // Resume (serial 3) lands before the pause it followed (serial 2).
    await pool.setIdle(false, serial: 3)
    await pool.setIdle(true, serial: 2)
    var published: PublishedSurface? = try await acquireOne(pool)
    _ = published
    published = nil
    #expect(await waitForFreeSlots(pool, atLeast: 1) == 1)
    #expect(await pool.allocatedSlotCount() == 1)
}

@Test("a capture in flight when the pause lands does not end idle")
func acquireWhileIdleStaysIdle() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    await pool.setIdle(true, serial: 1)
    var published: PublishedSurface? = try await acquireOne(pool)
    #expect(await pool.allocatedSlotCount() == 1)
    _ = published
    published = nil
    #expect(await waitForAllocated(pool, exactly: 0) == 0)
}

@Test("going idle frees unheld slots in a retired epoch that still has holds")
func idleFreesUnheldRetiredSlots() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    let held = try await acquireOne(pool)
    var released: PublishedSurface? = try await acquireOne(pool)
    _ = released
    released = nil
    _ = await waitForFreeSlots(pool, atLeast: 1)
    // Retire the epoch with one slot held and one free.
    #expect(await pool.retireAll())
    #expect(await pool.snapshotCounters().slotsAllocated == 2)

    await pool.setIdle(true, serial: 1)
    #expect(await pool.quarantinedEpochCount() == 1)
    #expect(await pool.snapshotCounters().slotsAllocated == 1)
    _ = held
}

/// Acquire `count` slots with committed holds by `token`, and return their
/// epoch. The published surfaces are dropped, so only the subscription holds
/// remain once their daemon-current releases land, which this waits for.
private func fillWithCommittedHolds(
    _ pool: LeasedSurfacePool,
    token: UUID,
    count: Int = 3,
    width: Int = 4
) async throws -> UInt64 {
    var epoch: UInt64 = 0
    for _ in 0..<count {
        let published = try #require(await pool.acquire(width: width, height: width))
        let lease = try #require(published.lease)
        epoch = lease.epoch
        let grant = try #require(await lease.acquireHold(token))
        #expect(await grant.commit())
    }
    #expect(await waitForDaemonCurrentReleases(pool))
    return epoch
}

/// Poll for the producer's own holds on dropped frames to release, which
/// happens asynchronously from `LeasedSurface.deinit`. Checks up to 400 times
/// with a delay, then checks once more before returning whether they did.
private func waitForDaemonCurrentReleases(_ pool: LeasedSurfacePool) async -> Bool {
    for _ in 0..<400 {
        if await pool.daemonCurrentHoldCount() == 0 { return true }
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return await pool.daemonCurrentHoldCount() == 0
}

@Test("after recovery, a slot held by a live consumer answers consumerBehind")
func spentRecoveryWithALiveHoldWaitsForTheConsumer() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    _ = try await fillWithCommittedHolds(pool, token: token)
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .recovered)
    _ = try await fillWithCommittedHolds(pool, token: token)
    #expect(await pool.acquire(width: 4, height: 4) == nil)
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .consumerBehind)
}

@Test("after recovery, holds pinned only by an orphaned consumer still fail")
func spentRecoveryWithOnlyOrphanedHoldsIsExhausted() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    _ = try await fillWithCommittedHolds(pool, token: token)
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .recovered)
    _ = try await fillWithCommittedHolds(pool, token: token)
    await pool.orphan(token)
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .exhausted)
}

@Test("a full quarantine budget with a live hold waits rather than failing")
func fullQuarantineBudgetWithALiveHoldWaits() async throws {
    let pool = LeasedSurfacePool(slotCount: 3, quarantineBudget: 1)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    // A resize rotates the held epoch into the single quarantine place.
    _ = try await fillWithCommittedHolds(pool, token: token, count: 1, width: 4)
    _ = try await fillWithCommittedHolds(pool, token: token, width: 8)
    #expect(await pool.quarantinedEpochCount() == 1)
    // The first recovery's retirement fails on the full budget.
    #expect(await pool.recoverFromExhaustion(width: 8, height: 8) == .consumerBehind)
}

@Test("a consumer that catches up frees its slots in the same epoch")
func aCaughtUpConsumerFreesSlotsWithoutANewEpoch() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    _ = try await fillWithCommittedHolds(pool, token: token)
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .recovered)
    let epoch = try await fillWithCommittedHolds(pool, token: token)
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .consumerBehind)

    // The watermark acknowledges every generation the consumer held.
    #expect(await pool.applyWatermark(token: token, epoch: epoch, lowestHeld: .max, connectionId: 1))
    _ = await waitForFreeSlots(pool, atLeast: 1)
    let next = try #require(await pool.acquire(width: 4, height: 4))
    #expect(try #require(next.lease).epoch == epoch)
}

@Test("a resize blocked by orphan-pinned quarantine fails even while a live consumer holds the current epoch")
func aResizeBlockedByOrphanedQuarantineIsExhausted() async throws {
    let pool = LeasedSurfacePool(slotCount: 3, quarantineBudget: 1)
    let gone = UUID()
    let live = UUID()
    await pool.registerToken(gone, connectionId: 1)
    await pool.registerToken(live, connectionId: 2)
    // An epoch pinned by a consumer that went away fills the only quarantine
    // place once a resize rotates it out.
    _ = try await fillWithCommittedHolds(pool, token: gone, count: 1, width: 4)
    await pool.orphan(gone)
    // A healthy consumer holds the current epoch, including its current frame.
    let current = try #require(await pool.acquire(width: 8, height: 8))
    let grant = try #require(await current.lease?.acquireHold(live))
    #expect(await grant.commit())
    #expect(await pool.quarantinedEpochCount() == 1)
    // Another resize can't rotate, and no live release can drain the
    // orphan-pinned quarantine, so waiting would freeze the pane for good.
    #expect(await pool.acquire(width: 16, height: 16) == nil)
    #expect(await pool.recoverFromExhaustion(width: 16, height: 16) == .exhausted)
    _ = current
}

@Test("slots pinned by an orphan or the producer's own frame can't be freed by a live consumer")
func slotsOnlyAnOrphanOrTheProducerCanFreeAreExhausted() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let gone = UUID()
    let live = UUID()
    await pool.registerToken(gone, connectionId: 1)
    await pool.registerToken(live, connectionId: 2)
    _ = try await fillWithCommittedHolds(pool, token: live)
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .recovered)
    // Two slots pinned by the departed consumer, and the producer's current
    // frame, which the live consumer also holds.
    _ = try await fillWithCommittedHolds(pool, token: gone, count: 2)
    await pool.orphan(gone)
    let current = try #require(await pool.acquire(width: 4, height: 4))
    let grant = try #require(await current.lease?.acquireHold(live))
    #expect(await grant.commit())
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .exhausted)
    _ = current
}

@Test("an acknowledgement landing before the recovery check counts as freed capacity")
func anAckBeforeTheRecoveryCheckWaitsRatherThanFailing() async throws {
    let pool = LeasedSurfacePool(slotCount: 3)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    _ = try await fillWithCommittedHolds(pool, token: token)
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .recovered)
    // Two older frames the consumer holds, and the current frame, which the
    // producer and the consumer both hold.
    let epoch = try await fillWithCommittedHolds(pool, token: token, count: 2)
    let current = try #require(await pool.acquire(width: 4, height: 4))
    let currentLease = try #require(current.lease)
    let grant = try #require(await currentLease.acquireHold(token))
    #expect(await grant.commit())
    #expect(await pool.acquire(width: 4, height: 4) == nil)
    // The consumer catches up between the failed acquire and the check,
    // releasing everything older than the current frame.
    #expect(await pool.applyWatermark(
        token: token,
        epoch: epoch,
        lowestHeld: currentLease.generation,
        connectionId: 1
    ))
    _ = await waitForFreeSlots(pool, atLeast: 1)
    #expect(await pool.recoverFromExhaustion(width: 4, height: 4) == .consumerBehind)
    #expect(await pool.acquire(width: 4, height: 4) != nil)
    _ = current
}
