// SPDX-License-Identifier: GPL-3.0-or-later
//
// InventorySyncCoordinator: the SINGLE caller of `session.restoreBatch`.
//
// `restoreBatch` is both restart restoration (after a daemon-only respawn) and
// ongoing authoritative inventory reconciliation: the daemon reclaims a
// closed-session tombstone only when an accepted, non-stale inventory OMITS it,
// so the GUI must re-supply its live inventory whenever the workspace changes,
// not only on reconnect, otherwise close tombstones accumulate until the next
// reconnect, an unbounded same-uid memory path.
//
// The coordinator serializes all of that behind a dirty flag with BOUNDED
// COALESCING (not a perpetually-reset trailing debounce):
//   - a completed workspace mutation (session create/close) marks the inventory
//     dirty (`markDirty`);
//   - at most one batch is ever in flight;
//   - each pass waits a short FIXED coalescing window, snapshots the live
//     inventory, sends it, and advances the synced watermark ONLY on a verified
//     echo, so continuous churn still flushes every window and can't postpone
//     synchronization indefinitely;
//   - a mutation during an in-flight batch re-dirties, forcing another batch;
//   - a failed or unverified delivery leaves the state dirty and retries with
//     capped backoff;
//   - a reconnect (`reconnected(generation:)`) re-supplies too, and fires the
//     terminal-rebind observers once per generation on its first verified sync;
//     a steady-state sync fires NO reconnect observers, terminal rebinding, or
//     pane recovery.
//
// The daemon's `(epoch, revision)` fence rejects an older connection's batch
// after a reconnect, so a superseded generation can neither reclaim nor
// resurrect state; the coordinator additionally never fires reconnect observers
// for a superseded generation.

import DaemonProtocol
import Foundation
import os

/// Restore-batch traffic, for correlating GUI syncs with daemon session events.
///
/// An accepted, non-stale authoritative batch can reap a session it omits, when
/// its ordering key dominates that session's last assertion. The reap revokes
/// that session's pane subscriptions while a spared `.guiPeer` subscriber keeps
/// the pane rendering. Attaching a device does not schedule a sync, since the
/// dirty check diffs terminal session ids, so a batch here came from startup, a
/// reconnect, or a terminal opening or closing.
private let syncLog = Logger(subsystem: "com.deviceterm", category: "inventory-sync")

@MainActor
final class InventorySyncCoordinator {
    /// Injected seams so the loop is testable without a live workspace/daemon.
    struct Dependencies {
        /// Build the current authoritative inventory from the live workspace, or
        /// nil on a daemon-contract violation (a live terminal missing its short
        /// id), which cannot be resent through.
        var buildInventory: @MainActor () -> [RestoredSession]?
        /// Send one batch; returns the echoed session ids, or nil on
        /// transport/daemon failure. The lone `restoreBatch` call site.
        var sendBatch: @MainActor ([RestoredSession]) async -> [String]?
        /// The daemon connection's current reconnect generation.
        var generation: @MainActor () -> Int
        /// Fire terminal-rebind observers etc.: reconnect only, once per
        /// generation, after its first verified sync. Receives the synced set.
        var onReconnectSynced: @MainActor ([RestoredSession]) async -> Void
        /// Surface the unresolvable-inventory contract violation (once).
        var reportContractViolation: @MainActor () -> Void
        /// Cancellation-aware sleep; returns false if cancelled (loop exits).
        var sleep: @Sendable (UInt64) async -> Bool
        /// Fixed coalescing window before each snapshot (ns). A short window
        /// coalesces a burst of mutations into one batch; being FIXED (not
        /// reset on each change) means continuous churn still flushes each
        /// window rather than being postponed forever.
        var coalesceWindowNanos: UInt64 = 50_000_000
        /// Backoff ceiling for retries (ns).
        var maxBackoffNanos: UInt64 = 5_000_000_000
        /// Initial backoff (ns).
        var baseBackoffNanos: UInt64 = 100_000_000
    }

    private let deps: Dependencies
    /// Monotonic count of workspace mutations observed. A batch that verifiably
    /// synchronizes the snapshot taken at version V advances `synced` to V.
    private var dirty = 0
    private var synced = 0
    /// Whether the run loop is active (enforces one batch in flight).
    private var running = false
    /// The reconnect generation awaiting its one-time observer fire, or nil.
    private var pendingReconnectFire: Int?

    /// Whether a sync is pending (dirty beyond the synced watermark) OR running.
    /// Test/diagnostic accessor.
    var isSettled: Bool { !running && synced >= dirty }

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// A completed workspace mutation: mark dirty and ensure the loop runs.
    func markDirty() {
        dirty += 1
        start()
    }

    /// A reconnect established a new connection: re-supply the inventory and, on
    /// the first verified sync at `generation`, fire the reconnect observers.
    func reconnected(generation: Int) {
        pendingReconnectFire = generation
        dirty += 1
        start()
    }

    private func start() {
        guard !running else { return }
        running = true
        Task { await self.run() }
    }

    private func run() async {
        defer { running = false }
        var backoff = deps.baseBackoffNanos
        while synced < dirty {
            // Bounded coalescing: a short FIXED window folds a burst of mutations
            // into one batch without postponing indefinitely.
            if !(await deps.sleep(deps.coalesceWindowNanos)) { return }
            let target = dirty
            // Tag this send with the generation it is ISSUED at. Its verified
            // reply may only fire that generation's reconnect notification. A
            // reconnect during the send bumps the generation, so a stale reply
            // can neither satisfy nor consume the newer generation's fire.
            let sendGeneration = deps.generation()
            guard let inventory = deps.buildInventory() else {
                // Unresolvable inventory: surface once, keep dirty, retry.
                deps.reportContractViolation()
                if !(await deps.sleep(backoff)) { return }
                backoff = min(backoff * 2, deps.maxBackoffNanos)
                continue
            }
            let expected = Set(inventory.map(\.sessionId))
            syncLog.info(
                """
                restoreBatch sending generation=\(sendGeneration, privacy: .public) \
                sessions=\(inventory.count, privacy: .public)
                """
            )
            let echoed = await deps.sendBatch(inventory)
            let verified = echoed.map { Set($0) == expected } ?? false
            syncLog.info(
                """
                restoreBatch generation=\(sendGeneration, privacy: .public) \
                verified=\(verified, privacy: .public)
                """
            )
            if verified {
                // Verified: advance the synced watermark to the snapshot version.
                // A mutation during the send bumped `dirty` past `target`, so the
                // loop sends another batch. Continuous churn flushes each window.
                synced = max(synced, target)
                // Fire reconnect observers once, only for THIS send's generation
                // and only if it is still current: an older connection's sync,
                // or a stale reply after a newer reconnect, never rebinds.
                if pendingReconnectFire == sendGeneration, deps.generation() == sendGeneration {
                    pendingReconnectFire = nil
                    await deps.onReconnectSynced(inventory)
                }
                backoff = deps.baseBackoffNanos
            } else {
                // Failure/unverified: leave dirty, retry with capped backoff.
                if !(await deps.sleep(backoff)) { return }
                backoff = min(backoff * 2, deps.maxBackoffNanos)
            }
        }
    }
}
