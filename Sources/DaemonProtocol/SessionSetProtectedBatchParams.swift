// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionSetProtectedBatchParams: wire shape for `session.setProtectedBatch`.
//
// Atomically flip the protection flag for every session backing one tab.
// A tab holds N terminal panes, each with its own daemon session; a
// per-session toggle applied in a loop can tear (session 1 flips,
// session 2 fails) and leave the daemon holding a mixed protected/unprotected
// set the GUI's single tab boolean can't represent. This batch is
// all-or-none: the daemon validates every id first, then mutates the
// whole set in one actor turn, so a partial application is impossible
// on the wire.
//
// No `(sessionId, cap)` handshake: the method is `.validatedGUI`-scoped,
// so the caller's audit token (validated against the daemon's own
// signature) is the authority. The GUI is the only legitimate caller
// (it alone resolves a tab to its session set), and the owner check is
// applied GUI-side before the batch is built. Threading a cap per
// session would also be wrong: the GUI's single shared connection
// authenticates as whichever tab it opened last and could not replay
// every tab's cap.
//
// `isProtected` is the *desired absolute state*, not a toggle, so a retry
// re-applying the same batch is a no-op: the property the GUI's
// retry-until-ack recovery depends on.
//
// `revision` is the client half of the ordering key. Per-connection the
// daemon pairs it with a server-derived epoch (the monotonic XPC
// connection id) into `(epoch, revision)`; a batch applies only when its
// key strictly dominates every target session's last-applied key,
// otherwise the daemon returns `applied: false` without mutating. The
// GUI allocates a fresh, monotonically increasing `revision` for every
// actual send attempt (including retries and membership-expanded
// re-sends); a superseded send never allocates another. This is what
// makes last-write-wins authoritative daemon-side without the GUI having
// to serialize sends: an older write arriving late (even across an XPC
// reconnect) loses to the newer one's higher key. The epoch defeats a
// GUI restart replaying low revision numbers: a fresh connection's
// higher epoch dominates any prior connection's revisions.

public struct SessionSetProtectedBatchParams: Codable, Sendable, Equatable {
    public let sessionIds: [String]
    public let isProtected: Bool
    public let revision: Int

    public init(sessionIds: [String], isProtected: Bool, revision: Int) {
        self.sessionIds = sessionIds
        self.isProtected = isProtected
        self.revision = revision
    }
}
