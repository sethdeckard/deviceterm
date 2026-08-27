// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// The pool times how long a consumer holds a surface, which is the daemon's
// only view of publish-to-ack latency. It reuses the hold timestamps the pool
// already keeps per slot, so these pin *which* releases count: an accepted
// watermark is a completed round trip, while a cancelled or revoked grant never
// reached a consumer and would drag the distribution toward zero.

/// A settable monotonic clock. `@unchecked Sendable` is sound because every
/// access goes through the lock.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UInt64 = 0

    var value: UInt64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}

@Test("collection is off unless the daemon's frame metrics armed it")
func holdAgesAreNotCollectedByDefault() async throws {
    let clock = MutableClock()
    let pool = LeasedSurfacePool(slotCount: 3, now: { clock.value })
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    let hold = try #require(await lease.acquireHold(token))
    #expect(await hold.commit() == true)

    clock.value = 5_000_000
    #expect(await pool.applyWatermark(
        token: token,
        epoch: lease.epoch,
        lowestHeld: lease.generation + 1,
        connectionId: 1
    ))

    #expect(await pool.drainHoldAges().sampleCount == 0)
    _ = published
}

@Test("an acknowledged hold records its age from grant to watermark")
func acknowledgedHoldRecordsItsAge() async throws {
    let clock = MutableClock()
    let pool = LeasedSurfacePool(slotCount: 3, now: { clock.value }, recordHoldAges: true)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    let hold = try #require(await lease.acquireHold(token))
    #expect(await hold.commit() == true)

    clock.value = 5_000_000
    let accepted = await pool.applyWatermark(
        token: token,
        epoch: lease.epoch,
        lowestHeld: lease.generation + 1,
        connectionId: 1
    )
    #expect(accepted)

    let ages = await pool.drainHoldAges()
    #expect(ages.sampleCount == 1)
    #expect(ages.maximum == 5_000_000)
    _ = published
}

@Test("a revoked grant records nothing, since it never reached a consumer")
func revokedGrantIsNotTimed() async throws {
    let clock = MutableClock()
    let pool = LeasedSurfacePool(slotCount: 3, now: { clock.value }, recordHoldAges: true)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    let hold = try #require(await lease.acquireHold(token))
    #expect(await hold.commit() == true)

    clock.value = 5_000_000
    await hold.revoke()

    #expect(await pool.drainHoldAges().sampleCount == 0)
    _ = published
}

@Test("a cancelled grant records nothing")
func cancelledGrantIsNotTimed() async throws {
    let clock = MutableClock()
    let pool = LeasedSurfacePool(slotCount: 3, now: { clock.value }, recordHoldAges: true)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    let hold = try #require(await lease.acquireHold(token))

    clock.value = 5_000_000
    await hold.cancel()

    #expect(await pool.drainHoldAges().sampleCount == 0)
    _ = published
}

@Test("draining starts a fresh accumulation window")
func drainingResetsTheWindow() async throws {
    let clock = MutableClock()
    let pool = LeasedSurfacePool(slotCount: 3, now: { clock.value }, recordHoldAges: true)
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 8, height: 8))
    let lease = try #require(published.lease)
    let hold = try #require(await lease.acquireHold(token))
    #expect(await hold.commit() == true)
    clock.value = 3_000_000
    #expect(await pool.applyWatermark(
        token: token,
        epoch: lease.epoch,
        lowestHeld: lease.generation + 1,
        connectionId: 1
    ))

    #expect(await pool.drainHoldAges().sampleCount == 1)
    #expect(await pool.drainHoldAges().sampleCount == 0)
    _ = published
}
