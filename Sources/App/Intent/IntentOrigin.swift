// SPDX-License-Identifier: GPL-3.0-or-later

/// Where an intent came from, and therefore how much
/// authority it carries over the workspace.
///
/// This is the single switch that closes the whole external-caller
/// resolver surface (tab / pane / window resolution and listing), not
/// just `tab send-input` / `tab capture`. It is a *required* parameter of
/// every resolution entry point and of `IntentDispatcher.dispatch`. There is
/// no default, so a future call site cannot silently obtain unrestricted
/// in-process resolution by omitting an argument. The only way to express
/// "unrestricted" is to name `.inProcess` explicitly.
///
///  - `.inProcess`: the main menu, tab strip, and other GUI-internal
///    surfaces. Full authority: the human at the keyboard is the
///    workspace's owner, so `.current` borrows the key window and
///    resolution sees every tab.
///  - `.external(sessionID:hasAutomationGrant:)`: the CLI back-channel.
///    The visibility rule restricts to tabs the caller can legitimately
///    see, and `.current` is
///    resolved relative to the caller's own session, never the human's focus.
///    `sessionID == nil` means **no authority**; never "skip the check":
///    a nil-session external caller owns no tab, so every non-unprotected tab
///    is inaccessible to it and protection mutation is denied.
///
/// `hasAutomationGrant` is the daemon's per-request answer, stamped onto
/// the `AppCommand` it publishes, never a role and never anything the
/// caller supplies. `WorkspaceAuthorityDecision` reads it when a mutation
/// fails its ownership requirement; it widens no visibility, so a grant
/// still cannot see or touch a foreign protected tab. A missing `originAutomationGrant` decodes as `false`, so
/// incomplete input fails closed: the cost is a refusal a legitimate
/// caller can retry, not authority handed to an ungranted one.
enum IntentOrigin: Sendable, Equatable {
    case inProcess
    case external(sessionID: String?, hasAutomationGrant: Bool)

    /// Every external tab/pane/window enumeration restricts to
    /// externally-accessible tabs; in-process never does.
    var restrictsToVisibleTabs: Bool {
        if case .inProcess = self { return false }
        return true
    }

    /// The caller's session id for `.current` / owner resolution.
    /// `.inProcess` has no session of its own; callers resolve `.current`
    /// via the key window instead. `.external(nil)` stays nil (no
    /// authority); it is never widened to the foreground session, which
    /// would recreate the fail-open path in a new shape.
    var sessionID: String? {
        switch self {
        case .inProcess:
            return nil

        case let .external(sessionID, _):
            return sessionID
        }
    }
}
