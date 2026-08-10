// SPDX-License-Identifier: GPL-3.0-or-later
//
// TerminalAnchorStore. In-memory registry of session→terminal bindings.
//
// Actor-isolated: mutated by the validated-GUI `session.bindTerminal` handler
// and by lifecycle events (session close via `SessionManager`, GUI disconnect
// via `XPCConnection.close`), and read by the session-provenance check
// (`ProvenanceMatcher`'s terminal arm). This is the backing store for the
// "bound terminal" provenance arm: the thing that lets a non-owner in-tab UDS
// caller authenticate as a session while an out-of-tab cap thief cannot.
// Nothing here is persisted; a daemon restart starts empty (the GUI re-binds
// on reconnect). ONE instance is shared across the bind handler, the
// provenance lookup, and the close-path revocation. See `ProvenanceContext`.
//
// Bindings are immutable for a live session. Re-binding the identical anchor is
// idempotent (the GUI may re-issue after a reconnect); binding a DIFFERENT
// terminal to a session that already has one is a conflict: a live terminal
// can't be silently repointed. An identical re-bind transfers the anchor's
// issuing connection ONLY to a strictly newer (higher-id) binder, so a delayed
// teardown of the prior issuer can't remove an anchor the current connection
// just confirmed, and an older issuer resuming late can't reclaim ownership
// from a newer one. The session's removal (`revokeForRemovedSession`) frees the
// id to be bound again, e.g. after a restart restores the session
// anchor-less.
//
// Removal and binding are linearized by live-session membership, mirroring the
// grant store: a session is registered live at create/restore and removed at
// close, and a bind requires its target to be a live member. Because
// registration, removal, and binding all serialize on this actor, a bind that
// runs after removal is rejected and one that ran before is cleared by the
// removal, with no timing assumption.

import Foundation

/// Outcome of a `bind`. The handler maps `.applied` to success and the other
/// cases to distinct errors.
public enum TerminalBindOutcome: Sendable, Equatable {
    /// Bound: a fresh binding, or an idempotent re-bind of the identical
    /// anchor.
    case applied
    /// The live session already has a DIFFERENT terminal anchor. Immutable:
    /// rejected; freeing requires the session to be removed first.
    case conflict
    /// The issuing GUI connection has been retired (closed). Rejected so a
    /// bind that suspended before the close can't resurrect an anchor.
    case issuerRetired
    /// The target session is not a live member (never registered, or removed
    /// while the bind was in flight). Rejected so a delayed bind can't
    /// recreate an anchor for a dead session.
    case sessionNotLive
}

public actor TerminalAnchorStore {
    private var anchors: [UUID: TerminalAnchor] = [:]
    /// Retirement of the validated-GUI connections that issued anchors,
    /// checked synchronously in `bind` so the check and the mutation are one
    /// atomic actor turn. Same reusable component as the grant store.
    private var issuerLifecycle = IssuerLifecycle()
    /// The live sessions the daemon currently holds: the bind liveness gate.
    /// Mirrors `SessionManager.sessions`, driven by `registerSession`
    /// (create/restore) and `revokeForRemovedSession` (close). A bind target
    /// must be in this set; removal drops it, so a late in-flight bind for a
    /// removed session is rejected however long it was delayed.
    private var liveSessions: Set<UUID> = []

    /// Live anchor count. Diagnostic.
    var count: Int { anchors.count }

    public init() {}

    /// Register a newly-created (or restored) session as live, so its
    /// terminal may be bound. Idempotent. A restored session is registered
    /// live but carries no anchor until the live GUI re-binds it.
    func registerSession(_ sessionId: UUID) {
        liveSessions.insert(sessionId)
    }

    /// Bind `facts` to `sessionId`, attributed to the issuing GUI connection.
    /// All-or-none, atomic on this actor:
    ///   - `.issuerRetired` if the issuing connection has closed;
    ///   - `.sessionNotLive` if the target isn't a live registered session;
    ///   - `.conflict` if a DIFFERENT anchor is already bound (immutable);
    ///   - `.applied` for a fresh bind or an idempotent re-bind of the
    ///     identical anchor; a fresh bind and a re-bind from a strictly newer
    ///     connection take ownership, while an older re-bind succeeds but
    ///     leaves the existing (newer) owner intact.
    @discardableResult
    func bind(
        sessionId: UUID,
        facts: TerminalAnchorFacts,
        issuedBy connectionId: UInt64
    ) -> TerminalBindOutcome {
        guard !issuerLifecycle.isRetired(connectionId) else { return .issuerRetired }
        guard liveSessions.contains(sessionId) else { return .sessionNotLive }
        if let existing = anchors[sessionId] {
            guard existing.facts == facts else { return .conflict }
            // Identical re-bind. Transfer ownership ONLY to a strictly newer
            // (higher-id) connection, so a delayed teardown of the prior
            // issuer can't remove an anchor the current connection just
            // confirmed. An OLDER issuer (a suspended request resuming after
            // a newer connection already rebound) succeeds idempotently but
            // must not reclaim ownership, or its later close would remove the
            // newer connection's anchor. Connection ids are monotonic, so
            // higher means newer.
            if connectionId > existing.issuingGUIConnectionId {
                anchors[sessionId] = TerminalAnchor(
                    sessionId: sessionId,
                    facts: facts,
                    issuingGUIConnectionId: connectionId
                )
            }
            return .applied
        }
        anchors[sessionId] = TerminalAnchor(
            sessionId: sessionId,
            facts: facts,
            issuingGUIConnectionId: connectionId
        )
        return .applied
    }

    /// The anchor bound to `sessionId`, or nil when none has been established
    /// (never bound, or lost to a close/disconnect/restart). The provenance
    /// matcher treats nil as "not yet ready" only for a non-owner UDS peer on
    /// a live session; owner and validated-GUI callers authorize by an earlier
    /// arm regardless.
    public func anchor(for sessionId: UUID) -> TerminalAnchor? {
        anchors[sessionId]
    }

    /// Remove a session because it was closed. Drops it from the live set (so
    /// a bind, in flight or later, for it is rejected, however long delayed)
    /// and drops its anchor. Leaves no residue.
    func revokeForRemovedSession(_ sessionId: UUID) {
        liveSessions.remove(sessionId)
        anchors.removeValue(forKey: sessionId)
    }

    /// Retire `connectionId` and drop every anchor it issued: the issuing GUI
    /// disappeared. Retiring rejects any later in-flight bind from it; the
    /// removal drops anchors already present. For the authoritative
    /// connection-close path (alongside the grant store), wired with the
    /// enforcement.
    func revokeAll(issuedBy connectionId: UInt64) {
        issuerLifecycle.retire(connectionId)
        for (id, anchor) in anchors where anchor.issuingGUIConnectionId == connectionId {
            anchors.removeValue(forKey: id)
        }
    }
}
