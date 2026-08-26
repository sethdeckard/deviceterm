// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import IOSurface
@preconcurrency import XPC
#if canImport(Darwin)
import Darwin
#endif

/// The libxpc `xpc_connection_get_audit_token` symbol is not
/// surfaced by Swift's `XPC` module on macOS 26 SDK. We re-import
/// it via `@_silgen_name` so the call site stays in Swift without
/// a `module.modulemap` shim in the build system. Spike-validated
/// under hardened runtime; safe with the connection's existing
/// memory model (the token is written into the caller's stack-
/// allocated `audit_token_t`).
@_silgen_name("xpc_connection_get_audit_token")
private func _xpc_connection_get_audit_token(
    _ connection: xpc_connection_t,
    _ outToken: UnsafeMutablePointer<audit_token_t>
)

/// Per-peer actor that owns one accepted XPC
/// connection.
///
/// The XPC-side counterpart to `RPCConnection`. Each peer the
/// `XPCServer` listener accepts gets one of these. The connection:
///
///   - Captures the peer's `audit_token_t` at accept time (the
///     trust primitive XPC carries that UDS doesn't, used to key the
///     shared verdict cache and validate the peer's signature on a
///     cache miss, identifying the calling process cryptographically).
///   - Receives `xpc_dictionary` messages framed by a `type`
///     discriminator: `"rpc"` carries an RPC envelope's JSON
///     bytes in a `"data"` field. Inbound traffic is RPC-only:
///     anything without that discriminator is dropped. The
///     `"surface"` type travels the other way: the daemon emits
///     XPC-marshalled IOSurfaces to the GUI on this connection.
///   - Dispatches RPC frames through the shared `MethodRegistry`
///     using the same intercept (`session.authenticate`) + scope
///     check + handler-invocation logic as the UDS path. The
///     dispatched handler runs with `DispatchPeerContext.current`
///     bound to a context whose `transport == .xpc` and whose
///     `auditToken` carries the peer's token.
///   - Cleans up its `PaneSubscriptionRegistry` slot on
///     invalidation so any pane subscriptions are dropped without
///     leaking continuations.
///
/// `xpc_connection_get_audit_token` is not exposed by Swift's
/// public `XPC` module on macOS 26; the `@_silgen_name` shim
/// below re-imports it from libxpc.
public actor XPCConnection {
    /// Where one subscription is in its lifetime. The early
    /// (`preStreaming`) record is created before the handler runs, so a
    /// drain arriving *after* it (keyed by this envelope id) finds a
    /// record, and a terminal cause that fires during the handler is seen
    /// by the synchronous post-handler inspect. A drain arriving *before*
    /// the record exists (per-callback tasks aren't FIFO) is held as a
    /// tombstone and applied on record creation. `streaming` carries the
    /// event drain task; `terminal` means a teardown cause already ran.
    private enum SubscriptionPhase {
        case preStreaming
        case streaming(Task<Void, Never>)
        case terminal
    }

    /// In-flight subscription, keyed by the originating request id.
    private struct SubscriptionRecord {
        var phase: SubscriptionPhase
        /// The surface-delivery registration id, also the pool lease
        /// token. `nil` for a non-pane subscription (events, app.commands)
        /// and for the brief window before the mint returns.
        var subscriptionToken: UUID?
        /// The universal teardown box (device pool teardown + producer
        /// cleanup routing). `nil` for a non-pane subscription.
        let lifecycle: SubscriptionLifecycle?
    }

    private static let drainTombstoneTTL: TimeInterval = 5
    private static let drainTombstoneCap = 128

    private let id: UInt64
    private let peer: xpc_connection_t
    private let methods: MethodRegistry
    private let authValidator: AuthValidator?
    private let subscriptionRegistry: PaneSubscriptionRegistry?
    /// Live automation-grant store, consulted by the automation scope
    /// check on every request. Authority is the presence of a live grant,
    /// not a cached role, so a forged manifest role authorizes nothing.
    /// Nil in tests that don't exercise the automation scope.
    private let automationGrantStore: AutomationGrantStore?
    /// The terminal-anchor store, for revoking this connection's issued
    /// anchors on close (the validated GUI issues terminal bindings over
    /// XPC). Read only for `revokeAll(issuedBy:)` at teardown: the XPC
    /// provenance arms (validated-GUI, exact-owner) never consult an anchor,
    /// so the authenticate gate passes `anchor: nil`.
    private let terminalAnchorStore: TerminalAnchorStore?
    /// Per-request provenance lookup: resolves a session's live owner (nil
    /// when the session has closed). Consulted at `session.authenticate` AND
    /// before every scoped request, so closing a session invalidates an
    /// already-authenticated XPC socket. XPC has no terminal arm, so only the
    /// snapshot's owner (and its liveness) matters here.
    private let sessionProvenanceLookup: SessionProvenanceLookup?
    /// See `RestorationGate`. Reclassifies an unknown-session authenticate to
    /// the retryable `notReady` while a fresh daemon still awaits its restore
    /// batch. Nil means "always treat restoration as complete."
    private let restorationGate: RestorationGate?
    /// Resolves this peer's GUI-validation verdict. Injected so tests
    /// can substitute a stub; production is the real signature walk.
    private let peerValidator: PeerValidator
    /// Shared audit-identity cache so the signature walk dedups across
    /// connections from the same peer process.
    private let verdictCache: PeerVerdictCache
    /// Weak so the server can drop the connection without
    /// keeping it alive past `close()`. Used only to send the
    /// "I'm gone, please forget me" message back so the server's
    /// registry stays free of dead peers (the analogue of
    /// `RPCConnection.server.removeConnection`).
    private weak var server: XPCServer?

    /// Captured at accept time. Used to key the shared verdict cache
    /// and, on a cache miss, validate the peer's signature
    /// (`PeerIdentity` resolves it to a `SecCode` for the self-mirror
    /// check). Consumers of the resulting verdict read the resolved
    /// `DispatchPeerContext.validatedGUIPeer` bool, not this token.
    private let auditToken: audit_token_t

    /// The session this connection authenticated as, if any.
    /// Set by a successful `session.authenticate` intercept;
    /// consulted by the pre-dispatch scope check.
    private var authenticatedSession: SessionState?

    /// The per-connection copy of the GUI-validation verdict. Holds
    /// only a **stable** outcome (a positive or a genuine mismatch); a
    /// non-cacheable `.unavailable` result leaves this `nil`, so the
    /// next dispatch re-resolves. When set, it keeps the expensive
    /// `SecCode` signature walk off every `pane.input.*` during a live
    /// drag. Consumers read the resolved verdict: the stamped
    /// `DispatchPeerContext.validatedGUIPeer` bool, or the value the
    /// dispatcher hands the scope check, never this field directly.
    private var guiPeerVerdict: Bool?

    private var subscriptions: [UInt32: SubscriptionRecord] = [:]
    /// Drains that arrived before their subscription's early record was
    /// inserted. `xpc_connection_set_event_handler` spawns an independent
    /// `Task` per inbound message and Swift doesn't guarantee those tasks
    /// run in arrival order, so a `pane.surfaceDrain` can reach the
    /// dispatcher before the matching `pane.subscribe` inserts its record.
    /// The tombstone remembers the drain (keyed by subscribe request id,
    /// aged so a drain that never matches is pruned) and the record's
    /// creation applies it. Expired entries are pruned opportunistically on
    /// the next drain/subscribe; the hard count cap bounds residence.
    private var drainTombstones: [UInt32: Date] = [:]
    /// Handler tasks for messages this connection is still processing, so
    /// `close()` can cancel them.
    ///
    /// The closed flag alone can't do this: it drops a message before dispatch
    /// but, as `handleEvent` notes, does nothing to a handler that already
    /// entered and suspended. A contact-lane waiter parked behind a long
    /// gesture is exactly that, and cancellation is what wakes it.
    private var inFlightRequests: [UInt64: Task<Void, Never>] = [:]
    private var nextRequestId: UInt64 = 1
    private var closed: Bool = false

    init(
        id: UInt64,
        peer: xpc_connection_t,
        methods: MethodRegistry,
        authValidator: AuthValidator? = nil,
        subscriptionRegistry: PaneSubscriptionRegistry? = nil,
        server: XPCServer? = nil,
        automationGrantStore: AutomationGrantStore? = nil,
        terminalAnchorStore: TerminalAnchorStore? = nil,
        sessionProvenanceLookup: SessionProvenanceLookup? = nil,
        restorationGate: RestorationGate? = nil,
        peerValidator: @escaping PeerValidator = defaultPeerValidator,
        verdictCache: PeerVerdictCache = PeerVerdictCache()
    ) {
        self.id = id
        self.peer = peer
        self.methods = methods
        self.authValidator = authValidator
        self.subscriptionRegistry = subscriptionRegistry
        self.server = server
        self.automationGrantStore = automationGrantStore
        self.terminalAnchorStore = terminalAnchorStore
        self.sessionProvenanceLookup = sessionProvenanceLookup
        self.restorationGate = restorationGate
        self.peerValidator = peerValidator
        self.verdictCache = verdictCache
        // Capture the audit token before any messages flow: the
        // value is stable for the lifetime of the connection, so
        // pulling it once at accept is correct.
        var token = audit_token_t(val: (0, 0, 0, 0, 0, 0, 0, 0))
        _xpc_connection_get_audit_token(peer, &token)
        self.auditToken = token
    }

    /// Hand handlers a parseable JSON object when the request had
    /// no body, mirroring `RPCConnection.normalizeParams`. Lives
    /// here as a static so handlers see the same input
    /// regardless of which transport vended them.
    private static func normalizeParams(_ body: RPCEnvelope.Body) -> Data {
        switch body {
        case .empty:
            return Data("{}".utf8)

        case let .params(bytes):
            return bytes

        case .result, .error:
            return Data("{}".utf8)
        }
    }

    /// Wire the underlying peer's event handler to this actor.
    /// Idempotent: calling twice is a no-op.
    ///
    /// The peer's `setEventHandler` runs callbacks on libxpc's
    /// internal queue; we hop into the actor via `Task` to keep
    /// dispatch serialized. Lifetime: the actor holds the peer
    /// strongly, so the handler closure capturing `self` doesn't
    /// create a retain cycle the peer would resolve. The peer
    /// is invalidated explicitly in `close()`.
    public func start() {
        guard !closed else { return }
        xpc_connection_set_event_handler(peer) { [weak self] event in
            guard let self else { return }
            Task { [weak self] in
                await self?.admit(event)
            }
        }
        xpc_connection_resume(peer)
    }

    /// Register an inbound message's handler task, then run it.
    ///
    /// The closed check, the id, the spawn, and the store share one
    /// non-suspending actor step. A task that spawned first and registered
    /// itself second would leave a window for `close()` to run between the
    /// two, clearing the registry and letting the late task dispatch against a
    /// closed connection.
    ///
    /// The key is minted here rather than taken from the envelope: the
    /// envelope's `id` is client-supplied and absent entirely on a
    /// notification, so it is neither always present nor guaranteed unique.
    private func admit(_ event: xpc_object_t) {
        guard !closed else { return }
        let id = nextRequestId
        nextRequestId &+= 1
        inFlightRequests[id] = Task { [weak self] in
            await self?.handleEvent(event)
            await self?.retireRequest(id)
        }
    }

    /// Drop a finished handler. Idempotent, so a task completing as `close()`
    /// clears the registry can't resurrect an entry.
    private func retireRequest(_ id: UInt64) {
        inFlightRequests.removeValue(forKey: id)
    }

    /// Close the connection: cancels every in-flight
    /// subscription drain (their `onCancel` hooks release
    /// per-subscription resources), drops every pane-subscription
    /// registry entry tied to this connection so the surface
    /// fanout doesn't keep dead delivery closures, cancels the
    /// underlying XPC connection, and asks the server to drop
    /// us from its connections map. Idempotent.
    public func close() async {
        guard !closed else { return }
        closed = true
        // Revoke every automation grant this connection issued before the
        // close completes: a grant's authority dies with the GUI connection
        // that holds the lease. A grant reissued by a newer connection (which
        // took ownership) is left intact. Gated on the validated-GUI verdict:
        // only a validated peer can grant (`automation.grant` is
        // `.validatedGUI`), so only such a connection can have grants or an
        // in-flight late grant to fence, which also keeps the store's
        // closed-issuer set from being grown by unvalidated connect/disconnect
        // churn.
        if let automationGrantStore, guiPeerVerdict == true {
            await automationGrantStore.revokeAll(issuedBy: id)
        }
        // Revoke every terminal anchor this connection bound, on the same
        // gate and for the same reason: a terminal binding's authority is the
        // validated GUI connection that issued it, so it must not outlive that
        // connection. A re-bind from a newer connection (which took ownership)
        // is left intact by `revokeAll`'s issuer match.
        if let terminalAnchorStore, guiPeerVerdict == true {
            await terminalAnchorStore.revokeAll(issuedBy: id)
        }
        // Orphan every lease token BEFORE cancelling tasks: an abrupt
        // disconnect is not proof the GPU finished reading, so held slots
        // stay pinned (never force-freed), and a late ack can still
        // drain them. Orphan dominates any in-flight drain.
        for (_, record) in subscriptions {
            if let lifecycle = record.lifecycle {
                await lifecycle.fire(.orphan)
            }
        }
        for (_, record) in subscriptions {
            if case let .streaming(task) = record.phase {
                task.cancel()
            }
        }
        subscriptions.removeAll()
        if let registry = subscriptionRegistry {
            await registry.dropAllForConnection(connectionId: id)
        }
        // Wake anything this connection left suspended mid-handler. A lane
        // waiter observes the cancellation, leaves its queue, and resumes
        // without touching the backend. The deferred-close supervisor is
        // deliberately not tracked here: it is detached and has to finish.
        for task in inFlightRequests.values {
            task.cancel()
        }
        inFlightRequests.removeAll()
        xpc_connection_cancel(peer)
        if let server {
            await server.removeConnection(id: id)
        }
    }

    // MARK: - Receive

    private func handleEvent(_ event: xpc_object_t) async {
        // Closed guard: `xpc_connection_set_event_handler` spawns an
        // independent, non-FIFO `Task` per inbound message, so a request
        // enqueued before `close()` can run after it. This guard drops such
        // a message before it is *dispatched*; it does NOT stop a handler
        // that already entered and later resumed past a suspension. That
        // remaining case (a grant handler suspended on its liveness check,
        // resuming after close) is fenced by the grant store's closed-issuer
        // tombstone, not by this flag. Both this and `close()` run on the
        // actor, so the flag is authoritative for the not-yet-dispatched case.
        guard !closed else { return }
        let type = xpc_get_type(event)
        if type == XPC_TYPE_ERROR {
            // Any error on the peer (`XPC_ERROR_CONNECTION_INVALID`,
            // `XPC_ERROR_CONNECTION_INTERRUPTED`, etc.) tears the
            // connection down. The dispatcher cannot distinguish
            // transient from terminal in a way that's useful, so
            // we drop all state and let the peer reconnect.
            //
            // The daemon pid distinguishes a peer disconnect from process
            // replacement: one connection id going away while the pid holds
            // steady means a single peer dropped. A later `lifecycle` startup
            // entry with another pid indicates replacement.
            DiagnosticLog.xpc.notice(
                """
                invalidated conn=\(self.id, privacy: .public) \
                error=\(XPCErrorDescription.of(event), privacy: .public) \
                pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)
                """
            )
            await close()
            return
        }
        if type != XPC_TYPE_DICTIONARY {
            // The protocol is dictionaries-only; ignore anything
            // else without surfacing.
            return
        }
        guard
            let kind = xpc_dictionary_get_string(event, XPCTransportKey.type)
                .map({ String(cString: $0) }),
            kind == XPCTransportKey.rpcValue
        else {
            // Not an RPC frame: drop. Surface payloads are
            // outbound-only, so nothing else is expected here.
            return
        }
        guard let jsonBytes = readDataField(event, key: XPCTransportKey.data) else {
            return
        }
        await dispatchEnvelope(jsonBytes: jsonBytes)
    }

    // MARK: - Dispatch

    private func dispatchEnvelope(jsonBytes: Data) async {
        let envelope: RPCEnvelope
        do {
            envelope = try RPCEnvelope.decode(jsonBytes)
        } catch {
            // Malformed payload: no envelope id to correlate, so
            // nothing meaningful to reply with. Drop.
            return
        }
        guard envelope.type == .request else { return }
        guard let method = envelope.method else {
            // Reply only if there's an id to correlate on; a method-less
            // notification is dropped.
            if let id = envelope.id {
                sendErrorReply(
                    envelopeId: id,
                    error: RPCError(
                        code: RPCErrorCode.invalidRequest,
                        message: "Request envelope missing `method`"
                    )
                )
            }
            return
        }

        // A request with no `id` is a one-way notification: run it
        // fire-and-forget and send nothing back. `pane.surfaceDrain` is
        // intercepted here (before generic dispatch) because its target,
        // the subscription task, lives on this connection keyed by
        // the originating `pane.subscribe` request id, which no registry
        // handler can resolve.
        guard let envelopeId = envelope.id else {
            if method == RPCMethod.paneSurfaceDrain.rawValue {
                await handleSurfaceDrainNotification(body: envelope.body)
                return
            }
            await dispatchNotification(method: method, body: envelope.body)
            return
        }

        // `session.authenticate` mutates per-connection state, so
        // it's intercepted by the dispatcher rather than handled
        // through the registry. Mirrors the UDS path.
        if method == RPCMethod.sessionAuthenticate.rawValue {
            let response = await handleAuthenticate(
                envelopeId: envelopeId,
                body: envelope.body
            )
            sendEnvelope(response)
            return
        }

        guard let resolved = methods.lookup(method) else {
            sendEnvelope(
                RPCEnvelope(
                    id: envelopeId,
                    type: .response,
                    method: nil,
                    body: .error(
                        RPCError(
                            code: RPCErrorCode.methodNotFound,
                            message: "Method not found: \(method)"
                        )
                    )
                )
            )
            return
        }

        let scope = methods.scope(of: method) ?? .daemonWide
        // Resolve the verdict first, THEN snapshot the session once, so a
        // `session.authenticate` racing in during a cache-miss await can't
        // split this request across two identities. Both identity inputs
        // (verdict + session) are fixed here; `scopeCheck` then awaits again
        // to read live grant state, but only against this already-fixed
        // session id, so no identity input is re-read after the snapshot.
        let (validatedGUI, verdictStable) = await resolveGUIPeerVerdict()
        // Recheck closed after the verdict suspension. A first request can
        // suspend inside `resolveGUIPeerVerdict()` (the signature walk); if
        // `close()` runs meanwhile it sees `guiPeerVerdict == nil` and records
        // no closed-issuer tombstone, so a resumed grant would otherwise
        // create a lease for the dead connection. Aborting here closes that
        // window; the tombstone still fences the later liveness-suspension
        // case, where the verdict is already resolved.
        guard !closed else { return }
        let session = authenticatedSession
        // Re-validate provenance once (see the UDS `dispatch`). A revoked
        // session downgrades the effective principal to nil so a `.daemonWide`
        // origin-aware handler (capabilities) can't resolve using stale
        // identity; `.session`/`.automationTab` then reject via scopeCheck.
        // The resolved incarnation rides into the principal so a parked request
        // can't pass a later incarnation's producer gate.
        let provenanceReject: RPCError?
        let sessionIncarnation: UInt64?
        if let session {
            let resolved = await resolveSession(
                for: session.id,
                validatedGUI: validatedGUI,
                verdictStable: verdictStable
            )
            provenanceReject = resolved.error
            sessionIncarnation = resolved.incarnation
        } else {
            provenanceReject = nil
            sessionIncarnation = nil
        }
        let effectiveSession = provenanceReject == nil ? session : nil
        if let scopeError = await scopeCheck(
            scope: scope,
            session: effectiveSession,
            validatedGUI: validatedGUI,
            verdictStable: verdictStable,
            invalidationError: provenanceReject
        ) {
            sendEnvelope(
                RPCEnvelope(
                    id: envelopeId,
                    type: .response,
                    method: nil,
                    body: .error(scopeError)
                )
            )
            return
        }

        let peerContext = DispatchPeerContext(
            transport: .xpc,
            connectionId: id,
            auditToken: auditToken,
            authenticatedSession: effectiveSession,
            validatedGUIPeer: validatedGUI,
            validationStable: verdictStable,
            sessionIncarnation: effectiveSession == nil ? nil : sessionIncarnation
        )
        let originatingSid = effectiveSession?.id.uuidString

        switch resolved {
        case let .oneShot(handler):
            let response = await SessionDispatchContext.$originatingSessionId
                .withValue(originatingSid) {
                    await DispatchPeerContext.$current
                        .withValue(peerContext) {
                            await runOneShot(
                                envelopeId: envelopeId,
                                handler: handler,
                                body: envelope.body
                            )
                        }
                }
            sendEnvelope(response)

        case let .subscription(handler):
            await SessionDispatchContext.$originatingSessionId
                .withValue(originatingSid) {
                    await DispatchPeerContext.$current
                        .withValue(peerContext) {
                            await runSubscription(
                                envelopeId: envelopeId,
                                method: method,
                                scope: scope,
                                handler: handler,
                                body: envelope.body
                            )
                        }
                }
        }
    }

    /// Dispatch a one-way notification (a request with no `id`) that
    /// isn't transport-intercepted. Runs the resolved one-shot handler
    /// fire-and-forget under the peer context and discards its result.
    /// `pane.surfaceRelease` reaches the daemon this way; its handler
    /// reads `DispatchPeerContext.current.connectionId` for the pool's
    /// connection-authority check. A missing/subscription method or a
    /// failed scope check drops silently.
    private func dispatchNotification(method: String, body: RPCEnvelope.Body) async {
        guard case let .oneShot(handler) = methods.lookup(method) else { return }
        let scope = methods.scope(of: method) ?? .daemonWide
        // Resolve the verdict first, then snapshot the session once (see
        // dispatchEnvelope) so the check and attribution share one identity.
        let (validatedGUI, verdictStable) = await resolveGUIPeerVerdict()
        // Recheck closed after the verdict suspension, same rationale as
        // `dispatchEnvelope`: a request that resumed after `close()` must not
        // reach a handler that could mutate grant state.
        guard !closed else { return }
        let session = authenticatedSession
        let provenanceReject: RPCError?
        let sessionIncarnation: UInt64?
        if let session {
            let resolved = await resolveSession(
                for: session.id,
                validatedGUI: validatedGUI,
                verdictStable: verdictStable
            )
            provenanceReject = resolved.error
            sessionIncarnation = resolved.incarnation
        } else {
            provenanceReject = nil
            sessionIncarnation = nil
        }
        let effectiveSession = provenanceReject == nil ? session : nil
        if await scopeCheck(
            scope: scope,
            session: effectiveSession,
            validatedGUI: validatedGUI,
            verdictStable: verdictStable,
            invalidationError: provenanceReject
        ) != nil { return }
        let peerContext = DispatchPeerContext(
            transport: .xpc,
            connectionId: id,
            auditToken: auditToken,
            authenticatedSession: effectiveSession,
            validatedGUIPeer: validatedGUI,
            validationStable: verdictStable,
            sessionIncarnation: effectiveSession == nil ? nil : sessionIncarnation
        )
        let originatingSid = effectiveSession?.id.uuidString
        let paramsJSON = Self.normalizeParams(body)
        await SessionDispatchContext.$originatingSessionId
            .withValue(originatingSid) {
                await DispatchPeerContext.$current.withValue(peerContext) {
                    _ = try? await handler(paramsJSON)
                }
            }
    }

    /// Resolve whether this peer is the validated host GUI. The verdict
    /// is `validatedGUIPeer`, a reliable identity fact stamped on every
    /// dispatch. Stable outcomes are retained per connection
    /// (`guiPeerVerdict`) so a live pane drag doesn't re-hop, and shared
    /// by process identity through the `PeerVerdictCache` so the
    /// expensive `SecCode` walk isn't repeated across connections;
    /// non-cacheable failures are retried. This is the daemon's single
    /// resolution point; every downstream consumer reads the resolved
    /// bool, never re-validates.
    /// Returns an IMMUTABLE `(verdict, stable)` snapshot. Downstream must carry
    /// this snapshot through the request rather than re-reading the mutable
    /// `guiPeerVerdict` after an `await`: a concurrent successful validation
    /// could otherwise flip an earlier ephemeral failure into a stable one and
    /// turn a retryable `-32002` into a hard `-32001`, pruning a valid
    /// credential. `stable == false` means the walk was non-cacheable
    /// (`.unavailable`): we can't say the peer ISN'T the GUI this time.
    private func resolveGUIPeerVerdict() async -> (verdict: Bool, stable: Bool) {
        if let verdict = guiPeerVerdict { return (verdict, true) }  // cached => stable
        let token = auditToken
        let validator = peerValidator
        let outcome = await verdictCache.verdict(
            for: PeerVerdictCache.Key(auditToken: token)
        ) {
            switch validator(token) {
            case .production, .adHocFromSameBuild:
                return .cache(true)

            case .rejected:
                // A genuine, stable signature mismatch: cache it so a
                // rejected peer's churn doesn't re-walk.
                return .cache(false)

            case .unavailable:
                // The peer's identity couldn't be read. Deny this
                // attempt but don't cache it (non-cacheable), so a
                // legitimate GUI re-resolves on its next dispatch rather
                // than being pinned to a false.
                return .ephemeral(false)
            }
        }
        // Hold a per-connection copy only for a stable verdict, so a
        // non-cacheable failure doesn't pin this connection to a false
        // for its whole life.
        if outcome.stable { guiPeerVerdict = outcome.verdict }
        return (outcome.verdict, outcome.stable)
    }

    /// Scope-check a request against a **single, already-captured**
    /// `(session, validatedGUI)` snapshot. The verdict is resolved (and the
    /// session snapshotted) once, before the check, so a
    /// `session.authenticate` racing in on a cache-miss suspension can't
    /// scope-check under one identity while the request is handled or
    /// attributed as another. The check itself is `async` only to read live
    /// grant state for the `.automationTab` arm (against the already-fixed
    /// session id); no other identity input is re-read after the snapshot.
    private func scopeCheck(
        scope: MethodScope,
        session: SessionState?,
        validatedGUI: Bool,
        verdictStable: Bool,
        invalidationError: RPCError?
    ) async -> RPCError? {
        switch scope {
        case .daemonWide:
            // Runs regardless, under the effective (possibly-downgraded)
            // session: no stale principal reaches an origin-aware handler.
            return nil

        case .session:
            guard session != nil else {
                // Never authenticated, or the cached principal just failed
                // re-validation (session closed). The provenance re-check
                // ran once in `dispatch`; surface its specific reason here.
                return invalidationError ?? RPCError(
                    code: RPCMethodError.unauthorizedCode,
                    message: "session-scoped method requires an "
                        + "authenticated connection; call "
                        + "session.authenticate first"
                )
            }
            return nil

        case .automationTab:
            // Authority is a LIVE automation grant, not a cached role.
            // The authenticated session must currently hold a grant issued
            // by the validated GUI, checked against the live store on every
            // request, so a forged role authorizes nothing, and nothing
            // role-bearing is persisted for a restart to resurrect. The XPC
            // peer must also still validate against the daemon's signature.
            guard let session else {
                return RPCError(
                    code: RPCMethodError.unauthorizedCode,
                    message: "automation-scoped method requires an "
                        + "authenticated connection; call "
                        + "session.authenticate first"
                )
            }
            guard validatedGUI else {
                // A transient (non-cached) identity-read failure is retryable:
                // a legitimate GUI whose audit token momentarily couldn't be
                // resolved must re-resolve on its next request, not be hard-
                // rejected. Only a STABLE verdict is a real signature mismatch.
                return validationRefusal(
                    verdictStable: verdictStable,
                    stableMessage: "automation-scoped XPC peer failed validation"
                )
            }
            let granted = await automationGrantStore?.hasGrant(session.id) ?? false
            guard granted else {
                return RPCError(
                    code: RPCMethodError.scopeViolationCode,
                    message: "this session has no live automation grant; "
                        + "open an automation tab in the deviceterm GUI"
                )
            }
            return nil

        case .validatedGUI:
            // Admit a validated XPC peer: no session or role required.
            // The audit token is the trust anchor, matching exactly what
            // `validatedGUIReachable` advertises, so dispatch and
            // capability filtering never disagree. The GUI back-channel
            // (`app.commands` / `app.commandResult`) carries this scope.
            guard validatedGUI else {
                // Transient identity-read failure → retryable; stable verdict →
                // hard rejection. (See the `.automationTab` arm.) This keeps a
                // definite-mismatch `daemon.shutdown` and the back-channel
                // reachable across a momentary signature-read blip instead of
                // abandoning them on the first flake.
                return validationRefusal(
                    verdictStable: verdictStable,
                    stableMessage: "validated-GUI-scoped XPC peer failed validation"
                )
            }
            return nil
        }
    }

    /// Map a failed GUI-peer verdict to an error: a STABLE verdict is a genuine
    /// signature mismatch (hard `scopeViolationCode`); an EPHEMERAL one (the
    /// audit token couldn't be read this time, not cached) is the retryable
    /// `notReadyCode`, so a legitimate GUI re-resolves on its next request
    /// rather than being pinned to a rejection by one transient flake.
    private func validationRefusal(verdictStable: Bool, stableMessage: String) -> RPCError {
        if verdictStable {
            return RPCError(code: RPCMethodError.scopeViolationCode, message: stableMessage)
        }
        return RPCError(
            code: RPCMethodError.notReadyCode,
            message: "GUI peer validation temporarily unavailable; retry"
        )
    }

    /// Run the provenance matcher for `sessionId` against the current store
    /// snapshot and map the verdict to an `RPCError` (nil = authorized). Used by
    /// `session.authenticate`; the per-request paths call `resolveSession`
    /// directly because they also need the incarnation this drops. XPC has no
    /// terminal arm, so only the snapshot's owner (and its liveness) is
    /// consulted; a nil snapshot means the session has closed and fails closed.
    /// A nil lookup disables the check (tests that don't exercise provenance).
    private func provenanceError(
        for sessionId: UUID,
        validatedGUI: Bool,
        verdictStable: Bool
    ) async -> RPCError? {
        await resolveSession(for: sessionId, validatedGUI: validatedGUI, verdictStable: verdictStable).error
    }

    /// As `provenanceError`, but also returns the admissible incarnation so the
    /// dispatch path can stamp it into the principal (see the UDS
    /// `resolveSession`). Consults the lifecycle admission gate first
    /// (`.notReady` is retryable regardless of provenance).
    private func resolveSession(
        for sessionId: UUID,
        validatedGUI: Bool,
        verdictStable: Bool
    ) async -> (error: RPCError?, incarnation: UInt64?) {
        guard let lookup = sessionProvenanceLookup else {
            // Fail closed. See the UDS `resolveSession`. A configured
            // validator with no provenance lookup is a wiring bug, not a
            // bypass.
            let error = authValidator == nil ? nil : RPCError(
                code: RPCMethodError.unauthorizedCode,
                message: "invalid sessionId or cap"
            )
            return (error, nil)
        }
        guard let snapshot = await lookup(sessionId) else {
            return (RPCError(code: RPCMethodError.unauthorizedCode, message: "invalid sessionId or cap"), nil)
        }
        // Lifecycle admission gate: mid-registration / mid-teardown is retryable.
        if case .notReady = snapshot.admission {
            return (RPCError(code: RPCMethodError.notReadyCode, message: "session not ready; retry shortly"), nil)
        }
        let incarnation: UInt64?
        if case let .ready(value) = snapshot.admission { incarnation = value } else { incarnation = nil }
        let owner = OwnerProcessIdentity(auditToken: auditToken)
        let peer: ProvenancePeer = validatedGUI
            ? .validatedGUI(owner: owner)
            : .xpc(owner: owner)
        switch ProvenanceMatcher.verdict(
            peer: peer,
            sessionOwner: snapshot.owner,
            anchor: snapshot.anchor?.facts
        ) {
        case .authorized:
            return (nil, incarnation)

        case .notReady, .unauthorized:
            // Transient validation: `resolveGUIPeerVerdict` couldn't read the
            // peer's signature this time (an ephemeral `.unavailable`,
            // `stable == false`). We therefore can't say the peer ISN'T the
            // validated GUI: an anchor-less session (owner arm not matching
            // this peer) would otherwise be rejected here even though the real
            // GUI owns it.
            // Return the RETRYABLE code so the GUI re-authenticates (validation
            // usually succeeds on retry) instead of the client pruning the
            // credential as a dead session. Uses the IMMUTABLE `verdictStable`
            // snapshot, NOT the mutable `guiPeerVerdict`, which a concurrent
            // successful validation could flip mid-request, turning this
            // retryable case into a hard `unauthorized`. A stable rejection or
            // a stable-validated non-owner is a definitive `unauthorized`.
            if !validatedGUI, !verdictStable {
                return (
                    RPCError(
                        code: RPCMethodError.notReadyCode,
                        message: "peer validation temporarily unavailable; retry shortly"
                    ),
                    nil
                )
            }
            return (RPCError(code: RPCMethodError.unauthorizedCode, message: "invalid sessionId or cap"), nil)
        }
    }

    private func handleAuthenticate(
        envelopeId: UInt32,
        body: RPCEnvelope.Body
    ) async -> RPCEnvelope {
        guard let validator = authValidator else {
            return errorEnvelope(
                envelopeId,
                RPCError(
                    code: RPCErrorCode.serverError,
                    message: "session.authenticate not configured on "
                        + "this daemon (no AuthValidator)"
                )
            )
        }
        let paramsJSON = Self.normalizeParams(body)
        let params: SessionAuthenticateParams
        do {
            params = try JSONDecoder()
                .decode(SessionAuthenticateParams.self, from: paramsJSON)
        } catch {
            return errorEnvelope(
                envelopeId,
                RPCError(
                    code: RPCMethodError.invalidParamsCode,
                    message: "session.authenticate params must include "
                        + "sessionId and cap"
                )
            )
        }
        guard let sessionId = UUID(uuidString: params.sessionId) else {
            return errorEnvelope(
                envelopeId,
                RPCError(
                    code: RPCMethodError.invalidParamsCode,
                    message: "sessionId must be a UUID string"
                )
            )
        }
        guard let capability = Capability(token: params.cap) else {
            return errorEnvelope(
                envelopeId,
                RPCError(
                    code: RPCMethodError.invalidParamsCode,
                    message: "cap must be base64-encoded bytes"
                )
            )
        }
        let state: SessionState
        do {
            state = try await validator(sessionId, capability)
        } catch {
            // A known session with a bad cap, or any non-session error, is a
            // hard `unauthorized`.
            guard let sessionError = error as? SessionError,
                case .notFound = sessionError else {
                return errorEnvelope(
                    envelopeId,
                    RPCError(
                        code: RPCMethodError.unauthorizedCode,
                        message: "invalid sessionId or cap"
                    )
                )
            }
            // Mirror the UDS barrier: while a fresh daemon awaits its restore
            // batch, an UNKNOWN session is retryable (`notReady`), so a GUI
            // session-scoped request racing ahead of restore doesn't prune a
            // still-valid credential.
            if let restorationGate, await restorationGate() == false {
                return errorEnvelope(
                    envelopeId,
                    RPCError(
                        code: RPCMethodError.notReadyCode,
                        message: "session not yet restored; retry shortly"
                    )
                )
            }
            // Barrier released. `restoreBatch` commits inserts before releasing
            // it, so a session a racing restore just inserted is visible now:
            // revalidate ONCE to close the validate/gate TOCTOU (no `-32001`
            // prune for a session restored in the gap). Still absent → gone.
            do {
                state = try await validator(sessionId, capability)
            } catch {
                return errorEnvelope(
                    envelopeId,
                    RPCError(
                        code: RPCMethodError.unauthorizedCode,
                        message: "invalid sessionId or cap"
                    )
                )
            }
        }
        // Provenance gate. An XPC peer's kernel identity is its audit token;
        // the owner triple `(pid, pidVersion, euid)` is derived from it. A
        // validated GUI peer authorizes for any session it created (it spans
        // sessions); a non-GUI XPC peer authorizes only as the exact owner of
        // the session it created. XPC has no terminal arm (a terminal caller
        // uses UDS), so the anchor is never consulted and the matcher never
        // returns `.notReady` here. A retryable `notReadyCode` can still come
        // from elsewhere: the lifecycle admission gate, a transient peer-
        // validation failure, or the restoration barrier below.
        let (validatedGUI, verdictStable) = await resolveGUIPeerVerdict()
        if let error = await provenanceError(
            for: sessionId,
            validatedGUI: validatedGUI,
            verdictStable: verdictStable
        ) {
            return errorEnvelope(envelopeId, error)
        }
        authenticatedSession = state
        do {
            let response = SessionAuthenticateResponse(
                success: true,
                role: state.role
            )
            let bytes = try JSONEncoder().encode(response)
            return RPCEnvelope(
                id: envelopeId,
                type: .response,
                method: nil,
                body: .result(bytes)
            )
        } catch {
            return errorEnvelope(
                envelopeId,
                RPCError(
                    code: RPCErrorCode.serverError,
                    message: "failed to encode authenticate response"
                )
            )
        }
    }

    private func errorEnvelope(
        _ envelopeId: UInt32,
        _ error: RPCError
    ) -> RPCEnvelope {
        RPCEnvelope(
            id: envelopeId,
            type: .response,
            method: nil,
            body: .error(error)
        )
    }

    private func runOneShot(
        envelopeId: UInt32,
        handler: MethodRegistry.Handler,
        body: RPCEnvelope.Body
    ) async -> RPCEnvelope {
        let paramsJSON = Self.normalizeParams(body)
        do {
            let resultBytes = try await handler(paramsJSON)
            return RPCEnvelope(
                id: envelopeId,
                type: .response,
                method: nil,
                body: .result(resultBytes)
            )
        } catch let methodError as RPCMethodError {
            return RPCEnvelope(
                id: envelopeId,
                type: .response,
                method: nil,
                body: .error(
                    RPCError(
                        code: methodError.code,
                        message: methodError.message
                    )
                )
            )
        } catch {
            return RPCEnvelope(
                id: envelopeId,
                type: .response,
                method: nil,
                body: .error(
                    RPCError(
                        code: RPCErrorCode.serverError,
                        message: String(describing: error)
                    )
                )
            )
        }
    }

    private func runSubscription(
        envelopeId: UInt32,
        method: String,
        scope: MethodScope,
        handler: MethodRegistry.SubscriptionHandler,
        body: RPCEnvelope.Body
    ) async {
        let paramsJSON = Self.normalizeParams(body)

        // For `pane.subscribe`, create the lifecycle + early record and
        // mint the side-band token before invoking the handler. The early
        // record is inserted synchronously (before any suspension) so a
        // drain that arrives *after* it always finds a record. A drain
        // that arrived *before* this record existed (per-callback Tasks
        // aren't FIFO) left a tombstone, applied here on creation. Either
        // way the record ends up `.terminal` and the post-handler inspect
        // tears it down.
        //
        // Registration happens only after ownership authorization: we no
        // longer parse the request's paneId or pre-register a surface hook
        // against it here, since the paneId is attacker-supplied and
        // unauthorized at this point. Instead we hand the handler a
        // *pane-agnostic* delivery capability on `context`; the coordinator
        // registers this exact token against the pane only after its
        // ownership gate authorizes it.
        var context: SubscriptionContext?
        if method == RPCMethod.paneSubscribe.rawValue,
            subscriptionRegistry != nil {
            let lifecycle = SubscriptionLifecycle()
            let token = UUID()
            var record = SubscriptionRecord(
                phase: .preStreaming,
                subscriptionToken: token,
                lifecycle: lifecycle
            )
            // Apply a drain that beat this record's insertion.
            if consumeDrainTombstone(envelopeId) {
                record.phase = .terminal
            }
            subscriptions[envelopeId] = record
            if case .terminal = record.phase {
                await lifecycle.fire(.drain)
            }
            context = SubscriptionContext(
                subscriptionToken: token,
                connectionId: id,
                lifecycle: lifecycle,
                surfaceDelivery: makeSurfaceDelivery()
            )
        }

        let result: MethodRegistry.SubscriptionResult
        do {
            result = try await handler(paramsJSON, context)
        } catch {
            // Handler threw. Fire the lifecycle drain (runs the producer
            // cleanup and the device pool teardown = unregister-if-unused
            // else drain), drop the surface-delivery entry + record, and
            // reply with the mapped error.
            if let lifecycle = context?.lifecycle {
                await lifecycle.fire(.drain)
            }
            await unregisterSurfaceDelivery(envelopeId: envelopeId)
            subscriptions.removeValue(forKey: envelopeId)
            sendEnvelope(errorEnvelope(envelopeId, mapSubscriptionError(error)))
            return
        }

        // Synchronously inspect the phase with NO intervening await: if a
        // drain/orphan fired during the handler, the record is already
        // `.terminal`; run the producer cleanup and create neither the
        // initial response nor the streaming task.
        if case .terminal? = subscriptions[envelopeId]?.phase {
            result.onCancel()
            await unregisterSurfaceDelivery(envelopeId: envelopeId)
            subscriptions.removeValue(forKey: envelopeId)
            return
        }
        if closed {
            // The connection closed while the handler ran. `close()` may
            // have enumerated `subscriptions` before this record was
            // inserted (inbound callbacks are independently scheduled), so
            // this subscription's lifecycle never received the orphan.
            // Orphan it now so its device token (and any replay grant) is
            // pinned rather than left active.
            if let lifecycle = subscriptions[envelopeId]?.lifecycle {
                await lifecycle.fire(.orphan)
            }
            result.onCancel()
            await unregisterSurfaceDelivery(envelopeId: envelopeId)
            subscriptions.removeValue(forKey: envelopeId)
            return
        }

        sendEnvelope(
            RPCEnvelope(
                id: envelopeId,
                type: .response,
                method: nil,
                body: .result(result.initialResult)
            )
        )

        let events = result.events
        let onCancel = result.onCancel
        let task = Task { [weak self] in
            await withTaskCancellationHandler {
                for await event in events {
                    if Task.isCancelled { break }
                    await self?.sendSubscriptionEvent(
                        envelopeId: envelopeId,
                        event: event
                    )
                }
            } onCancel: {
                onCancel()
            }
            // Natural completion: the producer's events stream finished
            // (e.g. PaneCoordinator.close(paneId:) ran). Drop the
            // surface-delivery entry so future surface callbacks don't
            // ship to a dead subscription, and remove the record.
            await self?.unregisterSurfaceDelivery(envelopeId: envelopeId)
            await self?.subscriptionFinished(envelopeId: envelopeId)
        }
        // Advance the early record to `streaming`, preserving its token +
        // lifecycle. A non-pane subscription had no early record, so
        // create one now.
        if var record = subscriptions[envelopeId] {
            record.phase = .streaming(task)
            subscriptions[envelopeId] = record
        } else {
            subscriptions[envelopeId] = SubscriptionRecord(
                phase: .streaming(task),
                subscriptionToken: nil,
                lifecycle: nil
            )
        }
    }

    /// Intercept a `pane.surfaceDrain` notification: resolve its
    /// `subscribeRequestId` to the subscription record and branch by
    /// phase: `preStreaming` marks the record terminal so the
    /// post-handler inspect bails; `streaming` cancels the drain task
    /// (which unregisters and removes the record). If no record exists
    /// yet (a drain whose Task beat the subscribe's), remember a
    /// tombstone the record's creation will apply.
    ///
    /// The phase decision is committed **synchronously, before** the
    /// `lifecycle.fire` await: subscription setup runs on this same actor
    /// and would otherwise be free to advance past the drain (create the
    /// streaming task, send the response) while `fire` is suspended.
    private func handleSurfaceDrainNotification(body: RPCEnvelope.Body) async {
        let bytes = Self.normalizeParams(body)
        guard let params = try? JSONDecoder().decode(SurfaceDrainParams.self, from: bytes) else {
            return
        }
        let requestId = params.subscribeRequestId
        guard let record = subscriptions[requestId] else {
            recordDrainTombstone(requestId)
            return
        }
        switch record.phase {
        case .preStreaming:
            var updated = record
            updated.phase = .terminal
            subscriptions[requestId] = updated

        case let .streaming(task):
            task.cancel()

        case .terminal:
            break
        }
        if let lifecycle = record.lifecycle {
            await lifecycle.fire(.drain)
        }
    }

    /// Remember a drain that arrived before its subscription's record.
    /// Prunes aged entries and enforces a hard cap so a drain that never
    /// matches a subscribe can't accumulate.
    private func recordDrainTombstone(_ requestId: UInt32) {
        pruneDrainTombstones()
        drainTombstones[requestId] = Date()
        if drainTombstones.count > Self.drainTombstoneCap,
            let oldest = drainTombstones.min(by: { $0.value < $1.value })?.key {
            drainTombstones.removeValue(forKey: oldest)
        }
    }

    /// Consume a tombstone for `requestId`, if a drain beat its record.
    private func consumeDrainTombstone(_ requestId: UInt32) -> Bool {
        pruneDrainTombstones()
        return drainTombstones.removeValue(forKey: requestId) != nil
    }

    private func pruneDrainTombstones() {
        let cutoff = Date().addingTimeInterval(-Self.drainTombstoneTTL)
        drainTombstones = drainTombstones.filter { $0.value >= cutoff }
    }

    /// Map a subscription-handler error to its wire error.
    private func mapSubscriptionError(_ error: Error) -> RPCError {
        if let methodError = error as? RPCMethodError {
            return RPCError(code: methodError.code, message: methodError.message)
        }
        return RPCError(
            code: RPCErrorCode.serverError,
            message: String(describing: error)
        )
    }

    /// Drop the surface-delivery registry entry for a subscription's
    /// token, if it has one. Idempotent.
    private func unregisterSurfaceDelivery(envelopeId: UInt32) async {
        guard let token = subscriptions[envelopeId]?.subscriptionToken else { return }
        await subscriptionRegistry?.unregister(subscriptionId: token)
    }

    private func sendSubscriptionEvent(
        envelopeId: UInt32,
        event: MethodRegistry.SubscriptionEvent
    ) {
        sendEnvelope(
            RPCEnvelope(
                id: envelopeId,
                type: .event,
                method: event.method,
                body: .params(event.params)
            )
        )
    }

    private func subscriptionFinished(envelopeId: UInt32) {
        subscriptions.removeValue(forKey: envelopeId)
    }

    // MARK: - Send

    private func sendEnvelope(_ envelope: RPCEnvelope) {
        guard !closed else { return }
        let payload: Data
        do {
            payload = try envelope.encode()
        } catch {
            return
        }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(
            message,
            XPCTransportKey.type,
            XPCTransportKey.rpcValue
        )
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            xpc_dictionary_set_data(
                message,
                XPCTransportKey.data,
                baseAddress,
                payload.count
            )
        }
        xpc_connection_send_message(peer, message)
    }

    private func sendErrorReply(envelopeId: UInt32, error: RPCError) {
        sendEnvelope(errorEnvelope(envelopeId, error))
    }

    // MARK: - Helpers

    /// Build this connection's **pane-agnostic** surface-delivery closure.
    /// It marshals a `SurfaceSendInfo` into an `xpc_object_t` and ships it
    /// on this connection's `peer`, reading the paneId/token/lease overlay
    /// from the `info`: it names no pane of its own, so handing it to the
    /// coordinator confers the *ability* to deliver without asserting
    /// *which* pane. The coordinator registers it against the authorized
    /// pane inside `subscribe`, only after its ownership gate authorizes.
    /// The handle holds the
    /// `RetainedSurface` for the duration of the marshal + send so the
    /// use-count pairing stays valid; libxpc copies the surface object
    /// payload before the call returns.
    private func makeSurfaceDelivery() -> PaneSubscriptionRegistry.SurfaceDelivery {
        let peer = self.peer
        return { info in
            info.surface.withRef { ref in
                let payload = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_string(
                    payload,
                    XPCTransportKey.type,
                    "surface"
                )
                xpc_dictionary_set_string(payload, "paneId", info.paneId.uuidString)
                xpc_dictionary_set_uint64(payload, "sequence", info.sequence)
                // Correlation token (every XPC pane subscription) + device lease
                // overlay (`leased`/`leaseEpoch`): the GUI keys its pending
                // pair table by the token and, when leased, takes a lease it
                // acks against `leaseEpoch`.
                xpc_dictionary_set_string(
                    payload,
                    "subscriptionToken",
                    info.subscriptionToken.uuidString
                )
                xpc_dictionary_set_bool(payload, "leased", info.leased)
                xpc_dictionary_set_uint64(payload, "leaseEpoch", info.leaseEpoch)
                let surfaceXPC = IOSurfaceCreateXPCObject(ref)
                xpc_dictionary_set_value(payload, "surface", surfaceXPC)
                xpc_connection_send_message(peer, payload)
            }
        }
    }

    /// Read a `data` field out of an XPC dictionary into a Swift
    /// `Data`. Returns nil if the key is missing or the field
    /// isn't a data blob.
    private func readDataField(
        _ dictionary: xpc_object_t,
        key: String
    ) -> Data? {
        var length: Int = 0
        guard
            let pointer = xpc_dictionary_get_data(dictionary, key, &length),
            length > 0
        else {
            return nil
        }
        let buffer = UnsafeBufferPointer(
            start: pointer.assumingMemoryBound(to: UInt8.self),
            count: length
        )
        return Data(buffer)
    }
}
