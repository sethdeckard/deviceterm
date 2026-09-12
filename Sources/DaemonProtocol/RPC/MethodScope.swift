// SPDX-License-Identifier: GPL-3.0-or-later

/// Declares which context an RPC method is meaningful
/// from. Powers `daemon.capabilities`'s `allowedMethods` filter so a
/// caller learns up-front which methods their context can usefully
/// invoke.
///
/// **Scope is the coarse per-request authorization gate and capability
/// classification.** Both transports enforce it per request
/// (`RPCConnection.scopeCheck` / `XPCConnection.scopeCheck`); pane- and
/// target-level authorization remains a separate layer on top. Trust is
/// context-based throughout deviceterm, but the `DEVICETERM_SESSION_CAP`
/// env var is only ONE factor. It is readable by any same-uid process
/// (`ps -E`), so it does not prove tab membership on its own.
/// A UDS caller authenticates a session only when a valid cap on a live session
/// is joined by matching kernel terminal provenance (its POSIX session /
/// controlling tty against the session's bound terminal); the daemon re-checks
/// that on every scoped request. See `ProvenanceMatcher`.
/// Pane-targeted calls are **not** trusted by paneId alone. Daemon-direct
/// methods such as `pane.closeById`, `pane.input.*`, `pane.ax.*`, and
/// `pane.subscribe` authorize through `PaneCoordinator`. Public GUI-backed
/// workspace mutations such as `pane.close` and `pane.rename` resolve and
/// authorize in `IntentDispatcher`.
///
/// Four values:
///   - `.daemonWide`: useful regardless of context. Includes
///     out-of-tab callers without env creds. Used by `daemon.ping`,
///     `daemon.capabilities`, and `device.list`.
///   - `.session`: useful only to in-tab callers. Some handlers
///     validate `(sessionId, cap)` directly (`pane.deviceList`,
///     `device.attach`, `session.close`, `shim.event`); the pane-
///     targeted daemon methods (`pane.input.*`, `pane.ax.*`,
///     `pane.closeById`, `pane.subscribe`) are authorized by the caller's cohort
///     membership on the pane (`PaneCoordinator.authorize`), not by the
///     paneId alone. GUI-backed workspace methods such as `tab.list`,
///     `pane.close`, and `pane.rename` apply their target visibility and
///     authority rules in `IntentDispatcher`. The tag exists so
///     `daemon.capabilities` correctly
///     filters the no-session subset: calling these without env creds
///     is pointless (no reachable pane), so they don't appear in
///     an out-of-tab caller's `allowedMethods`.
///   - `.automationTab`: requires valid creds AND a **live
///     automation grant** for the session, checked against the
///     `AutomationGrantStore` on every request. Authority is the grant,
///     not the role: a granted `.agent` reaches it, an ungranted
///     `.automation` does not. Grants are issued in memory only by the
///     validated GUI and never persisted, so a forged/rehydrated role
///     grants nothing. `pane.sendInput` and `pane.captureText` carry this tag,
///     as do the workspace-wide verbs (`tab.open`, `tab.focus`, `tab.move`,
///     `pane.focus`, `window.open`, `window.focus`), which create or rearrange
///     workspace surfaces or change workspace focus.
///     Reachable over BOTH transports for a granted session: over the GUI's
///     validated XPC connection, and over UDS from the CLI inside a granted
///     tab (a UDS session authenticates via cap + kernel terminal-process
///     provenance, so the grant sits on a real, provenance-checked identity).
///     Only *escalation* stays XPC-GUI-only: a UDS caller can neither mint an
///     automation role nor issue itself a grant, so it can only exercise a
///     grant the GUI already gave its session.
///   - `.validatedGUI`: reachable ONLY over XPC from a peer whose audit
///     token validates against the daemon's own signature, and
///     deliberately requiring no authenticated session and no role. The
///     GUI subscribes to `app.commands` at startup before any session
///     exists, and its shared connection re-authenticates as whichever
///     tab it created last, so the *audit token*, not the session, is
///     the trust anchor. The GUI back-channel (`app.commands` /
///     `app.commandResult`) carries this scope; the dispatcher admits a
///     validated XPC peer and rejects everyone else.
///
/// Scope decides "is this method meaningful from your context". The handler's
/// authorization layer then decides "may you touch this target", either in
/// `PaneCoordinator` for daemon-direct methods or `IntentDispatcher` for the
/// public workspace API.
public enum MethodScope: String, Codable, Sendable, Equatable, CaseIterable {
    case daemonWide
    case session
    case automationTab
    case validatedGUI
}
