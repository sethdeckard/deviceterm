// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneAccessPrincipal: derives a pane-access identity from the
// current dispatch context. This type does not itself enforce pane
// ownership; it names who a call acts as when a pane-authorization gate
// compares the identity against a pane's `Record.sessionId`. There are
// exactly two identities:
//
//   - `.session(id)`: an authenticated tab session, which owns the
//     panes whose `Record.sessionId` matches.
//   - `.guiPeer`: the signature-validated host GUI XPC peer, which
//     spans every session: the GUI renders and drives panes across all
//     tabs, and each of its shared transport lanes may authenticate as
//     any live tab, so it is identified as a *peer*, not a *session*.
//
// `internal`, not `public`: minting a principal is the module's own
// concern (every caller lives in `Daemon`), and there is deliberately
// no third "bypass ownership" identity.

import Foundation

enum PaneAccessPrincipal: Sendable, Equatable {
    /// An authenticated session identity plus the session INCARNATION the
    /// request was authorized under. Authorization gates compare the id with
    /// a pane's `Record.sessionId`; the incarnation closes a reincarnation
    /// ABA hole: a request scope-checked under one incarnation of a session
    /// id that parks and resumes after the id was closed and a *different*
    /// incarnation restored under the same UUID must not pass the new
    /// incarnation's producer gate. The incarnation is captured from the same
    /// immutable per-request liveness snapshot the scope check reads and is
    /// never re-read at handler entry. `nil` means "no incarnation pinning"
    /// and is used by direct/test callers or internal paths with no captured
    /// snapshot. A nil-incarnation request is not incarnation-gated (the UUID
    /// owner match still applies).
    case session(UUID, incarnation: UInt64?)
    /// The validated GUI XPC peer; spans every session.
    case guiPeer

    /// Convenience for call sites and tests that don't pin an incarnation
    /// (an internal daemon path, or a direct-on-actor test). Resolves to
    /// `.session(id, incarnation: nil)`. Distinct arity from the case, so
    /// `.session(id)` binds here and `.session(id, incarnation:)` binds the
    /// case.
    static func session(_ id: UUID) -> PaneAccessPrincipal { .session(id, incarnation: nil) }

    /// Derive the principal for the currently dispatching call from
    /// its `DispatchPeerContext`. `.guiPeer` only for a validated XPC
    /// peer (the `transport == .xpc` conjunct is belt-and-braces: UDS
    /// can never become `.guiPeer` even if a refactor mis-set the
    /// bool); otherwise the authenticated session, if any, carrying the
    /// incarnation stamped on the context by the scope-check's liveness
    /// snapshot; else nil (no authenticated caller and no validated GUI
    /// peer).
    static func fromCurrentDispatch() -> PaneAccessPrincipal? {
        guard let ctx = DispatchPeerContext.current else { return nil }
        if ctx.transport == .xpc, ctx.validatedGUIPeer { return .guiPeer }
        if let session = ctx.authenticatedSession {
            return .session(session.id, incarnation: ctx.sessionIncarnation)
        }
        return nil
    }

    /// The incarnation to pin a pane owned by `targetSessionId`. For an
    /// OWN-session caller (`.session(sid, inc)` with `sid == targetSessionId`)
    /// it is the DISPATCH-CAPTURED incarnation, so a request authorized under
    /// incarnation G that resumes after the same UUID was restored at G+1 stays
    /// pinned to G and is refused by the producer fence, rather than being
    /// re-pinned to G+1 by a fresh lookup. For a validated-GUI cross-session
    /// caller (`.guiPeer`, which carries no session incarnation) it resolves the
    /// target's CURRENT incarnation through `resolveCurrent` (a fenced
    /// `SessionManager` lookup), because the GUI legitimately targets whatever
    /// incarnation is live.
    static func ownerIncarnation(
        for targetSessionId: UUID,
        resolveCurrent: () async -> UInt64?
    ) async -> UInt64? {
        if case let .session(sid, incarnation) = fromCurrentDispatch(), sid == targetSessionId {
            return incarnation
        }
        return await resolveCurrent()
    }
}
