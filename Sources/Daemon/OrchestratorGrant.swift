// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Daemon-internal ordering key for orchestration grants, mirroring
/// `PrivacyOrderingKey`. Lexicographic `(epoch, revision)`: `epoch` is
/// server-derived from the issuing XPC connection id (monotonic, so a
/// reconnected GUI always dominates an older one and a client can't forge
/// or rewind it); `revision` orders successive requests within one
/// connection. A grant or revoke applies only when its key **strictly
/// dominates** the target session's stored key. So a stale grant that runs
/// after a newer revoke (the non-FIFO XPC task hazard) can never resurrect
/// authority.
struct GrantOrderingKey: Comparable, Sendable, Equatable {
    let epoch: UInt64
    let revision: Int

    static func < (lhs: GrantOrderingKey, rhs: GrantOrderingKey) -> Bool {
        if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
        return lhs.revision < rhs.revision
    }
}

/// The result of an `orchestrator.grant` batch.
enum GrantOutcome: Sendable, Equatable {
    /// Applied: every target was a live session and the key dominated.
    case applied
    /// No mutation: a stale (non-dominating) key, or the issuing connection
    /// has closed. The caller reports `applied: false`.
    case notApplied
    /// A target is not a live session (never created, or already removed).
    /// The caller rejects the whole batch with `invalidParams`.
    case sessionNotLive
}

/// Daemon-wide store of orchestration grants. Actor-isolated: mutated only
/// by validated-GUI handlers (`orchestrator.grant` / `orchestrator.revoke`),
/// by connection teardown, and by session removal; read by the orchestrator
/// scope check and capability advertising on every request.
///
/// Nothing here is written to disk. A daemon restart starts empty; grants live
/// only in memory and can be issued only over a validated-XPC connection from a
/// signature-validated GUI peer. Authority can only come from a live,
/// signature-validated GUI, never from a user-writable file.
///
/// **Ordering + tombstones.** Each session keeps its last-applied
/// `GrantOrderingKey` and whether it is currently granted. A revoke keeps the
/// key and flips `granted` false (a tombstone), so a stale grant that runs
/// after the revoke fails the dominance check and cannot resurrect authority.
/// A batch is all-or-none: it applies only if its key dominates *every*
/// target, and returns whether it applied.
///
/// **Closed-issuer tombstones.** When a connection closes, its id is recorded
/// so any grant still in flight from it (a handler that suspended before
/// `close()` ran and resumes after) is rejected rather than creating a lease
/// owned by a dead GUI.
///
/// **Live-session membership.** The store tracks the set of live sessions
/// (registered at `session.create`, removed at `session.close`), and a grant
/// requires every target to be a live session. Because the actor serializes
/// registration/removal against `grant`, this is race-free with no timing
/// assumption: a grant that runs before its target's removal is cleared by the
/// removal; one that runs after is rejected (target no longer live). Memory is
/// proportional to live sessions: a removed session leaves no residue.
public actor OrchestratorGrantStore {
    private struct Entry {
        var key: GrantOrderingKey
        var granted: Bool
        /// Connection that issued the current (granted) lease. Meaningful
        /// only while `granted`; a tombstone's issuer is irrelevant.
        var issuingConnectionId: UInt64
    }

    private var entries: [UUID: Entry] = [:]
    /// Retirement of the validated-GUI connections that issued grants. A grant
    /// attributed to a retired connection is rejected (closes the
    /// disconnect-then-late-grant race). Uses the reusable `IssuerLifecycle`
    /// component, checked synchronously in `grant` so the check and the
    /// mutation are one atomic actor turn. Recorded only for validated-GUI
    /// connections (only they can grant), so unvalidated connect/disconnect
    /// churn can't grow it; reset on restart.
    private var issuerLifecycle = IssuerLifecycle()
    /// The live sessions the daemon currently holds: the grant liveness
    /// gate. Mirrors `SessionManager.sessions`, driven by `registerSession`
    /// (create/restore) and `revokeForRemovedSession` (close). A grant
    /// target must be in this set; a removed session leaves it, so a late
    /// in-flight grant for it is rejected however long it was delayed.
    private var liveSessions: Set<UUID> = []

    /// Count of currently-live grants (tombstones excluded). Diagnostic.
    var count: Int { entries.values.filter(\.granted).count }

    /// Total stored entries including tombstones. Diagnostic: proves the
    /// ledger doesn't grow from spurious revokes of non-live targets.
    var entryCount: Int { entries.count }

    public init() {}

    /// Register a newly-created (or restored) session as live, so a grant
    /// may target it. Idempotent.
    func registerSession(_ sessionId: UUID) {
        liveSessions.insert(sessionId)
    }

    /// Issue grants for `sessionIds` at ordering `key`, attributed to the
    /// issuing GUI connection. All-or-none:
    ///   - `.notApplied` if the issuing connection has closed, or the key
    ///     doesn't strictly dominate the stored key of every target;
    ///   - `.sessionNotLive` if any target isn't a live session;
    ///   - `.applied` otherwise (every target granted).
    @discardableResult
    func grant(sessionIds: [UUID], key: GrantOrderingKey, issuedBy connectionId: UInt64) -> GrantOutcome {
        guard !issuerLifecycle.isRetired(connectionId) else { return .notApplied }
        guard sessionIds.allSatisfy({ liveSessions.contains($0) }) else { return .sessionNotLive }
        guard sessionIds.allSatisfy({ dominates(key, over: entries[$0]?.key) }) else { return .notApplied }
        for id in sessionIds {
            entries[id] = Entry(key: key, granted: true, issuingConnectionId: connectionId)
        }
        return .applied
    }

    /// Revoke grants for `sessionIds` at ordering `key`, leaving a tombstone
    /// on each live target (the key is preserved, `granted` flips false) so a
    /// later stale grant can't resurrect it. All-or-none by the same dominance
    /// rule; returns whether it applied.
    ///
    /// **Non-live targets store nothing.** A session removed via
    /// `revokeForRemovedSession` already had its entry dropped, and an
    /// arbitrary/never-live UUID has no grant to clear: both are already
    /// revoked. Tombstoning them would recreate a permanent entry that no
    /// later removal ever cleans up (unbounded ledger growth), so they are
    /// filtered out. The tombstone is only needed to block a racing stale
    /// grant, and a stale grant for a non-live target already fails the
    /// liveness gate in `grant`, so no tombstone is required to fence it.
    @discardableResult
    func revoke(sessionIds: [UUID], key: GrantOrderingKey) -> Bool {
        let liveTargets = sessionIds.filter { liveSessions.contains($0) }
        guard liveTargets.allSatisfy({ dominates(key, over: entries[$0]?.key) }) else { return false }
        for id in liveTargets {
            entries[id] = Entry(
                key: key,
                granted: false,
                issuingConnectionId: entries[id]?.issuingConnectionId ?? 0
            )
        }
        return true
    }

    /// Mark `connectionId` closed and revoke every live grant it issued: the
    /// issuing GUI disappeared. Recording the closed issuer rejects any late
    /// in-flight grant from it; the revoke tombstones grants already present.
    /// Only grants still *owned* by that connection are tombstoned; a grant
    /// reissued by a newer connection (which took ownership) survives.
    func revokeAll(issuedBy connectionId: UInt64) {
        issuerLifecycle.retire(connectionId)
        for (id, entry) in entries where entry.granted && entry.issuingConnectionId == connectionId {
            entries[id] = Entry(
                key: GrantOrderingKey(epoch: connectionId, revision: .max),
                granted: false,
                issuingConnectionId: connectionId
            )
        }
    }

    /// Remove a session because it was closed. Drops it from the live set (so
    /// a grant, in flight or future, for it is rejected, however long
    /// delayed) and drops its grant entry (so `hasGrant` is immediately false:
    /// the same authenticated socket is refused after close). Leaves no
    /// residue.
    func revokeForRemovedSession(_ sessionId: UUID) {
        liveSessions.remove(sessionId)
        entries.removeValue(forKey: sessionId)
    }

    /// Whether `sessionId` currently holds a live grant. The orchestrator
    /// scope check and capability advertising call this on every request.
    func hasGrant(_ sessionId: UUID) -> Bool {
        entries[sessionId]?.granted ?? false
    }

    /// A key strictly dominates when there is no prior key, or it is greater.
    private func dominates(_ key: GrantOrderingKey, over existing: GrantOrderingKey?) -> Bool {
        guard let existing else { return true }
        return key > existing
    }
}
