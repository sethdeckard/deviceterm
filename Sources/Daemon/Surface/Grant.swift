// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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
