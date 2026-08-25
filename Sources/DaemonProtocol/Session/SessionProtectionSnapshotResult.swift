// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionProtectionSnapshotResult: authoritative reply to
// `session.protectionSnapshot`.
//
// `fenced` is true only when the request's `(epoch, revision)` key
// strictly dominates every live requested session's current key. The
// daemon then advances them all to this key, making the snapshot
// authoritative: no older write can still change those sessions. A
// `fenced: false` result means a newer authority already exists on some
// session, so the reported states may be about to change. The GUI must
// treat it as unresolved.
//
// `sessions` reports every requested id explicitly, including `.missing`
// for one that names no live session, so the GUI can detect a membership
// change (a since-closed terminal) rather than silently dropping it.
//
// The GUI exposes a tab only from a `fenced`, uniform-`unprotected`
// snapshot (or the current highest-key unprotect acknowledgement);
// anything mixed, missing, or unfenced is hidden-and-unresolved.

public struct SessionProtectionSnapshotResult: Codable, Sendable, Equatable {
    public let fenced: Bool
    /// Echo of the request's `revision`, for correlating the reply.
    public let revision: Int
    public let sessions: [SessionProtectionEntry]

    public init(fenced: Bool, revision: Int, sessions: [SessionProtectionEntry]) {
        self.fenced = fenced
        self.revision = revision
        self.sessions = sessions
    }
}
