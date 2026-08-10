// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionPrivacySnapshotParams: wire shape for `session.privacySnapshot`.
//
// An *ordering-fenced* authoritative read of tab privacy. A plain read
// would race an older in-flight write: the write could land right after
// the snapshot is taken, so the "authoritative" answer would already be
// obsolete when it reached the GUI. Passing a `revision` lets the daemon
// fence: in the same actor turn it snapshots every requested session AND
// advances each live session's `(epoch, revision)` ordering key to this
// request's key, so any delayed older write subsequently returns
// `applied: false`. The snapshot's answer therefore stays authoritative.
//
// `revision` is a fresh value from the same monotonic counter the GUI
// uses for `session.setPrivateBatch` sends: the daemon pairs it with the
// server-derived connection epoch. `.validatedGUI`-scoped, like
// `setPrivateBatch`, so the audit token is the authority (no cap on the
// wire).

public struct SessionPrivacySnapshotParams: Codable, Sendable, Equatable {
    public let sessionIds: [String]
    public let revision: Int

    public init(sessionIds: [String], revision: Int) {
        self.sessionIds = sessionIds
        self.revision = revision
    }
}
