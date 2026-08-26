// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The GUI half of the surface-lease loop.
///
/// Tracks, per `(paneId, subscriptionToken, leaseEpoch)`, the set of device
/// surface generations the GUI still holds. `acquire` records a generation
/// when a lease is built; `release` drops it when the lease's ARC deinit
/// fires (i.e. the surface is no longer current and every command buffer
/// that sampled it has GPU-completed). A coalescing pump emits one
/// cumulative low-water-mark `pane.surfaceRelease` per key per tick. The
/// daemon then frees committed generations strictly below it.
///
/// The watermark is `min(held)`, or one past the highest generation
/// received when the set is empty (the GUI only ever receives committed
/// generations). It crosses generation numbers never committed to the
/// token (dropped frames) but never a still-held one, and is idempotent
/// and self-healing: a lost tick is corrected by the next absolute
/// watermark.
actor SurfaceReleaseAccountant {
    private struct AccountKey: Hashable {
        let paneId: String
        let subscriptionToken: UUID
        let leaseEpoch: UInt64
    }

    private struct Account {
        var held: Set<UInt64> = []
        var highestReceived: UInt64 = 0
        var lastSent: UInt64?
        var dirty = false
    }

    /// Coalescing tick. One `pane.surfaceRelease` per changed key per tick
    /// caps the notification rate (≈125/s per subscription at 8 ms), using
    /// small request-shaped frames with no response.
    private static let tickNanoseconds: UInt64 = 8_000_000

    private var accounts: [AccountKey: Account] = [:]
    private let send: @Sendable (SurfaceReleaseParams) -> Void
    /// One-shot coalescing flush, armed on a mutation and cleared once it
    /// runs. No timer runs while nothing is dirty, so an idle device pane (or
    /// none at all) wakes the app zero times, not ~125/s.
    private var flushTask: Task<Void, Never>?
    private var stopped = false

    init(send: @escaping @Sendable (SurfaceReleaseParams) -> Void) {
        self.send = send
    }

    /// Record a generation the GUI now holds. Arms the coalescing flush.
    func acquire(paneId: String, subscriptionToken: UUID, leaseEpoch: UInt64, generation: UInt64) {
        guard !stopped else { return }
        let key = AccountKey(paneId: paneId, subscriptionToken: subscriptionToken, leaseEpoch: leaseEpoch)
        var account = accounts[key] ?? Account()
        account.held.insert(generation)
        account.highestReceived = max(account.highestReceived, generation)
        account.dirty = true
        accounts[key] = account
        scheduleFlush()
    }

    /// Drop a released generation. Arms the flush to emit the new watermark.
    func release(paneId: String, subscriptionToken: UUID, leaseEpoch: UInt64, generation: UInt64) {
        guard !stopped else { return }
        let key = AccountKey(paneId: paneId, subscriptionToken: subscriptionToken, leaseEpoch: leaseEpoch)
        guard var account = accounts[key] else { return }
        if account.held.remove(generation) != nil {
            account.dirty = true
            accounts[key] = account
            scheduleFlush()
        }
    }

    /// Re-send every current cumulative watermark after the XPC peer changes
    /// its authenticated session. A release notification sent after the old
    /// session closed is silently refused daemon-side, and no later surface
    /// mutation is guaranteed to repair that lost final watermark.
    func resendCurrentWatermarks() {
        guard !stopped else { return }
        for (key, var account) in accounts {
            account.lastSent = nil
            account.dirty = true
            accounts[key] = account
        }
        flush()
    }

    /// Stop the pump and forget all accounts (connection teardown).
    func stop() {
        stopped = true
        flushTask?.cancel()
        flushTask = nil
        accounts.removeAll()
    }

    /// Arm a single coalescing flush a tick from now, unless one is already
    /// pending. Mutations during the tick fold into that one flush.
    private func scheduleFlush() {
        guard flushTask == nil, !stopped else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.tickNanoseconds)
            guard let self else { return }
            await self.runScheduledFlush()
        }
    }

    private func runScheduledFlush() {
        flushTask = nil
        flush()
    }

    /// Emit one watermark per changed key. `lowestHeld` is `min(held)`, or
    /// one past the highest received generation when the set is empty.
    private func flush() {
        guard !stopped else { return }
        for (key, var account) in accounts where account.dirty {
            let lowestHeld = account.held.min() ?? (account.highestReceived &+ 1)
            account.dirty = false
            defer { accounts[key] = account }
            // Skip a re-send of an unchanged watermark (idempotent anyway,
            // but keeps the rate down).
            if account.lastSent == lowestHeld { continue }
            account.lastSent = lowestHeld
            send(
                SurfaceReleaseParams(
                    paneId: key.paneId,
                    subscriptionToken: key.subscriptionToken.uuidString,
                    leaseEpoch: key.leaseEpoch,
                    lowestHeld: lowestHeld
                )
            )
        }
    }
}
