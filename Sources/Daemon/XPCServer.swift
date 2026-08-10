// SPDX-License-Identifier: GPL-3.0-or-later
//
// XPCServer: the XPC counterpart to `RPCServer`. Accepts peer
// connections on an `xpc_connection_t` listener and wraps each
// accepted peer in an `XPCConnection` actor.
//
// Two ways in, sharing all dispatch logic: only the listener
// source differs. `bindMachService(name:)` is the production
// entry point, pulling the launchd-vended listener via
// `xpc_connection_create_mach_service(name, queue, LISTENER)`.
// `bind(listener:)` takes an arbitrary listener handle so unit
// tests can drive the server via `xpc_connection_create_anonymous`
// + peer-endpoint handoff: a single in-process pair that
// exercises the full path (frame → envelope → handler → reply)
// without launchd or a real mach service.
//
// Connection-id space: XPC ids start at `xpcIdBase` so a bare
// connection id tells you which transport vended it, without an
// extra `transport` field. UDS uses a separate (smaller) range
// assigned by `RPCServer`.

import DaemonProtocol
import Foundation
@preconcurrency import XPC

public actor XPCServer {
    /// XPC connections take ids starting at this base so a
    /// connection id alone identifies the transport that vended
    /// it. UDS ids stay below.
    public static let xpcIdBase: UInt64 = 1_000_000_000

    private let methods: MethodRegistry
    /// Live orchestration-grant store, handed to each connection so its
    /// orchestrator scope check reads live grant state. Read OFF the registry
    /// (`methods.orchestratorGrant`), never a separate parameter, so the ledger
    /// this server enforces against is the SAME one the grant/revoke handlers
    /// write and the advertiser reads, by construction (mirroring `provenance`).
    /// Nil when the registry doesn't exercise orchestration grants.
    private let orchestratorGrantStore: OrchestratorGrantStore?
    /// Bundles the shared anchor store + the per-request provenance lookup so
    /// the store the close path revokes is GUARANTEED the store the lookup
    /// reads (see `ProvenanceContext`). Nil in tests that don't exercise
    /// terminal provenance; required whenever a validator is configured.
    private let provenance: ProvenanceContext?
    private let authValidator: AuthValidator?
    private let subscriptionRegistry: PaneSubscriptionRegistry?
    /// Provides each `XPCConnection` with the validator used to resolve
    /// the GUI verdict (stable results are then cached). Production passes
    /// `defaultPeerValidator` (the real signature walk); tests inject a stub.
    private let peerValidator: PeerValidator
    /// Shared across every connection so verdicts dedup by peer process
    /// identity. Repeated connections reuse a cached verdict while the
    /// process identity remains resident.
    private let verdictCache = PeerVerdictCache()

    private var connections: [UInt64: XPCConnection] = [:]
    private var nextConnectionId: UInt64
    /// Holds onto the listener handle the server is bound to so
    /// libxpc doesn't tear it down between accept callbacks.
    private var listener: xpc_connection_t?
    private var bound: Bool = false

    /// Number of currently live peer connections. Used by tests
    /// and by the daemon's idle predicate (a daemon with zero
    /// XPC peers and zero UDS peers is a candidate for idle
    /// exit, modulo the owned-sims rule).
    public var connectionCount: Int {
        connections.count
    }

    public init(
        methods: MethodRegistry,
        authValidator: AuthValidator? = nil,
        subscriptionRegistry: PaneSubscriptionRegistry? = nil,
        peerValidator: @escaping PeerValidator = defaultPeerValidator
    ) {
        // Provenance is read OFF the registry (`methods.provenance`), never
        // taken as a separate parameter, so the store the lookup reads, the
        // store the close path revokes, and the store `session.bindTerminal`
        // writes are structurally the same context (the one `defaultRegistry`
        // built the handler from), not merely equal by convention.
        //
        // A provenance-enabled server (one that authenticates sessions) MUST
        // therefore carry a registry with a `ProvenanceContext`. Without it,
        // binding still "works" but the close-path revocation silently no-ops.
        // Fail fast on that gap.
        precondition(
            authValidator == nil || methods.provenance != nil,
            "an authenticating XPCServer requires a registry with a ProvenanceContext"
        )
        self.methods = methods
        self.authValidator = authValidator
        self.subscriptionRegistry = subscriptionRegistry
        self.orchestratorGrantStore = methods.orchestratorGrant
        self.provenance = methods.provenance
        self.peerValidator = peerValidator
        self.nextConnectionId = Self.xpcIdBase
    }

    /// Bind to an existing `xpc_connection_t` listener. The
    /// caller owns the listener's lifetime up to this call; once
    /// bound, the server holds it strongly for the rest of its
    /// life. Idempotent. Calling twice is a no-op.
    ///
    /// Production main.swift uses `bindMachService(name:)`; unit
    /// tests pass an anonymous endpoint produced by
    /// `xpc_connection_create_anonymous`.
    public func bind(listener: xpc_connection_t) {
        guard !bound else { return }
        bound = true
        self.listener = listener
        xpc_connection_set_event_handler(listener) { [weak self] event in
            guard let self else { return }
            Task { [weak self] in
                await self?.handleListenerEvent(event)
            }
        }
        xpc_connection_resume(listener)
    }

    /// Bind to the launchd-vended mach service with the given
    /// name. Production entry point: the daemon's plist must
    /// declare a `MachServices` key matching `name`.
    public func bindMachService(name: String) {
        guard !bound else { return }
        let listener = xpc_connection_create_mach_service(
            name,
            nil,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        bind(listener: listener)
    }

    /// Stop accepting new peers and tear down every live
    /// connection. Best-effort: async cancellation may still
    /// drain in the background.
    public func stop() async {
        if let listener {
            xpc_connection_cancel(listener)
        }
        listener = nil
        bound = false
        let snapshot = connections
        connections.removeAll()
        for (_, connection) in snapshot {
            await connection.close()
        }
    }

    // MARK: - Listener event path

    private func handleListenerEvent(_ event: xpc_object_t) async {
        let type = xpc_get_type(event)
        if type == XPC_TYPE_ERROR {
            // Listener-level errors (`XPC_ERROR_TERMINATION_IMMINENT`,
            // `XPC_ERROR_CONNECTION_INVALID`) tear the server
            // down. The launchd lifecycle then decides whether to
            // demand-relaunch.
            //
            // Logged as a LISTENER failure, deliberately distinct from a peer
            // invalidation: this is the whole server going away, not one
            // client's connection dropping. Conflating them would point an
            // investigation at the wrong layer.
            DiagnosticLog.xpc.error(
                """
                listener failed: \(XPCErrorDescription.of(event), privacy: .public); \
                stopping server
                """
            )
            await stop()
            return
        }
        guard type == XPC_TYPE_CONNECTION else { return }
        // A new peer was handed to us. The libxpc handle is
        // already retained by the time we see it; we hand it to
        // the connection actor which keeps it for its lifetime.
        let peer = event
        let connectionId = nextConnectionId
        nextConnectionId &+= 1
        let connection = XPCConnection(
            id: connectionId,
            peer: peer,
            methods: methods,
            authValidator: authValidator,
            subscriptionRegistry: subscriptionRegistry,
            server: self,
            orchestratorGrantStore: orchestratorGrantStore,
            terminalAnchorStore: provenance?.anchorStore,
            sessionProvenanceLookup: provenance?.lookup,
            restorationGate: provenance?.restorationComplete,
            peerValidator: peerValidator,
            verdictCache: verdictCache
        )
        connections[connectionId] = connection
        DiagnosticLog.xpc.info(
            """
            accepted peer conn=\(connectionId, privacy: .public) \
            live=\(self.connections.count, privacy: .public)
            """
        )
        await connection.start()
    }

    /// Remove a tracked connection. The `XPCConnection` actor
    /// calls this on close so the registry doesn't keep dead
    /// entries. Internal API.
    public func removeConnection(id: UInt64) {
        connections.removeValue(forKey: id)
    }
}
