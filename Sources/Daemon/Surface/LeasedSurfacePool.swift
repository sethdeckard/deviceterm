// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import IOSurface

/// A per-pane pool of daemon-owned IOSurfaces with an
/// acknowledged lease protocol.
///
/// A decoded device frame is copied into a pool slot before it is handed to
/// subscribers, isolating them from VideoToolbox's decode pool. A slot is
/// reused only once every hold on it has been released: the daemon-current
/// owner (dropped by ARC when a newer frame supersedes it) plus one
/// subscription hold per subscribed GUI, each released only by a cumulative
/// watermark acknowledgement. A slot with any live hold is never
/// overwritten, so a slow consumer can never be shown a mixed- or
/// wrong-generation frame.
///
/// Slot identity on the wire is the **generation**, a per-pane monotonic
/// counter that never repeats, so a stale ack can only ever match the one
/// grant it named. The **epoch** groups a slot set: resize and controlled
/// recovery retire the current set (quarantined, never re-acquired) and
/// allocate a fresh epoch, so old and new leases coexist while the retired
/// set drains.
///
/// This type is `actor`-isolated; every mutation is serialized. Subscription
/// holds exist only for registered tokens, so a pane with no subscribers
/// takes only `.daemonCurrent` holds and the pool behaves like a
/// least-recently-freed reuse pool.
actor LeasedSurfacePool {
    private final class PhysicalSlot {
        let surface: IOSurfaceRef
        var generation: UInt64?
        var holders: Set<SurfaceHolder> = []
        /// Monotonic free-order stamp; the least-recently-freed slot has
        /// the smallest value, maximizing reuse distance.
        var freeSeq: UInt64
        /// When each subscription hold on this slot was taken, keyed by
        /// token: one slot can carry several tokens' holds, added at
        /// different times, so delinquency ages must be per subscription.
        var subscriptionHoldSince: [UUID: UInt64] = [:]
        var isFree: Bool { holders.isEmpty }

        init(surface: IOSurfaceRef, freeSeq: UInt64) {
            self.surface = surface
            self.freeSeq = freeSeq
        }
    }

    private final class EpochPool {
        let epoch: UInt64
        let width: Int
        let height: Int
        var slots: [PhysicalSlot]
        var hasLiveHold: Bool { slots.contains { !$0.isFree } }

        init(epoch: UInt64, width: Int, height: Int, slots: [PhysicalSlot]) {
            self.epoch = epoch
            self.width = width
            self.height = height
            self.slots = slots
        }
    }

    private final class TokenEpoch {
        var highestReserved: UInt64 = 0
        var highestCommitted: UInt64 = 0
        var acceptedLowestHeld: UInt64 = 0
        var provisional: Set<UInt64> = []
        var committed: Set<UInt64> = []
        var isEmpty: Bool { provisional.isEmpty && committed.isEmpty }
    }

    private final class TokenInfo {
        var state: SurfaceTokenState = .active
        let connectionId: UInt64
        var perEpoch: [UInt64: TokenEpoch] = [:]
        var hasAnyHold: Bool { perEpoch.values.contains { !$0.isEmpty } }

        init(connectionId: UInt64) { self.connectionId = connectionId }
    }

    /// Documented clamp for the configured slot count.
    static let slotRange = 3...8

    private let slotCount: Int
    private let now: @Sendable () -> UInt64
    private let delinquencyThresholdNs: UInt64
    private let quarantineBudget: Int

    private var nextGeneration: UInt64 = 0
    private var nextEpoch: UInt64 = 0
    private var freeSeqCounter: UInt64 = 0

    private var active: EpochPool?
    private var quarantined: [EpochPool] = []
    private var tokens: [UUID: TokenInfo] = [:]
    private var counters = SurfacePoolCounters()
    /// One controlled recovery is permitted per pool: after it, another
    /// sustained exhaustion is fatal rather than retiring again indefinitely.
    private var usedRecovery = false

    /// - Parameters:
    ///   - slotCount: clamped to `slotRange`.
    ///   - now: monotonic nanosecond clock (injected for tests).
    ///   - delinquencyThresholdNs: hold age past which `diagnoseDelinquent`
    ///     flags a lease (default ~2s).
    ///   - quarantineBudget: max retired epochs retained at once.
    init(
        slotCount: Int,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        delinquencyThresholdNs: UInt64 = 2_000_000_000,
        quarantineBudget: Int = 2
    ) {
        self.slotCount = min(max(slotCount, Self.slotRange.lowerBound), Self.slotRange.upperBound)
        self.now = now
        self.delinquencyThresholdNs = delinquencyThresholdNs
        self.quarantineBudget = max(1, quarantineBudget)
    }

    // MARK: - Acquire (daemon-current)

    /// Acquire the least-recently-freed slot at `(width, height)` as a new
    /// generation held by `.daemonCurrent`, ready for the caller to copy
    /// pixels into. Rotates to a fresh epoch when the dimensions change.
    /// Returns nil on exhaustion (no free slot) or when a rotation would
    /// exceed the quarantine budget, so the caller drops the frame.
    func acquire(width: Int, height: Int) -> PublishedSurface? {
        guard width > 0, height > 0 else { return nil }
        pruneEmptyQuarantined()
        if active == nil || active?.width != width || active?.height != height {
            // A rotation can fail because the quarantine budget is full
            // (counted in `retireAll`) or because slot allocation failed;
            // don't double-count the budget case here.
            guard rotateEpoch(width: width, height: height) else { return nil }
        }
        guard let epochPool = active else { return nil }
        guard let slot = leastRecentlyFreedSlot(in: epochPool) else {
            counters.exhaustionDrops += 1
            return nil
        }
        // Telemetry (not an authority): count reuse attempts while the
        // IOSurface still reports a nonzero use count. This does not prove
        // which holder kept it in use or when it should have been released.
        if IOSurfaceIsInUse(slot.surface) {
            counters.reuseWhileInUse += 1
        }
        nextGeneration += 1
        let generation = nextGeneration
        slot.generation = generation
        slot.holders = [.daemonCurrent]
        slot.subscriptionHoldSince.removeAll()

        let epoch = epochPool.epoch
        let owned = LeasedSurface(
            surface: RetainedSurface(slot.surface),
            onRelease: { [weak self] in
                Task { [weak self] in
                    await self?.releaseDaemonCurrent(epoch: epoch, generation: generation)
                }
            }
        )
        let lease = LeaseMetadata(
            epoch: epoch,
            generation: generation,
            acquireHold: { [weak self] token in
                guard let self else { return nil }
                return await self.reserveHold(epoch: epoch, generation: generation, token: token)
            }
        )
        return PublishedSurface(owned: owned, lease: lease)
    }

    private func leastRecentlyFreedSlot(in pool: EpochPool) -> PhysicalSlot? {
        pool.slots.filter(\.isFree).min { $0.freeSeq < $1.freeSeq }
    }

    private func releaseDaemonCurrent(epoch: UInt64, generation: UInt64) {
        guard let slot = slot(epoch: epoch, generation: generation) else { return }
        slot.holders.remove(.daemonCurrent)
        freeSlotIfEmpty(slot)
    }

    // MARK: - Token registration & lifecycle

    func registerToken(_ token: UUID, connectionId: UInt64) {
        if tokens[token] == nil {
            tokens[token] = TokenInfo(connectionId: connectionId)
        }
    }

    /// Drop the token only when it holds no provisional or committed grant
    /// anywhere; returns false so the caller falls back to drain/orphan.
    @discardableResult
    func unregisterTokenIfUnused(_ token: UUID) -> Bool {
        guard let info = tokens[token] else { return true }
        guard !info.hasAnyHold else { return false }
        tokens[token] = nil
        return true
    }

    func beginDrain(_ token: UUID) {
        guard let info = tokens[token], info.state == .active || info.state == .draining else { return }
        info.state = .draining
        closeIfDrained(token)
    }

    // A disconnect is not proof the GPU finished reading, so an orphaned
    // token's held slots are never force-reclaimed on teardown: they stay
    // pinned and are freed only by a late ack that names them.
    func orphan(_ token: UUID) {
        guard let info = tokens[token], info.state != .closed else { return }
        info.state = .orphaned
        closeIfDrained(token)
    }

    /// Orphan every token registered by `connectionId` (an abrupt
    /// disconnect). Held slots are quarantined, never force-freed.
    func orphanConnection(_ connectionId: UInt64) {
        for (token, info) in tokens where info.connectionId == connectionId {
            info.state = info.state == .closed ? .closed : .orphaned
            closeIfDrained(token)
        }
    }

    func tokenState(_ token: UUID) -> SurfaceTokenState? { tokens[token]?.state }

    // MARK: - Grant lifecycle

    private func reserveHold(epoch: UInt64, generation: UInt64, token: UUID) -> Grant? {
        guard let info = tokens[token], info.state == .active else { return nil }
        guard let slot = slot(epoch: epoch, generation: generation) else { return nil }
        let epochState = tokenEpoch(info, epoch)
        guard generation > epochState.highestReserved else {
            counters.rejectedAtMostOnce += 1
            return nil
        }
        guard generation >= epochState.acceptedLowestHeld else {
            counters.rejectedBelowFrontier += 1
            return nil
        }
        epochState.highestReserved = generation
        epochState.provisional.insert(generation)
        if slot.holders.insert(.subscription(token)).inserted {
            slot.subscriptionHoldSince[token] = now()
        }
        return Grant(epoch: epoch, generation: generation, token: token, pool: self)
    }

    /// Promote a provisional hold to committed before the send. Returns
    /// false if the token is no longer `active` (caller cancels).
    func commitGrant(epoch: UInt64, generation: UInt64, token: UUID) -> Bool {
        guard let info = tokens[token] else { return false }
        guard let epochState = info.perEpoch[epoch] else { return false }
        if epochState.committed.contains(generation) { return true }
        guard epochState.provisional.contains(generation) else { return false }
        guard info.state == .active else { return false }
        epochState.provisional.remove(generation)
        epochState.committed.insert(generation)
        epochState.highestCommitted = max(epochState.highestCommitted, generation)
        return true
    }

    /// Remove a provisional (pre-commit) hold.
    func cancelGrant(epoch: UInt64, generation: UInt64, token: UUID) {
        guard let epochState = tokens[token]?.perEpoch[epoch] else { return }
        if epochState.provisional.remove(generation) != nil {
            removeSubscriptionHolder(epoch: epoch, generation: generation, token: token)
            closeIfDrained(token)
        }
    }

    /// Remove a committed-but-unexposed hold (post-commit revalidation
    /// failure, before the surface was sent).
    func revokeGrant(epoch: UInt64, generation: UInt64, token: UUID) {
        guard let epochState = tokens[token]?.perEpoch[epoch] else { return }
        if epochState.committed.remove(generation) != nil {
            removeSubscriptionHolder(epoch: epoch, generation: generation, token: token)
            closeIfDrained(token)
        }
    }

    // MARK: - Watermark acknowledgement

    /// Apply a cumulative low-water-mark ack: free committed generations
    /// `< lowestHeld` for `(token, epoch)`. Honored only from the
    /// connection that registered the token, and only while the token is
    /// not `closed`; the epoch may be active or quarantined. Returns
    /// whether the ack was accepted (false → counted no-op).
    @discardableResult
    func applyWatermark(token: UUID, epoch: UInt64, lowestHeld: UInt64, connectionId: UInt64) -> Bool {
        guard let info = tokens[token] else {
            counters.rejectedUnknownToken += 1
            return false
        }
        guard info.state != .closed else {
            counters.rejectedUnknownToken += 1
            return false
        }
        guard info.connectionId == connectionId else {
            counters.rejectedWrongConnection += 1
            return false
        }
        guard epochExists(epoch) else {
            counters.rejectedUnknownEpoch += 1
            return false
        }
        let epochState = tokenEpoch(info, epoch)
        epochState.acceptedLowestHeld = max(epochState.acceptedLowestHeld, lowestHeld)
        for generation in epochState.committed where generation < lowestHeld {
            epochState.committed.remove(generation)
            removeSubscriptionHolder(epoch: epoch, generation: generation, token: token)
        }
        closeIfDrained(token)
        return true
    }

    // MARK: - Epoch rotation & quarantine

    /// Quarantine the active epoch (leases preserved, never re-acquired)
    /// and clear it so the next `acquire` allocates a fresh epoch. Returns
    /// false if the quarantine budget is already full of live-hold epochs.
    @discardableResult
    func retireAll() -> Bool {
        guard let current = active else { return true }
        pruneEmptyQuarantined()
        guard quarantined.count < quarantineBudget else {
            counters.quarantineBudgetExceeded += 1
            return false
        }
        quarantined.append(current)
        active = nil
        return true
    }

    /// Controlled recovery from sustained exhaustion. Retires (quarantines)
    /// the active epoch, **preserving every held slot**, never reclaiming a
    /// live lease. It does not allocate the replacement itself: the next
    /// `acquire` (finding no active epoch) rotates in a fresh epoch of
    /// unused slots. Permitted exactly once: a second call returns
    /// `.exhausted`, as does a first call whose `retireAll` fails because the
    /// quarantine budget is full. A quarantined slot is never re-acquired, so
    /// recovery only ever leads to brand-new generations.
    func recoverFromExhaustion() -> RecoveryOutcome {
        if usedRecovery { return .exhausted }
        // Consume the single allowance up front: a failed `retireAll` (the
        // quarantine budget is full) is terminal (the pane fails), so the
        // attempt itself is spent whether or not it retires. This keeps the
        // "at most one retirement attempt per pool" invariant literal; a
        // budget that later frees up does not resurrect recovery.
        usedRecovery = true
        guard retireAll() else { return .exhausted }
        return .recovered
    }

    private func rotateEpoch(width: Int, height: Int) -> Bool {
        if active != nil {
            guard retireAll() else { return false }
        }
        nextEpoch += 1
        let epoch = nextEpoch
        let slots: [PhysicalSlot] = (0..<slotCount).compactMap { _ in
            guard let surface = SurfaceCopy.makeSurface(width: width, height: height) else { return nil }
            freeSeqCounter += 1
            return PhysicalSlot(surface: surface, freeSeq: freeSeqCounter)
        }
        guard !slots.isEmpty else { return false }
        active = EpochPool(epoch: epoch, width: width, height: height, slots: slots)
        return true
    }

    private func pruneEmptyQuarantined() {
        quarantined.removeAll { !$0.hasLiveHold }
    }

    // MARK: - Delinquency (diagnosis only)

    /// Report subscription holds older than the delinquency threshold.
    /// Diagnosis only: never frees or reclaims.
    func diagnoseDelinquent(now clock: UInt64? = nil) -> [DelinquentHold] {
        let current = clock ?? now()
        var result: [DelinquentHold] = []
        for pool in allPools() {
            for slot in pool.slots {
                guard let generation = slot.generation else { continue }
                for holder in slot.holders {
                    guard case let .subscription(token) = holder,
                        let since = slot.subscriptionHoldSince[token],
                        current >= since,
                        current - since >= delinquencyThresholdNs
                    else { continue }
                    result.append(
                        DelinquentHold(
                            epoch: pool.epoch,
                            generation: generation,
                            token: token,
                            ageNanoseconds: current - since
                        )
                    )
                }
            }
        }
        counters.delinquentObserved += result.count
        return result
    }

    // MARK: - Counters / test queries

    func snapshotCounters() -> SurfacePoolCounters { counters }

    /// Free (unheld) slot count in the active epoch.
    func freeSlotCount() -> Int { active?.slots.filter(\.isFree).count ?? 0 }

    func activeEpoch() -> UInt64? { active?.epoch }

    func quarantinedEpochCount() -> Int { quarantined.count }

    /// The holder set for a generation, searching active + quarantined
    /// epochs. Empty when the generation is unknown or freed.
    func holders(epoch: UInt64, generation: UInt64) -> Set<SurfaceHolder> {
        slot(epoch: epoch, generation: generation)?.holders ?? []
    }

    // MARK: - Private helpers

    private func tokenEpoch(_ info: TokenInfo, _ epoch: UInt64) -> TokenEpoch {
        if let existing = info.perEpoch[epoch] { return existing }
        let created = TokenEpoch()
        info.perEpoch[epoch] = created
        return created
    }

    private func removeSubscriptionHolder(epoch: UInt64, generation: UInt64, token: UUID) {
        guard let slot = slot(epoch: epoch, generation: generation) else { return }
        slot.holders.remove(.subscription(token))
        slot.subscriptionHoldSince[token] = nil
        freeSlotIfEmpty(slot)
    }

    private func freeSlotIfEmpty(_ slot: PhysicalSlot) {
        guard slot.isFree else { return }
        slot.generation = nil
        slot.subscriptionHoldSince.removeAll()
        freeSeqCounter += 1
        slot.freeSeq = freeSeqCounter
    }

    private func closeIfDrained(_ token: UUID) {
        guard let info = tokens[token] else { return }
        guard info.state == .draining || info.state == .orphaned else { return }
        guard !info.hasAnyHold else { return }
        info.state = .closed
        tokens[token] = nil
    }

    private func slot(epoch: UInt64, generation: UInt64) -> PhysicalSlot? {
        guard let pool = poolForEpoch(epoch) else { return nil }
        return pool.slots.first { $0.generation == generation }
    }

    private func poolForEpoch(_ epoch: UInt64) -> EpochPool? {
        if let active, active.epoch == epoch { return active }
        return quarantined.first { $0.epoch == epoch }
    }

    private func epochExists(_ epoch: UInt64) -> Bool { poolForEpoch(epoch) != nil }

    private func allPools() -> [EpochPool] {
        var pools = quarantined
        if let active { pools.append(active) }
        return pools
    }
}
