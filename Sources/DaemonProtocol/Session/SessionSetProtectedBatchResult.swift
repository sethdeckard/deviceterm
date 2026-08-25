// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionSetProtectedBatchResult: authoritative reply to
// `session.setProtectedBatch`.
//
// The daemon is the ordering authority for tab protection. It never
// acknowledges a stale write as ordinary success: a batch whose
// `(epoch, revision)` key does not strictly dominate every target
// session's last-applied key returns `applied: false` *without
// mutating*. Only `applied: true` means "the daemon committed this
// exact `isProtected` for these sessions."
//
// The GUI commits its presentation state **only** from an `applied: true`
// response (and only when the echoed `revision` advances past the last
// it committed. A late lower-revision ack that already lost to a newer
// write is ignored). It must never restore a request-time snapshot: on a
// definite rejection or an `applied: false`, the GUI stays fail-closed
// and reconciles from a subsequent authoritative response, rather than
// guessing the daemon's state.
//
// `revision` echoes the request's revision so the GUI can match the
// reply to the send that produced it; `isProtected` echoes the applied
// (or, when stale, the requested) absolute state.

public struct SessionSetProtectedBatchResult: Codable, Sendable, Equatable {
    /// True iff the daemon actually mutated the target sessions to
    /// `isProtected`. False means the batch was stale (a higher-key write
    /// already won) and nothing changed.
    public let applied: Bool
    /// Echo of the request's `revision`, so the GUI can correlate the
    /// reply with its originating send.
    public let revision: Int
    /// The absolute protection state carried by the request. On `applied:
    /// true` this is what the daemon committed; on `applied: false` it is
    /// the (losing) requested value and the GUI must not commit from it.
    public let isProtected: Bool

    public init(applied: Bool, revision: Int, isProtected: Bool) {
        self.applied = applied
        self.revision = revision
        self.isProtected = isProtected
    }
}
