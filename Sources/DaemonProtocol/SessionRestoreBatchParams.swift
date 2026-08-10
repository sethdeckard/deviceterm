// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionRestoreBatchParams: wire shape for `session.restoreBatch`.
//
// A fresh daemon instance starts with ZERO sessions: nothing
// authority-bearing is rehydrated from disk (the on-disk manifest is
// untrusted input a same-uid process can rewrite). The one authority for
// a session's existence and metadata is a live, signature-validated GUI,
// which re-supplies its whole live inventory over XPC after a
// daemon-only restart (the daemon idle-exited/crashed while the GUI
// survived). This is a *reconnect* mechanism (GUI → fresh daemon), never
// a cold-start-from-disk one; on a full GUI+daemon cold restart no old
// session is restored.
//
// `sessions` is the COMPLETE live inventory in one call, not incremental
// and not per-tab. Processing it (even an empty array) is the unambiguous
// "the inventory is now complete" signal that releases the daemon's
// restoration barrier: while a fresh daemon is pending restoration, an
// `session.authenticate` for an unknown session returns the retryable
// `notReady` (-32002) rather than the terminal `unauthorized` (-32001),
// so an in-tab CLI/shim keeps its bounded retry instead of pruning a
// still-valid credential; once a batch completes, an unknown session is
// terminally `unauthorized`.
//
// `.validatedGUI`-scoped: the caller's audit token, validated against
// the daemon's own signature, is the authority. UDS can never reach it,
// and the issuing GUI identity comes from the dispatch context, never the
// payload. The restored session's *owner* is likewise captured from the
// validated XPC peer server-side (identical to `session.create`), never
// sent on the wire.

public struct SessionRestoreBatchParams: Codable, Sendable, Equatable {
    /// The complete live session inventory. Entry order is significant.
    /// It defines `tabs.list` ordering for the restored set. An empty
    /// array is valid and still completes the restoration barrier.
    public let sessions: [RestoredSession]
    /// A monotonically increasing revision the GUI allocates per restore SEND
    /// (including each durable retry). Paired server-side with the connection
    /// epoch and a `restore` tier into an `(epoch, tier, revision)` ordering
    /// key, so a same-connection retry that carries a changed inventory strictly
    /// dominates the earlier attempt (letting it authoritatively update a live
    /// session's privacy or reap one an earlier retry asserted). A strictly
    /// older restore key is rejected; an equal key may replay idempotently. The
    /// tier keeps a restore below any live user action at the same epoch.
    public let revision: Int

    public init(sessions: [RestoredSession], revision: Int) {
        self.sessions = sessions
        self.revision = revision
    }
}

/// One session in a restore batch. Carries only state the GUI can
/// authoritatively reconstruct from its own live model; the daemon
/// derives everything else (owner from the XPC peer, verifier from the
/// capability, `createdAt` fresh).
///
/// Deliberately absent:
/// - **owner / ownerPID**: captured server-side from the validated XPC
///   audit token, exactly as `session.create` does; never wire-supplied.
/// - **terminal anchor / grant**: never persisted, never restored here;
///   the GUI re-establishes them AFTER restore (`session.bindTerminal`,
///   then orchestration grants) in a fixed order.
/// - **epoch**: the ordering epoch is the caller's XPC connection id,
///   derived server-side from the dispatch context, never wire-supplied (a
///   client can't forge or rewind it). Paired with `revision` it fences a
///   restore against staleness and orders it against overlapping restores;
///   replay safety rests on that fence plus idempotency, conflict-reject, and
///   the `.validatedGUI` scope.
/// - **label**: the GUI has no authoritative label source (sessions are
///   created with a nil label), so none is invented; the daemon defaults
///   it as `session.create` does with a nil label.
public struct RestoredSession: Codable, Sendable, Equatable {
    /// The UUID string the session is restored under (the id the tab's
    /// env cap was minted against). Must parse as a UUID.
    public let sessionId: String
    /// The EXISTING bearer capability the GUI still holds for this session
    /// (the one already in the tab shell's `DEVICETERM_SESSION_CAP`). The
    /// daemon re-derives the non-recoverable `CapabilityVerifier` from it
    /// via the same domain-separated hash `session.create` uses, so the
    /// in-tab cap keeps authenticating across a daemon restart. Never
    /// logged or interpolated into a diagnostic string.
    public let capability: String
    /// The immutable Crockford-base32 short id the session already had.
    /// Preserved verbatim (never re-derived) so cached `--tab <ref>`
    /// values and scripts keep working across a daemon restart.
    public let shortId: String
    /// The role the session was minted with (`agent` | `orchestrator`).
    public let role: SessionRole
    /// The optional human/agent-set tab name.
    public let name: String?
    /// The desired absolute privacy state, derived fail-closed from the
    /// GUI's effective-hidden presentation (a mid-transition tab restores
    /// private, never briefly public).
    public let isPrivate: Bool

    public init(
        sessionId: String,
        capability: String,
        shortId: String,
        role: SessionRole,
        name: String?,
        isPrivate: Bool
    ) {
        self.sessionId = sessionId
        self.capability = capability
        self.shortId = shortId
        self.role = role
        self.name = name
        self.isPrivate = isPrivate
    }
}

/// Reply to `session.restoreBatch`: the count and ids the daemon now
/// holds live for this inventory, so the GUI can confirm the set it
/// pushed. On success the whole batch committed atomically (all-or-none);
/// a malformed / duplicate / conflicting batch is rejected in full with
/// `invalidParams` and nothing is mutated.
public struct SessionRestoreBatchResult: Codable, Sendable, Equatable {
    public let restoredCount: Int
    public let sessionIds: [String]

    public init(restoredCount: Int, sessionIds: [String]) {
        self.restoredCount = restoredCount
        self.sessionIds = sessionIds
    }
}
