// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

// Which scopes a caller can actually reach.
//
// This is an extension rather than a member on `MethodScope` because
// it depends on daemon-only types: `DaemonProtocol` describes the
// wire and knows nothing about how a connection was vended.
//
// `daemon.capabilities` exists to filter `--help` down to the verbs
// the caller can actually invoke, so the advertised set has to agree
// with what the dispatcher will accept.
//
// The dispatcher itself still decides in `RPCConnection.scopeCheck`
// and `XPCConnection.scopeCheck`, which need to distinguish *why* a
// call was refused so they can say so. This predicate answers the
// yes/no question those two arrive at, and the advertiser uses it.
// Keeping all three in agreement is a review obligation, not
// something the type system enforces.
extension MethodScope {
    /// Whether a connection can reach `.orchestratorTab`-scoped methods.
    ///
    /// Authority is a **live orchestration grant**, not a role, so this
    /// takes `hasGrant` (the session's live grant state, read from the
    /// `OrchestratorGrantStore`), never `SessionRole`. A granted `.agent`
    /// session is reachable; an ungranted `.orchestrator` session is not.
    /// The role stays descriptive metadata; it grants nothing.
    ///
    /// Reachable over **both** transports for a granted session, because the
    /// grant is only meaningful on top of a real, provenance-checked identity:
    /// - **UDS**: `session.authenticate` already proved the caller's kernel
    ///   terminal-process provenance, and the grant was minted by the validated
    ///   GUI for this exact session. Cap + provenance + live grant together are
    ///   the authority. What provenance proves is that the caller's live parent
    ///   chain reaches the orchestrator tab's controlling terminal, which is
    ///   either the caller itself sitting in that terminal or a descendant that
    ///   detached from it. A same-uid process that merely stole the cap has no
    ///   such chain and can't authenticate, so it never reaches here.
    /// - **XPC**: the peer's audit token must validate against the daemon's
    ///   own signature; `validatedGUI` is the already-resolved verdict, never a
    ///   fresh signature walk.
    static func orchestratorTabReachable(
        hasGrant: Bool,
        transport: DispatchPeerContext.Transport,
        validatedGUI: Bool
    ) -> Bool {
        guard hasGrant else { return false }
        switch transport {
        case .uds:
            // A granted UDS session reaches the orchestrator tab by
            // construction: the grant guard above required a live grant, and a
            // UDS session only authenticates after passing terminal-process
            // provenance. No audit token is involved (UDS carries none); the
            // grant plus the authenticated identity are the authority.
            return true

        case .xpc:
            return validatedGUI
        }
    }

    /// Whether a connection can reach `.validatedGUI`-scoped methods.
    ///
    /// Orthogonal to role and to any authenticated session: the only
    /// thing that matters is that the peer validated against the
    /// daemon's own signature over XPC. `validatedGUI` is the
    /// **already-resolved** verdict (`DispatchPeerContext.validatedGUIPeer`).
    /// This predicate never re-runs the signature walk. UDS carries no
    /// audit token, so it can never be `.validatedGUI`.
    static func validatedGUIReachable(
        transport: DispatchPeerContext.Transport,
        validatedGUI: Bool
    ) -> Bool {
        switch transport {
        case .uds:
            return false

        case .xpc:
            return validatedGUI
        }
    }

    /// The scope set a caller may invoke. The two reachability predicates
    /// above are passed in so pure callers (the registry's advertiser)
    /// don't need the peer-validation / grant-store dependencies.
    ///
    /// `role` decides only the `.daemonWide` / `.session` base; it does
    /// **not** gate `.orchestratorTab`. That scope is added purely from
    /// `orchestratorTabReachable`, which the caller derives from the live
    /// grant, so a granted `.agent` is advertised the orchestrator surface
    /// and an ungranted `.orchestrator` is not. `.validatedGUI` is likewise
    /// orthogonal to role.
    static func allowedFor(
        role: SessionRole?,
        orchestratorTabReachable: Bool,
        validatedGUIReachable: Bool
    ) -> Set<MethodScope> {
        var allowed: Set<MethodScope>
        switch role {
        case nil:
            allowed = [.daemonWide]

        case .agent, .orchestrator:
            allowed = [.daemonWide, .session]
            // `.orchestratorTab` requires a session AND a live grant; the
            // caller folds the grant into `orchestratorTabReachable`. A live
            // orchestration grant gates the scope; role is descriptive, so a
            // granted `.agent` gets it and an ungranted `.orchestrator` does
            // not.
            if orchestratorTabReachable { allowed.insert(.orchestratorTab) }
        }
        if validatedGUIReachable { allowed.insert(.validatedGUI) }
        return allowed
    }
}
