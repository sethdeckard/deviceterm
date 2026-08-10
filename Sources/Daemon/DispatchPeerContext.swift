// SPDX-License-Identifier: GPL-3.0-or-later
//
// DispatchPeerContext. Value type that captures "who is calling"
// for every dispatched method.
//
// One context is constructed per dispatched request by the
// transport layer (UDS in `RPCConnection`, XPC in `XPCConnection`)
// and threaded through the handler signature in `MethodRegistry`.
// The orchestrator-mint gate, the orchestrator-scope check, the
// `daemon.capabilities` response, and pane-subscription tagging
// all read from it instead of consulting
// per-call ad-hoc state on the originating connection.
//
// Centralizing identity here keeps the two transports (UDS for the
// CLI and shim, XPC for the GUI) symmetrical: the dispatcher never
// needs a separate code path per transport: it just constructs
// the right `transport` case + the right `auditToken` (which is
// `nil` on UDS, present on XPC), and the rest of the daemon reads
// uniformly.

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct DispatchPeerContext: Sendable {
    /// Which transport vended the connection. The orchestrator-mint
    /// gate (in `session.create`) uses this to reject orchestrator
    /// mints over UDS unconditionally; XPC peers then run through
    /// the audit-token + self-mirror gate.
    public enum Transport: String, Sendable, Equatable {
        case uds
        case xpc
    }

    /// The transport this dispatch arrived on.
    public let transport: Transport

    /// The connection-id assigned by the server. UDS and XPC use
    /// disjoint `UInt64` ranges so a bare id can distinguish
    /// origins without an extra field.
    public let connectionId: UInt64

    /// The peer's audit token, captured at accept time on XPC connections
    /// via `xpc_connection_get_audit_token`. **XPC-only**: the audit token
    /// is the input to the daemon's self-mirror code-signature check that
    /// establishes GUI authority, which only XPC peers can pass. A UDS peer
    /// carries `nil` here; its kernel identity rides `peerProcess` instead
    /// (derived from `LOCAL_PEERTOKEN`), which establishes *process*
    /// provenance but never GUI authority: UDS never sets
    /// `validatedGUIPeer`.
    public let auditToken: audit_token_t?

    /// The session this connection authenticated as, if any. Set
    /// by a successful `session.authenticate` frame. The
    /// orchestrator-scope check reads its `id` to look up the session's
    /// live orchestration grant (authority is the grant, not the role).
    /// Daemon-wide methods see `nil`.
    public let authenticatedSession: SessionState?

    /// Whether this connection's peer validated as the host GUI:
    /// its audit token passed the daemon's self-mirror signature
    /// check (`PeerIdentity.validateGUIPeer`). Stamped on every XPC
    /// dispatch as a reliable identity fact, so downstream consumers
    /// (the pane-access principal, the orchestrator scope/mint gates,
    /// `daemon.capabilities` advertising, and the device-attach
    /// attribution gate) read one verdict instead of each re-running
    /// the walk. Repeated connections reuse the verdict while the peer
    /// identity remains resident in the shared cache. Production UDS
    /// dispatch contexts use `false` (a UDS peer carries no audit
    /// token); the initializer still accepts `true` for tests, so
    /// consumers that grant GUI authority must also require
    /// `transport == .xpc`.
    public let validatedGUIPeer: Bool

    /// Whether the GUI-validation verdict is STABLE (definitive) rather than a
    /// transient failure to read the peer's identity. A `.production` or a
    /// genuine `.rejected` signature mismatch is stable; an `.unavailable`
    /// verdict (the `SecCode` walk couldn't complete) is NOT. Gates that hard-
    /// reject an unvalidated peer (the orchestrator mint) consult this so a
    /// recoverable validation blip returns the RETRYABLE `notReady` instead of a
    /// terminal `roleViolation`, while a stable mismatch stays hard. UDS and test
    /// contexts default to stable (a UDS peer's non-GUI-ness is definitive).
    public let validationStable: Bool

    /// The kernel-established identity of a UDS peer, resolved once at accept
    /// via `LOCAL_PEERTOKEN`. Present only on UDS dispatch contexts; `nil` on
    /// XPC (which carries the audit token instead) and `nil` on UDS when the
    /// kernel couldn't vend it (a consumer requiring provenance must then
    /// fail closed). Used to capture the server-side session owner at
    /// `session.create`/restore; consumers that require it fail closed when
    /// it is unavailable.
    public let peerProcess: PeerProcessIdentity?

    /// The `authenticatedSession`'s live INCARNATION, captured from the same
    /// per-request liveness snapshot the scope check reads (a session id's
    /// monotonic incarnation, allocated on each insert). Threaded into
    /// `PaneAccessPrincipal.session(_, incarnation:)` so a request authorized
    /// under incarnation G carries G to the producer even if it resumes after
    /// the id was closed and restored at G+1, closing the reincarnation ABA
    /// hole. `nil` when the session carries no admissible incarnation (never
    /// authenticated, or a manager that doesn't track incarnations), which
    /// leaves the caller un-incarnation-pinned (UUID owner match still
    /// applies).
    public let sessionIncarnation: UInt64?

    public init(
        transport: Transport,
        connectionId: UInt64,
        auditToken: audit_token_t? = nil,
        authenticatedSession: SessionState? = nil,
        validatedGUIPeer: Bool = false,
        validationStable: Bool = true,
        peerProcess: PeerProcessIdentity? = nil,
        sessionIncarnation: UInt64? = nil
    ) {
        self.transport = transport
        self.connectionId = connectionId
        self.auditToken = auditToken
        self.authenticatedSession = authenticatedSession
        self.validatedGUIPeer = validatedGUIPeer
        self.validationStable = validationStable
        self.peerProcess = peerProcess
        self.sessionIncarnation = sessionIncarnation
    }
}

public extension DispatchPeerContext {
    /// The currently dispatching call's peer context, bound by the
    /// transport-layer dispatcher (`RPCConnection` on UDS, the XPC
    /// listener on XPC) for the duration of each handler invocation.
    /// Handlers that need to know who's calling (the orchestrator-
    /// mint gate, role-aware `daemon.capabilities`,
    /// subscription tagging) read this instead of consulting
    /// ad-hoc state on the originating connection.
    ///
    /// Why a task-local: handlers run inside the dispatcher's task;
    /// the value propagates across `await` boundaries within the same
    /// task without per-call wire-shape changes or signature-level
    /// threading. The same approach `SessionDispatchContext` uses for
    /// `originatingSessionId`; this context supersedes that single
    /// field with the broader caller-identity record while the
    /// existing TaskLocal stays in place for backwards source
    /// compatibility during the cutover.
    @TaskLocal static var current: DispatchPeerContext?

    /// A context with a different `authenticatedSession`. Used by
    /// the dispatcher after `session.authenticate` succeeds, when
    /// the per-call context for follow-on dispatches must reflect
    /// the new session.
    func withAuthenticatedSession(_ session: SessionState?) -> Self {
        DispatchPeerContext(
            transport: transport,
            connectionId: connectionId,
            auditToken: auditToken,
            authenticatedSession: session,
            validatedGUIPeer: validatedGUIPeer,
            validationStable: validationStable,
            peerProcess: peerProcess,
            sessionIncarnation: sessionIncarnation
        )
    }
}
