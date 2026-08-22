// SPDX-License-Identifier: GPL-3.0-or-later
//
// RPCConnection: per-client actor that owns one accepted UDS fd.
//
// Each accepted client gets one of these. The actor encapsulates:
//
//   - The connection fd (shut down on close, then released after the read
//     source cancels and the active write finishes).
//   - A serial `DispatchSourceRead` that fires when the fd has bytes
//     to drain.
//   - A `Data` accumulator for partially-received frames.
//   - The method registry shared with the server.
//   - A map of in-flight subscriptions, keyed by the original
//     request `id` (events sent for a subscription reuse that id so
//     the client can correlate the stream back to its request).
//
// All state mutation runs inside the actor; the dispatch source's
// event handler dispatches into the actor via a `Task { await … }`
// so concurrent read events serialize cleanly on the actor's
// executor.

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Standard JSON-RPC-ish error codes for daemon-side responses.
public enum RPCErrorCode {
    /// Method requested isn't in the registry.
    public static let methodNotFound = -32_601
    /// Caller's payload was syntactically invalid JSON / frame.
    public static let invalidRequest = -32_600
    /// Method handler threw an arbitrary error not otherwise typed.
    public static let serverError = -32_000
}

/// Validates `(sessionId, capability)` against the session manager.
/// Lives as a closure so `RPCConnection` doesn't have to import or
/// hold a reference to `SessionManager` directly. `RPCServer`
/// provides the closure at connection-init time. Throws on
/// invalid creds; returns the matching `SessionState` on success.
public typealias AuthValidator = @Sendable (
    _ sessionId: UUID,
    _ capability: Capability
) async throws -> SessionState

/// Reports whether the daemon's session-restoration barrier has been released.
/// While it returns false (a fresh daemon still awaiting its validated-GUI
/// restore batch), an `session.authenticate` for an UNKNOWN session is
/// reclassified from the hard `unauthorized` (-32001) to the retryable
/// `notReady` (-32002), so an in-tab CLI/shim keeps its bounded retry instead
/// of pruning a still-valid credential. Nil disables the reclassification
/// (tests / a server not gated on restoration), preserving the plain
/// unknown → unauthorized behavior.
public typealias RestorationGate = @Sendable () async -> Bool

/// Whether a session id is admissible right now, and (when it is) the live
/// incarnation the request is authorized under. `.ready(incarnation:)` admits
/// the session; a `nil` incarnation means "admissible, unpinned" for a manager
/// that tracks no incarnation or for a test lookup. `.notReady` blocks with the
/// retryable code while the id is mid-registration or mid-teardown.
/// `.absent` means the id is gone (terminal). Derived from
/// `SessionManager.admission(for:)`.
public enum SessionAdmission: Sendable, Equatable {
    case ready(incarnation: UInt64?)
    case notReady
    case absent
}

/// A per-request provenance snapshot for a session: its captured owner, its
/// current terminal anchor, and its lifecycle admission. Returned by
/// `SessionProvenanceLookup` and fed to the `ProvenanceMatcher`. Keeping them
/// together means the authenticate gate and per-request scope re-check share
/// one lookup. `admission` gates a request *before* the provenance verdict:
/// a `.notReady` id is retryable regardless of provenance, and a `.ready`
/// id's incarnation rides into the principal so a parked request can't pass a
/// later incarnation's producer gate. Defaults to `.ready(incarnation: nil)`
/// so a synthetic test snapshot is admissible and un-pinned unless it says
/// otherwise.
public struct SessionProvenanceSnapshot: Sendable, Equatable {
    public let owner: OwnerProcessIdentity?
    public let anchor: TerminalAnchor?
    public let admission: SessionAdmission

    public init(
        owner: OwnerProcessIdentity?,
        anchor: TerminalAnchor?,
        admission: SessionAdmission = .ready(incarnation: nil)
    ) {
        self.owner = owner
        self.anchor = anchor
        self.admission = admission
    }
}

/// Resolves a session's current provenance inputs, or nil when the session is
/// no longer live (closed or never existed). Injected so a connection can run
/// the provenance check both at `session.authenticate` AND before every scoped
/// request: a valid cap on a live session is necessary but not sufficient; the
/// peer's kernel identity must still match the session's owner or its bound
/// terminal, re-derived from the CURRENT store state. Because authentication
/// caches only a claim, this per-request re-check is what makes closing a
/// session or revoking its terminal anchor invalidate an already-authenticated
/// socket. Production wires it to `SessionManager.session(id:)` +
/// `TerminalAnchorStore.anchor(for:)`; a nil lookup disables the re-check (for
/// tests that don't exercise provenance).
public typealias SessionProvenanceLookup =
    @Sendable (_ sessionId: UUID) async -> SessionProvenanceSnapshot?

actor RPCConnection {
    /// Tracks an in-flight server-streamed subscription. The `task`
    /// is the drain loop reading from the producer's `events` stream
    /// and writing `.event` envelopes to the wire; cancelling it
    /// fires `withTaskCancellationHandler { ... } onCancel:` which
    /// calls the producer's `onCancel` so it can release resources.
    private struct SubscriptionRecord {
        let task: Task<Void, Never>
    }

    /// One frame waiting for the connection's writer pump. The continuation
    /// keeps `send`'s established contract: it returns only after the frame was
    /// written or the connection failed.
    private struct PendingWrite {
        let frame: Data
        let completion: CheckedContinuation<Bool, Never>
    }

    /// Bound frames retained behind a peer that has stopped reading. One
    /// oversized frame is admitted into an empty pending queue so a legitimate
    /// response up to `RPCFraming.defaultPayloadCap` can still be delivered;
    /// no additional frame joins it.
    private static let maximumPendingWriteCount = 64
    private static let maximumPendingWriteBytes = 1 * 1_024 * 1_024

    private let id: UInt64
    private let fd: Int32
    private let methods: MethodRegistry
    private let authValidator: AuthValidator?
    private let sessionProvenanceLookup: SessionProvenanceLookup?
    /// See `RestorationGate`. Nil means "always treat restoration as complete."
    private let restorationGate: RestorationGate?
    /// The kernel-established identity of this UDS peer (`LOCAL_PEERTOKEN` →
    /// pid/pidVersion/euid, POSIX session, controlling tty, session-leader
    /// start), resolved once at init from the accepted fd. `nil` when the
    /// kernel couldn't vend it (a non-socket fd, or a peer that closed before
    /// we asked). This is the UDS caller's PROVENANCE: `session.authenticate`
    /// and the per-request scope re-check match it against the session's owner
    /// or bound terminal (`ProvenanceMatcher`) before installing a principal.
    /// `nil` fails closed.
    private let peerProcess: PeerProcessIdentity?
    /// Resolves the caller's provenance fresh for each scoped request: hop zero
    /// re-read from the socket's audit token, plus the verified ancestor prefix
    /// above it. Deliberately NOT cached alongside `peerProcess`, because the
    /// ancestry arm's authority is the *live* chain: a harness can be orphaned
    /// while this connection stays open, and the next request has to see that.
    nonisolated private let provenanceSnapshotResolver: ProvenanceSnapshotResolver
    /// The live automation-grant store the `.automationTab` scope check
    /// reads on every request (the same instance the validated GUI grants into
    /// and the session close revokes from). `nil` disables the check; a
    /// granted session then can't reach the automation surface over this
    /// connection (fail closed).
    private let automationGrantStore: AutomationGrantStore?
    private weak var server: RPCServer?
    nonisolated private let ioQueue: DispatchQueue
    nonisolated private let writeQueue: BlockingWorkQueue
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    /// Dispatch read events may enqueue several actor tasks while a response
    /// write suspends. Only one task may drain frames; otherwise actor
    /// reentrancy defeats socket backpressure and pipelines more work.
    private var readPumpRunning = false
    private var readPumpRequested = false
    private var pendingWrites: [PendingWrite] = []
    private var pendingWriteBytes = 0
    private var writerPumpRunning = false
    private var subscriptions: [UInt32: SubscriptionRecord] = [:]
    private var closed: Bool = false
    /// The session this connection authenticated as, if any. Set by
    /// a successful `session.authenticate` frame; consulted by the
    /// pre-dispatch scope check for every subsequent method. Stays
    /// nil for connections that never authenticated (out-of-tab
    /// callers, the GUI's pre-create probes); those connections can
    /// only invoke `.daemonWide`-tagged methods.
    private var authenticatedSession: SessionState?

    init(
        id: UInt64,
        fd: Int32,
        methods: MethodRegistry,
        server: RPCServer,
        authValidator: AuthValidator? = nil,
        sessionProvenanceLookup: SessionProvenanceLookup? = nil,
        restorationGate: RestorationGate? = nil,
        automationGrantStore: AutomationGrantStore? = nil,
        peerIdentityResolver: @escaping PeerIdentityResolver = defaultPeerIdentityResolver,
        provenanceSnapshotResolver: ProvenanceSnapshotResolver? = nil
    ) {
        self.id = id
        self.fd = fd
        self.methods = methods
        self.authValidator = authValidator
        self.sessionProvenanceLookup = sessionProvenanceLookup
        self.restorationGate = restorationGate
        self.automationGrantStore = automationGrantStore
        // Resolve the peer identity once, now, while the fd is freshly
        // accepted and the peer is still connected. This caches the
        // token-validated identity of the process that established the
        // connection: `resolve` binds the SID/TTY facts to the peer's
        // audit-token `(pid, pidVersion)` generation, so a later pid reuse
        // can't retroactively change what this connection authenticated as.
        self.peerProcess = peerIdentityResolver(fd)
        // Default the request-time resolver by COMPOSING it over the same peer
        // resolver, so whatever governs hop zero at accept still governs it per
        // request. A second, independent seam defaulting to the real
        // `LOCAL_PEERTOKEN` read would leave every synthetic-peer harness
        // resolving a loopback fd for real.
        self.provenanceSnapshotResolver = provenanceSnapshotResolver
            ?? composedProvenanceSnapshotResolver(peer: peerIdentityResolver)
        self.server = server
        self.ioQueue = DispatchQueue(label: "deviceterm.daemon.conn.\(id)")
        self.writeQueue = BlockingWorkQueue(label: "deviceterm.daemon.conn-write.\(id)")
    }

    // Hand handlers a parseable JSON object when the request had no
    // body, so methods whose Params type has all-optional fields can
    // use a uniform `JSONDecoder().decode(...)` rather than each
    // handler special-casing empty Data.
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

    /// Begin reading from the fd. Idempotent: calling twice is a
    /// no-op because the read source is only constructed once.
    func start() {
        guard readSource == nil, !closed else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.handleReadable()
            }
        }
        let fdCopy = fd
        let writer = writeQueue
        source.setCancelHandler {
            // Dispatch source cancellation drains its event handler first.
            // Enqueueing close from here, behind the active blocking write,
            // prevents both the read source and an old writer from observing a
            // descriptor number the kernel has already reused.
            writer.submit {
                Darwin.close(fdCopy)
            }
        }
        source.resume()
        readSource = source
    }

    /// Close the connection. Cancels every in-flight subscription
    /// (their `onCancel` closures release per-subscription resources
    /// via `withTaskCancellationHandler`), shuts down the fd, cancels the read
    /// source, and asks the server to drop us from its connections map. The read
    /// source's cancellation handler closes the fd at the tail of `writeQueue`,
    /// after its event handler and any active write have finished, so descriptor
    /// reuse cannot redirect old connection work. Idempotent.
    func close() {
        guard !closed else { return }
        closed = true
        for (_, record) in subscriptions {
            record.task.cancel()
        }
        subscriptions.removeAll()
        failPendingWrites()
        Darwin.shutdown(fd, SHUT_RDWR)
        if let readSource {
            readSource.cancel()
        } else {
            // A connection can be closed before `start()` installs its read
            // source. There is then no cancellation handler to own the close.
            let fdCopy = fd
            writeQueue.submit {
                Darwin.close(fdCopy)
            }
        }
        readSource = nil
        Task { [weak server, id] in
            await server?.removeConnection(id: id)
        }
    }

    // MARK: - Read path

    private func handleReadable() async {
        guard !closed else { return }
        if readPumpRunning {
            readPumpRequested = true
            return
        }
        readPumpRunning = true
        defer { readPumpRunning = false }
        do {
            repeat {
                readPumpRequested = false
                guard let chunk = try UDSSocket.readAvailable(fd: fd) else {
                    // Peer closed cleanly.
                    close()
                    return
                }
                guard !chunk.isEmpty else { continue }
                readBuffer.append(chunk)
                try await drainFrames()
                // A response write can suspend while more socket data arrives.
                // Loop once more even if Dispatch coalesced that readiness
                // notification into a task that only set `readPumpRequested`.
            } while !closed && readPumpRequested
        } catch {
            // Any I/O or framing fault closes the connection. Future
            // chunks can split "transient framing error → send error
            // response" from "fatal I/O error → close" if we observe
            // wire-corruption recovery being useful.
            close()
        }
    }

    /// Drain as many complete frames as the buffer holds, dispatching
    /// each. Stops when the next frame is incomplete.
    private func drainFrames() async throws {
        while let parse = try RPCFraming.decodeNext(from: readBuffer) {
            let bufferEnd = readBuffer.endIndex
            let dropEnd = readBuffer.index(readBuffer.startIndex, offsetBy: parse.consumed)
            readBuffer = Data(readBuffer[dropEnd..<bufferEnd])
            await dispatch(payloadJSON: parse.payload)
        }
    }

    // MARK: - Dispatch

    private func dispatch(payloadJSON: Data) async {
        let envelope: RPCEnvelope
        do {
            envelope = try RPCEnvelope.decode(payloadJSON)
        } catch {
            // Malformed envelope: we don't know the id, so there's
            // nothing meaningful to respond with. Drop the frame.
            return
        }

        // Only requests get responses. Events and responses arriving
        // from a client are not part of the contract (the client is
        // the one issuing requests); silently ignore.
        guard envelope.type == .request else { return }
        guard let method = envelope.method else {
            // No method, so nothing to run. Reply only if there's an id
            // to correlate the error on; a method-less notification is
            // simply dropped.
            if let id = envelope.id {
                await send(
                    errorResponse: RPCError(
                    code: RPCErrorCode.invalidRequest,
                    message: "Request envelope missing `method`"
                ),
                    correlatingId: id
                    )
            }
            return
        }

        // A request with no `id` is a one-way notification: run it
        // fire-and-forget and send nothing back (no correlation key to
        // reply on). The surface-lease notifications (the release ack and
        // the drain teardown) ride this shape.
        guard let envelopeId = envelope.id else {
            await dispatchNotification(method: method, body: envelope.body)
            return
        }

        // `session.authenticate` is intercepted by the dispatcher
        // rather than handled through MethodRegistry, because it
        // mutates per-connection state (the authenticated session)
        // that handlers can't see. Tagged `.daemonWide` so out-of-
        // tab callers see it in `daemon.capabilities`; the
        // intercept path is the actual implementation.
        if method == RPCMethod.sessionAuthenticate.rawValue {
            let response = await handleAuthenticate(
                envelopeId: envelopeId,
                body: envelope.body
            )
            await send(envelope: response)
            return
        }

        guard let resolved = methods.lookup(method) else {
            await send(
                envelope: RPCEnvelope(
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

        // Pre-dispatch scope check. Connection-layer auth means the
        // CLI never threads creds in individual call params; the
        // dispatcher reads the connection's auth state. Three rules:
        //   - `.daemonWide` → proceed regardless of auth.
        //   - `.session` → require authenticatedSession != nil.
        //   - `.automationTab` → require an authenticated session that
        //     currently holds a live automation grant (the validated GUI
        //     minted it; provenance was re-checked above); see `scopeCheck`.
        //   - `.validatedGUI` → hard reject. No UDS peer carries an audit
        //     token to validate against the daemon's signature.
        // Snapshot the authenticated session ONCE, before the scope check's
        // `await` (which re-validates provenance). `scopeCheck` and the
        // handler context below all read this one snapshot, never the mutable
        // `authenticatedSession` property again, so a concurrent
        // `session.authenticate` racing in during the scope-check suspension
        // (actor reentrancy) can't scope-check under one identity while the
        // request is attributed or dispatched under another.
        let session = authenticatedSession
        // Re-validate the snapshotted session's provenance ONCE, whatever the
        // scope. A revoked session or terminal anchor invalidates the cached
        // principal even for `.daemonWide` handlers: `daemon.capabilities` (and
        // any other origin-aware daemon-wide handler) must not advertise or
        // resolve using a stale identity. An invalid result downgrades the
        // effective session to nil; the handler runs unauthenticated rather
        // than as a ghost of the closed session. The resolved incarnation rides
        // into the principal (below) so a parked request can't pass a later
        // incarnation's producer gate.
        let provenanceReject: RPCError?
        let sessionIncarnation: UInt64?
        if let session {
            let resolved = await resolveSession(for: session.id)
            provenanceReject = resolved.error
            sessionIncarnation = resolved.incarnation
        } else {
            provenanceReject = nil
            sessionIncarnation = nil
        }
        let effectiveSession = provenanceReject == nil ? session : nil
        let scope = methods.scope(of: method) ?? .daemonWide
        if let scopeError = await scopeCheck(
            scope: scope,
            session: effectiveSession,
            invalidationError: provenanceReject
        ) {
            await send(
                envelope: RPCEnvelope(
                id: envelopeId,
                type: .response,
                method: nil,
                body: .error(scopeError)
            )
                )
            return
        }

        // Bind per-call caller identity for the handler. Two
        // task-locals carry it:
        //   - `SessionDispatchContext.originatingSessionId`:
        //     legacy; the existing readers
        //     (`AppCommandMethods.publishVerb`, `SessionMethods`)
        //     still consult it.
        //   - `DispatchPeerContext.current`: the broader caller-
        //     identity record. Carries transport, connectionId,
        //     and the authenticated session. New readers (the
        //     automation-mint gate, role-aware capabilities)
        //     consult
        //     this. UDS dispatch sets `transport: .uds` and
        //     `auditToken: nil`; the XPC dispatcher will bind the
        //     same task-local with `transport: .xpc` and the
        //     peer's captured audit token.
        // Daemon-wide calls still see a context (with `authenticatedSession`
        // nil), so handlers always get a non-nil current.
        let originatingSid = effectiveSession?.id.uuidString
        let peerContext = DispatchPeerContext(
            transport: .uds,
            connectionId: id,
            auditToken: nil,
            authenticatedSession: effectiveSession,
            peerProcess: peerProcess,
            sessionIncarnation: effectiveSession == nil ? nil : sessionIncarnation
        )
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
            await send(envelope: response)

        case let .subscription(handler):
            await SessionDispatchContext.$originatingSessionId
                .withValue(originatingSid) {
                    await DispatchPeerContext.$current
                        .withValue(peerContext) {
                            await runSubscription(
                                envelopeId: envelopeId,
                                method: method,
                                handler: handler,
                                body: envelope.body
                            )
                        }
                }
        }
    }

    /// Dispatch a one-way notification (a request that arrived with no
    /// `id`). Runs the resolved one-shot handler fire-and-forget under
    /// the peer context and discards its result, since there is no
    /// correlation key to reply on. A missing method, a subscription
    /// method, or a failed scope check drops silently. The surface-lease
    /// acks (`pane.surfaceRelease`) reach the daemon this way; over UDS
    /// they have no registered token, so the pool's connection-authority
    /// check makes them a counted no-op.
    private func dispatchNotification(method: String, body: RPCEnvelope.Body) async {
        guard case let .oneShot(handler) = methods.lookup(method) else { return }
        // Snapshot once and re-validate provenance with the same fences as `dispatch`.
        let session = authenticatedSession
        let provenanceReject: RPCError?
        let sessionIncarnation: UInt64?
        if let session {
            let resolved = await resolveSession(for: session.id)
            provenanceReject = resolved.error
            sessionIncarnation = resolved.incarnation
        } else {
            provenanceReject = nil
            sessionIncarnation = nil
        }
        let effectiveSession = provenanceReject == nil ? session : nil
        let scope = methods.scope(of: method) ?? .daemonWide
        if await scopeCheck(scope: scope, session: effectiveSession, invalidationError: provenanceReject) != nil {
            return
        }
        let peerContext = DispatchPeerContext(
            transport: .uds,
            connectionId: id,
            auditToken: nil,
            authenticatedSession: effectiveSession,
            peerProcess: peerProcess,
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

    /// Validates that the connection's auth state permits a call to
    /// a method of the given `scope`. Returns nil when the call may
    /// proceed; returns a populated `RPCError` for the caller to
    /// send back when not.
    ///
    /// UDS connections can never reach `.validatedGUI`; a UDS peer carries no
    /// audit token, so it can't validate against the daemon's own signature.
    /// `.automationTab` IS reachable over UDS, but only for a session holding
    /// a **live automation grant**: the grant was minted by the validated
    /// GUI for this exact session, and the session's kernel terminal-process
    /// provenance was already proved at `session.authenticate` and re-checked
    /// once in `dispatch` (a revoked session/anchor arrives here as a nil
    /// `session`). So cap + provenance + live grant, not a role, is the
    /// authority: the same live-grant test the XPC dispatcher applies.
    /// Scope-check against the ALREADY-provenance-validated effective session
    /// (`session` is nil when the connection never authenticated OR its cached
    /// principal just failed re-validation; `invalidationError` carries the
    /// specific reason in the latter case). The provenance re-check itself runs
    /// once in `dispatch`, so this is pure policy over the resolved identity.
    /// `async` only to read live grant state for the `.automationTab` arm
    /// against the already-fixed session id; no other identity input is re-read.
    private func scopeCheck(
        scope: MethodScope,
        session: SessionState?,
        invalidationError: RPCError?
    ) async -> RPCError? {
        switch scope {
        case .daemonWide:
            // Daemon-wide methods run regardless, but with the effective
            // (possibly-downgraded) session, so an origin-aware handler sees no
            // stale principal.
            return nil

        case .session:
            guard session != nil else {
                // Either never authenticated, or the cached principal just
                // failed re-validation (revoked session / anchor). Surface the
                // specific retryable/hard reason when we have it.
                return invalidationError ?? RPCError(
                    code: RPCMethodError.unauthorizedCode,
                    message: "session-scoped method requires an "
                        + "authenticated connection; call "
                        + "session.authenticate first"
                )
            }
            return nil

        case .automationTab:
            // Authority is a LIVE automation grant, not a role; the same
            // test the XPC dispatcher applies. The session already passed the
            // per-request provenance re-check in `dispatch` (a revoked session
            // or lost terminal anchor arrives as a nil `session`), so the only
            // remaining question is whether the validated GUI currently grants
            // it. No audit token: UDS carries none, and the grant plus the
            // provenance-checked identity are the authority.
            guard let session else {
                return invalidationError ?? RPCError(
                    code: RPCMethodError.unauthorizedCode,
                    message: "automation-scoped method requires an "
                        + "authenticated connection; call "
                        + "session.authenticate first"
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
            // No UDS peer validates against the daemon's signature, so
            // `.validatedGUI` is unreachable over UDS by construction.
            return RPCError(
                code: RPCMethodError.scopeViolationCode,
                message: "validated-GUI-scoped methods are not available "
                    + "over UDS; use the deviceterm GUI"
            )
        }
    }

    /// Run the provenance matcher for `sessionId` against the CURRENT store
    /// snapshot and map the verdict to an `RPCError` (nil = authorized). Shared
    /// by `session.authenticate` (first admission) and the per-request scope
    /// re-check (revocation). A nil `sessionProvenanceLookup` disables the
    /// check (tests that don't exercise provenance); a nil snapshot means the
    /// session is no longer live and fails closed.
    private func provenanceError(for sessionId: UUID) async -> RPCError? {
        await resolveSession(for: sessionId).error
    }

    /// Resolve a session's admission: the lifecycle-phase gate first (a
    /// `.notReady` id is retryable regardless of provenance), then the
    /// provenance matcher over the CURRENT store snapshot. Returns `(nil,
    /// incarnation)` when authorized; the incarnation rides into the principal
    /// so a request authorized under one incarnation can't pass a later
    /// incarnation's producer gate, and `(error, nil)` otherwise. A nil lookup
    /// fails closed when a validator is configured (a wiring bug); a nil
    /// snapshot means the session is gone.
    private func resolveSession(for sessionId: UUID) async -> (error: RPCError?, incarnation: UInt64?) {
        guard let lookup = sessionProvenanceLookup else {
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
        switch ProvenanceMatcher.verdict(
            peer: currentProvenancePeer(),
            sessionOwner: snapshot.owner,
            anchor: snapshot.anchor?.facts
        ) {
        case .authorized:
            return (nil, incarnation)

        case .notReady:
            return (
                RPCError(code: RPCMethodError.notReadyCode, message: "session terminal not yet bound; retry shortly"),
                nil
            )

        case .unauthorized:
            return (RPCError(code: RPCMethodError.unauthorizedCode, message: "invalid sessionId or cap"), nil)
        }
    }

    /// This connection's provenance as of right now: hop zero re-resolved from
    /// the socket, plus the ancestor prefix above it. Resolved per call rather
    /// than read from `peerProcess`, because the ancestry arm's authority is
    /// the live chain and a cached one would let an orphaned harness keep
    /// authority for the life of its connection.
    ///
    /// The fresh peer must still be the process this connection was accepted
    /// from. A `(pid, pidVersion)` that moved means the fd no longer names the
    /// process we authenticated, so it fails closed rather than authorizing a
    /// stranger. An unresolvable peer is `.missing` for the same reason; only a
    /// failed *walk* is survivable, and that arrives as an empty prefix.
    private func currentProvenancePeer() -> ProvenancePeer {
        guard let accepted = peerProcess else { return .missing }
        guard let snapshot = provenanceSnapshotResolver(fd) else { return .missing }
        guard snapshot.peer.pid == accepted.pid,
            snapshot.peer.pidVersion == accepted.pidVersion
        else {
            return .missing
        }
        return .uds(snapshot.peer, ancestors: snapshot.ancestors)
    }

    /// Handle a `session.authenticate` request. Decodes the
    /// `(sessionId, cap)` params, validates via the injected
    /// `authValidator`, stores the resulting `SessionState` on the
    /// connection, and returns `{ok: true, role}`. Failure → wire-
    /// level `error.unauthorized`. Re-authentication on an already-
    /// auth'd connection replaces the prior state (last-write-wins).
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
            // A KNOWN session with a bad cap (`.invalidCapability`), or any
            // non-session error, is always a hard `unauthorized`.
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
            // Unknown session. While a fresh daemon still awaits its
            // validated-GUI restore batch, this is not yet a hard failure.
            // Return the retryable `notReady` so an in-tab CLI/shim keeps its
            // bounded retry instead of pruning a still-valid credential.
            if let restorationGate, await restorationGate() == false {
                return errorEnvelope(
                    envelopeId,
                    RPCError(
                        code: RPCMethodError.notReadyCode,
                        message: "session not yet restored; retry shortly"
                    )
                )
            }
            // Barrier released (or ungated). Because `restoreBatch` commits its
            // inserts BEFORE releasing the barrier, observing "released" means a
            // session a racing restore just inserted is already visible, so
            // revalidate ONCE to close the validate/gate TOCTOU. This stops a
            // `-32001` (credential prune) for a session restored between the
            // first validate and the gate read. Still absent → genuinely gone.
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
        // Provenance gate. A valid capability on a live session is necessary
        // but not sufficient: the cap is readable by any same-uid process (it
        // rides inherited env, recoverable via `ps -E`). A UDS peer authorizes
        // only when its kernel identity matches the session's captured owner or
        // its bound terminal. `.missing` (the kernel couldn't name the peer)
        // fails closed; `.notReady` (a live session whose terminal has not been
        // bound yet, for example right after a restart) is a distinct, retryable
        // code so the CLI briefly re-tries rather than failing outright.
        if let error = await provenanceError(for: sessionId) {
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

    /// Compact factory for the wire-level error envelope shape.
    /// Kept private + close to the auth handler since both error
    /// branches need it; lifting to a top-level helper would
    /// dilute the surface for one consumer.
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
        handler: MethodRegistry.SubscriptionHandler,
        body: RPCEnvelope.Body
    ) async {
        let paramsJSON = Self.normalizeParams(body)
        let result: MethodRegistry.SubscriptionResult
        do {
            // UDS vends no surface lane, so it mints no token and passes a
            // nil subscription context; only the producer-side
            // `onCancel` teardown applies.
            result = try await handler(paramsJSON, nil)
        } catch let methodError as RPCMethodError {
            let errorResponse = RPCError(
                code: methodError.code,
                message: methodError.message
            )
            await send(
                envelope: RPCEnvelope(
                id: envelopeId,
                type: .response,
                method: nil,
                body: .error(errorResponse)
            )
                )
            return
        } catch {
            let errorResponse = RPCError(
                code: RPCErrorCode.serverError,
                message: String(describing: error)
            )
            await send(
                envelope: RPCEnvelope(
                id: envelopeId,
                type: .response,
                method: nil,
                body: .error(errorResponse)
            )
                )
            return
        }

        // Confirm the subscription is live before any events flow.
        await send(
            envelope: RPCEnvelope(
            id: envelopeId,
            type: .response,
            method: nil,
            body: .result(result.initialResult)
        )
            )
        // If the initial-ack send failed (client disconnected after
        // the handler allocated subscription resources but before we
        // could acknowledge), `send` already called `close()` and
        // cleared the subscriptions map. Registering the drain task
        // now would leak: close ran while our entry was missing, so
        // task.cancel() / onCancel will never fire. Run onCancel
        // ourselves and bail out before the producer's resources
        // pile up.
        if closed {
            result.onCancel()
            return
        }

        // Spin a drain task that reads events from the producer and
        // sends each as a same-id `.event` envelope. The
        // `withTaskCancellationHandler` arrangement means cancelling
        // the task (via `close()`) synchronously runs the producer's
        // `onCancel`. That closure is the producer's hook to finish
        // its event stream so the `for await` here actually exits
        // instead of awaiting forever.
        let events = result.events
        let onCancel = result.onCancel
        let task = Task { [weak self] in
            await withTaskCancellationHandler {
                for await event in events {
                    if Task.isCancelled { break }
                    await self?.sendEvent(envelopeId: envelopeId, event: event)
                }
            } onCancel: {
                onCancel()
            }
            // Natural completion: producer's events stream finished.
            // Drop the bookkeeping record so a later connection close
            // doesn't try to cancel a finished task.
            await self?.subscriptionFinished(envelopeId: envelopeId)
        }
        subscriptions[envelopeId] = SubscriptionRecord(task: task)
    }

    private func sendEvent(
        envelopeId: UInt32,
        event: MethodRegistry.SubscriptionEvent
    ) async {
        await send(
            envelope: RPCEnvelope(
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

    private func send(envelope: RPCEnvelope) async {
        guard !closed else { return }
        do {
            let payload = try envelope.encode()
            let frame = RPCFraming.encode(payload)
            let wrote = await enqueueWrite(frame)
            guard wrote else {
                close()
                return
            }
        } catch {
            close()
        }
    }

    /// Admit a frame to the bounded per-connection writer. A peer that stops
    /// draining is disconnected once the pending budget is exhausted. The
    /// budget bounds only additional queued frames: the active write and the
    /// first frame admitted to an empty queue may exceed its byte limit. Close
    /// still resumes every parked sender.
    private func enqueueWrite(_ frame: Data) async -> Bool {
        guard !closed else { return false }
        let pendingQueueIsEmpty = pendingWrites.isEmpty
        let exceedsCount = pendingWrites.count >= Self.maximumPendingWriteCount
        let exceedsBytes = pendingWriteBytes + frame.count > Self.maximumPendingWriteBytes
        if exceedsCount || (exceedsBytes && !pendingQueueIsEmpty) {
            close()
            return false
        }

        return await withCheckedContinuation { continuation in
            pendingWrites.append(PendingWrite(frame: frame, completion: continuation))
            pendingWriteBytes += frame.count
            guard !writerPumpRunning else { return }
            writerPumpRunning = true
            Task { [weak self] in
                await self?.drainWrites()
            }
        }
    }

    /// Dequeue one frame at a time before entering the blocking queue. Only the
    /// active frame and the bounded `pendingWrites` array are retained while a
    /// peer is backpressured.
    private func drainWrites() async {
        while !closed, !pendingWrites.isEmpty {
            let pending = pendingWrites.removeFirst()
            pendingWriteBytes -= pending.frame.count
            let frame = pending.frame
            let wrote = await writeQueue.run { [fd] in
                do {
                    try UDSSocket.writeAll(fd: fd, data: frame)
                    return true
                } catch {
                    return false
                }
            }
            pending.completion.resume(returning: wrote)
            guard wrote else {
                writerPumpRunning = false
                close()
                return
            }
        }
        writerPumpRunning = false
    }

    private func failPendingWrites() {
        let pending = pendingWrites
        pendingWrites.removeAll(keepingCapacity: false)
        pendingWriteBytes = 0
        for write in pending {
            write.completion.resume(returning: false)
        }
    }

    private func send(errorResponse: RPCError, correlatingId id: UInt32) async {
        await send(
            envelope: RPCEnvelope(
            id: id,
            type: .response,
            method: nil,
            body: .error(errorResponse)
        )
            )
    }
}
