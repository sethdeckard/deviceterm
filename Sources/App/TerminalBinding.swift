// SPDX-License-Identifier: GPL-3.0-or-later
//
// Role protocol: bind a session to its terminal's kernel identity.
//
// One of the narrow role protocols carved out of `DaemonClient` so a consumer
// (and its test fake) depends only on the surface it uses. The terminal-pane
// container reads a spawned shell's foreground pid + tty from libghostty and
// calls this so the daemon can derive and store the session's terminal anchor:
// the provenance "terminal" arm that lets an in-tab CLI process authenticate
// as the pane's session while an out-of-tab cap thief cannot.
//
// `@MainActor`/`AnyObject` because the whole GUI daemon path is main-actor and
// reference-typed.

import Foundation

/// Opaque handle for a registered reconnect observer, so a closing tab can
/// remove its observer and the client's registry doesn't grow unboundedly.
struct ReconnectObserverToken: Hashable, Sendable {
    let id: UUID
}

/// Role protocol: observe connection re-establishment.
///
/// After a reconnect (daemon respawn or XPC interruption), the daemon's
/// in-memory terminal-anchor store is gone or the prior connection's anchors
/// were revoked. The terminal-pane container registers here so it can re-bind
/// every live terminal once the connection is back. Idempotent binds make a
/// duplicate notification harmless. The returned token MUST be removed on tab
/// teardown; otherwise the registry accumulates dead closures across tab
/// open/close cycles.
@MainActor
protocol ReconnectObserving: AnyObject {
    func addReconnectObserver(_ handler: @escaping @MainActor () -> Void) -> ReconnectObserverToken
    func removeReconnectObserver(_ token: ReconnectObserverToken)
}

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
