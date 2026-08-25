// SPDX-License-Identifier: GPL-3.0-or-later
//
// Role protocol: issue a live automation grant for a tab's sessions.
//
// One of the narrow role protocols carved out of `DaemonClient` so a consumer
// (and its test fake) depends only on the surface it uses. When a terminal in
// an automation tab has been created AND terminal-bound, the terminal-pane
// container calls this so the daemon marks the session automation-authorized:
// the live grant that lets an in-tab CLI drive the cross-tab `tab.sendInput`
// / `tab.capture` verbs. Authority is the grant, not the tab's role: without
// it, those verbs stay refused even in an automation tab.
//
// `automation.grant` is `.validatedGUI`-scoped, so no cap rides on the wire:
// the GUI's audit token is the authority, and `DaemonClient` is the sole
// conformer. This role vends ONLY issuance: revocation is handled daemon-side
// when a session is removed (closing a tab/terminal calls `session.close`,
// which revokes the session's grant via the store's session-removal fence), so
// the GUI never needs an explicit revoke call.
//
// `@MainActor`/`AnyObject` because the whole GUI daemon path is main-actor and
// reference-typed.

import DaemonProtocol
import Foundation

@MainActor
protocol AutomationGranting: AnyObject {
    /// Grant a live automation lease to `sessionIds`. The client stamps a
    /// monotonic revision internally (the daemon pairs it with the connection
    /// epoch for `(epoch, revision)` last-write-wins ordering), so callers pass
    /// only the target sessions, never a revision to keep in sync. Returns
    /// whether the batch applied; a stale revision or a non-live target yields
    /// `applied == false`. Issuance failure is fail-closed: the daemon simply
    /// holds no grant, so the elevated verbs stay unavailable.
    @discardableResult
    func grantAutomation(sessionIds: [UUID]) async throws -> AutomationGrantResult
}
