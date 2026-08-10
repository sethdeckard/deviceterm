// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionPrivacySnapshotResult: authoritative reply to
// `session.privacySnapshot`.
//
// `fenced` is the load-bearing field. It is true iff the request's
// `(epoch, revision)` key strictly dominated every live requested
// session's current ordering key, so the daemon was able to advance them
// all to this key. Only a `fenced: true` snapshot is authoritative: it
// guarantees no older write can still change these sessions (they would
// now lose the `(epoch, revision)` race). A `fenced: false` result means
// a newer authority already exists on some session, so the reported
// states may be about to change. The GUI must treat it as unresolved.
//
// `sessions` reports every requested id explicitly, including `.missing`
// for one that names no live session, so the GUI can detect a membership
// change (a since-closed terminal) rather than silently dropping it.
//
// The GUI exposes a tab only from a `fenced`, uniform-`public` snapshot
// (or the current highest-key public write acknowledgement); anything
// mixed, missing, or unfenced is hidden-and-unresolved.

public struct SessionPrivacySnapshotResult: Codable, Sendable, Equatable {
    public let fenced: Bool
    /// Echo of the request's `revision`, for correlating the reply.
    public let revision: Int
    public let sessions: [SessionPrivacyEntry]

    public init(fenced: Bool, revision: Int, sessions: [SessionPrivacyEntry]) {
        self.fenced = fenced
        self.revision = revision
        self.sessions = sessions
    }
}

/// One session's snapshotted privacy. `.missing` names a requested id
/// that has no live session (a since-closed terminal), an explicit
/// entry so the GUI sees the membership change instead of a silent drop.
public struct SessionPrivacyEntry: Codable, Sendable, Equatable {
    public let sessionId: String
    public let state: SessionPrivacyMembership

    public init(sessionId: String, state: SessionPrivacyMembership) {
        self.sessionId = sessionId
        self.state = state
    }
}

public enum SessionPrivacyMembership: String, Codable, Sendable, Equatable {
    case publicState = "public"
    case privateState = "private"
    case missing
}
