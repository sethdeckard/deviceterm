// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Why a `restoreBatch` was rejected in full. Every case leaves the manager
/// unmutated (validation runs before any insert). Mapped to `invalidParams`
/// at the RPC boundary; the offending id/short id is for daemon-side
/// diagnostics only and is never echoed with the supplied capability.
public enum RestoreBatchError: Error, Equatable, Sendable {
    /// The same session id appears twice in the batch.
    case duplicateSessionId(UUID)
    /// The same short id appears twice in the batch.
    case duplicateShortId(String)
    /// A short id is not well-formed (wrong length / alphabet).
    case malformedShortId(String)
    /// The id names a live session, but the supplied capability derives a
    /// different verifier: a stale cap must not rebind a live session.
    case verifierConflict(UUID)
    /// The id names a live session with a matching verifier but disagreeing
    /// immutable metadata (short id / role); restore never rewrites it.
    case metadataConflict(UUID)
    /// A new session's short id collides with a different live session's.
    case shortIdCollision(String)
    /// The batch's epoch is strictly older than the last applied restore. This
    /// is a late batch from an older connection and mutates nothing.
    case staleBatch(epoch: UInt64)
}
