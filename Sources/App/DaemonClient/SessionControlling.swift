// SPDX-License-Identifier: GPL-3.0-or-later
//
// Role protocol: session lifecycle on the daemon.
//
// One of four narrow role protocols carved out of `DaemonClient` so
// a consumer (and its test fake) depends only on the surface it
// uses. `DaemonClient` is the sole concrete conformer; consumers
// take an injected `any SessionControlling` (or a composition with
// other roles). `@MainActor`/`AnyObject` because the whole GUI
// daemon path is main-actor and reference-typed.

import DaemonProtocol

@MainActor
protocol SessionControlling: AnyObject {
    /// `session.create`: mint a daemon session, returning its id +
    /// cap. `name` is optional; the GUI uses it to carry a worktree-
    /// derived branch name so a tab opened in a worktree auto-labels.
    /// `role` is the session's role (descriptive metadata, not an authority
    /// gate: cross-tab verbs are gated by a live automation grant);
    /// standard tab-open call sites pass `.agent`. The GUI's "Open Automation Tab" menu is the
    /// product-UI path that passes `.automation`; no CLI verb emits
    /// the request, and the daemon refuses an automation mint
    /// that doesn't arrive over XPC from a signature-validated peer.
    /// `initialProtected` seeds the session's protection flag atomically at
    /// create time: passed `true` for a terminal joining a tab that is
    /// already protected (or mid-transition to protected) so the new
    /// session is never observable as unprotected on `tabs.list`. The standard
    /// tab-open path passes `false`.
    func createSession(
        label: String?,
        name: String?,
        role: SessionRole,
        initialProtected: Bool
    ) async throws -> SessionCreateResponse
    /// `session.close`: `mode` is `.detach` (sims keep running) or
    /// `.shutdown`. The witness may default `mode`; the requirement
    /// doesn't (protocol requirements can't carry default arguments).
    func closeSession(
        sessionId: String,
        capability: String,
        mode: PaneCloseMode
    ) async throws
    /// `session.setProtectedBatch`: atomically flip the protection flag for
    /// every session backing one tab, subject to daemon-side ordering.
    /// `.validatedGUI`-scoped, so no cap rides on the wire (the GUI's
    /// audit token is the authority). The daemon validates every id and
    /// checks the `(epoch, revision)` key before mutating, so a
    /// multi-terminal tab can't end up torn and a stale write loses; the
    /// GUI applies the owner check before building the batch. `revision`
    /// is a fresh, monotonically increasing value per send attempt; the
    /// reply's `applied` says whether the daemon actually committed it.
    func setProtectedBatch(
        sessionIds: [String],
        isProtected: Bool,
        revision: Int
    ) async throws -> SessionSetProtectedBatchResult

    /// `session.restoreBatch`: re-supply the daemon's COMPLETE session
    /// inventory after a daemon-only restart, the sole path by which sessions
    /// come back (the daemon rehydrates nothing from disk). `.validatedGUI`-
    /// scoped; each entry carries the existing bearer cap the daemon re-derives
    /// the verifier from. Called once per reconnect, before terminals rebind.
    func restoreBatch(sessions: [RestoredSession]) async throws -> SessionRestoreBatchResult

    /// `session.protectionSnapshot`: ordering-fenced authoritative read of the
    /// sessions' confirmed protection. `.validatedGUI`-scoped. `revision` is a
    /// fresh value from the same monotonic counter as `setProtectedBatch`; the
    /// daemon advances the sessions' ordering key to it so a delayed older
    /// write loses, keeping the returned snapshot authoritative. Only a
    /// `fenced: true` reply is authoritative.
    func protectionSnapshot(
        sessionIds: [String],
        revision: Int
    ) async throws -> SessionProtectionSnapshotResult

    /// `session.setCohort`: reconcile a tab's cohort membership, or commit a
    /// close verdict for members that are leaving (`beginClose`).
    /// `.validatedGUI`-scoped, so no cap rides on the wire. `params.revision`
    /// is a fresh, monotonically increasing value per send attempt; the
    /// daemon pairs it with its own connection epoch, so a stale write
    /// loses and a GUI restart replaying low revisions is harmless. The
    /// reply's `applied` says whether the daemon committed (or, for a
    /// retried `beginClose`, replayed its journalled verdict).
    func setCohort(_ params: SessionSetCohortParams) async throws -> SessionSetCohortResult
}
