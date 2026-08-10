// SPDX-License-Identifier: GPL-3.0-or-later
//
// PublishedSurface: the single wrapper a backend publishes for one
// frame, carried through `PaneCoordinator` and `PaneSubscriptionRegistry`.
//
// It explicitly retains its `LeasedSurface` (the daemon-current owner):
// `Record.currentSurface` holds a `PublishedSurface`, so assigning a newer
// one drops the prior `owned` by ARC and releases its `.daemonCurrent`
// hold. A device frame carries `lease` metadata (epoch + generation +
// the hold-reservation entry point); a simulator frame sets `lease` to nil
// and an `owned` whose release sink is nil, the simulator live-alias path.

import Foundation

struct PublishedSurface: Sendable {
    /// Retains the slot's `LeasedSurface`; its `deinit` releases the
    /// `.daemonCurrent` hold. Never dropped before this value is.
    let owned: LeasedSurface
    /// Device-only lease overlay. Nil for a simulator frame.
    let lease: LeaseMetadata?
    /// Off-by-default instrumentation stamp assigned at the producer copy
    /// site; nil unless surface tracing is enabled.
    var trace: SurfaceTraceStamp?

    var surface: RetainedSurface { owned.surface }

    init(owned: LeasedSurface, lease: LeaseMetadata? = nil, trace: SurfaceTraceStamp? = nil) {
        self.owned = owned
        self.lease = lease
        self.trace = trace
    }
}

/// Device-only per-frame lease identity. `acquireHold` reserves a
/// subscription hold for a token on this exact `(epoch, generation)`.
struct LeaseMetadata: Sendable {
    let epoch: UInt64
    let generation: UInt64
    /// Reserve a provisional subscription hold for `token` on this frame.
    /// Returns nil when the token is not `active`/unknown, the generation
    /// is `≤ highestReserved`, or it is `< acceptedLowestHeld` (below the
    /// acked frontier). Release is NOT per-frame metadata: a
    /// `pane.surfaceRelease` watermark routes through its own connection-
    /// checked handler.
    let acquireHold: @Sendable (_ token: UUID) async -> Grant?
}

/// A reservation handle from `LeaseMetadata.acquireHold`. The provisional
/// hold exists in the pool immediately; the delivery path drives it to
/// exactly one terminal:
///
///   - `commit()` before the send promotes it to committed and returns
///     `false` if the token went non-`active` in the gap (then `cancel()`);
///     a committed hold survives this value going out of scope; only a
///     watermark ack or orphaning removes it.
///   - `cancel()` (any pre-commit failure) removes the provisional hold.
///   - `revoke()` (a committed-but-unexposed hold, e.g. a post-commit
///     revalidation failure) removes the committed hold before it is sent.
///
/// All three are `async` (an actor hop) and idempotent.
struct Grant: Sendable {
    let epoch: UInt64
    let generation: UInt64
    let token: UUID
    private let pool: LeasedSurfacePool

    init(epoch: UInt64, generation: UInt64, token: UUID, pool: LeasedSurfacePool) {
        self.epoch = epoch
        self.generation = generation
        self.token = token
        self.pool = pool
    }

    /// Promote the provisional hold to committed. Returns false if the
    /// token is no longer `active` (the caller then cancels).
    @discardableResult
    func commit() async -> Bool {
        await pool.commitGrant(epoch: epoch, generation: generation, token: token)
    }

    func cancel() async {
        await pool.cancelGrant(epoch: epoch, generation: generation, token: token)
    }

    func revoke() async {
        await pool.revokeGrant(epoch: epoch, generation: generation, token: token)
    }
}
