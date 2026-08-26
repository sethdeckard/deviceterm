// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// One terminal pane inside a tab. Each terminal
/// pane backs its own daemon session (its own `sessionId` + cap), its
/// own libghostty PTY child, and its own `SessionEnvironment` scratch
/// dir. A tab always holds at least one terminal pane (the primary);
/// additional terminals are added via `Route.openTerminalPane`.
///
/// The tab still carries the `role` (agent / automation) because role
/// is a tab-wide property: "Open Automation Tab" mints an
/// automation tab, and every terminal within shares that role. Role is
/// descriptive metadata, not authority (cross-tab verbs are gated by a
/// live automation grant); each terminal's session inherits the tab's
/// role at create-time.
struct TerminalPaneState: Identifiable, Equatable, Sendable {
    let id: TerminalPaneID
    /// Daemon-issued session UUID for this terminal's shell.
    let sessionId: String
    /// Daemon-issued capability token for this terminal's session.
    /// Held in memory only; never persisted to disk. The GUI uses it
    /// to authenticate `session.close` on graceful shell exit (the
    /// `terminalSurface(_:didExitWithCode:)` path) and on tab close.
    let capability: String
    /// Daemon-minted Crockford base32 short_id (6 chars). Optional in
    /// the GUI model: nil when decoded from a pre-identifier-model
    /// daemon response.
    let shortId: String?
    /// Optional session name, as supplied at `session.create` and
    /// echoed back. Nil when none was supplied, and never rewritten
    /// afterward: a manual tab title lives in `TabTitleViewModel`.
    let name: String?
    /// Startup-only working directory for the shell. Threaded through
    /// from `deviceterm tab open --cwd <path>` / `pane open --terminal
    /// --cwd <path>`. Consumed once at `TerminalPaneViewController`
    /// attach time and ignored by the reconcile loop, since the field
    /// describes how to spawn the shell, not durable state.
    let cwd: String?
    /// Startup-only command line typed into the shell after attach
    /// (libghostty's `initial_input`). Threaded through from `--cmd
    /// '<cmd>'`. Same lifecycle as `cwd`: consumed at attach, not
    /// re-read on reconcile. Array on the wire so a programmatic
    /// caller can send argv-style; the CLI sends a single string in
    /// a length-1 array.
    let command: [String]?

    init(
        id: TerminalPaneID,
        sessionId: String,
        capability: String,
        shortId: String? = nil,
        name: String? = nil,
        cwd: String? = nil,
        command: [String]? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.capability = capability
        self.shortId = shortId
        self.name = name
        self.cwd = cwd
        self.command = command
    }
}
