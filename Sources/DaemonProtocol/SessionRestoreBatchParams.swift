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
    /// session's protection or reap one an earlier retry asserted). A strictly
    /// older restore key is rejected; an equal key may replay idempotently. The
    /// tier keeps a restore below any live user action at the same epoch.
    public let revision: Int

    public init(sessions: [RestoredSession], revision: Int) {
        self.sessions = sessions
        self.revision = revision
    }
}
