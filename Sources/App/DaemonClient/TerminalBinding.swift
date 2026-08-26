// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Role protocol: bind a session to its terminal's kernel identity.
///
/// One of the narrow role protocols carved out of `DaemonClient` so a consumer
/// (and its test fake) depends only on the surface it uses. The terminal-pane
/// container reads a spawned shell's foreground pid + tty from libghostty and
/// calls this so the daemon can derive and store the session's terminal anchor:
/// the provenance "terminal" arm that lets an in-tab CLI process authenticate
/// as the pane's session while an out-of-tab cap thief cannot.
///
/// `@MainActor`/`AnyObject` because the whole GUI daemon path is main-actor and
/// reference-typed.
@MainActor
protocol TerminalBinding: AnyObject {
    /// `session.bindTerminal`: `.validatedGUI`-scoped, so no cap rides on the
    /// wire (the GUI's audit token is the authority). Idempotent: re-binding
    /// the same terminal is a daemon-side no-op, so a reconnect/restart replay
    /// is safe. `foregroundPid`/`ttyName` come from
    /// `TerminalSurface.terminalIdentity()`.
    func bindTerminal(
        sessionId: String,
        foregroundPid: Int32,
        ttyName: String
    ) async throws
}
