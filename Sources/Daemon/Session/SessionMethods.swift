// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// RPC handlers for the `session.*` and `tabs.*`
/// methods.
///
/// Each handler is a `MethodRegistry.Handler` factory: pass in the
/// shared `SessionManager` and get back the closure to register
/// under a method name. Wire shapes match the schema in
/// `docs/ARCHITECTURE.md`:
///
///     session.create({label?, name?, role?, initialProtected?, tabId?})
///                        → {sessionId, capability, shortId, name?, role}
///     session.close({sessionId, cap, mode?})
///                        → {ok: true}
///     tabs.list          → [{sessionId, tabId, shortId, name?, displayTitle?, label?}]
///
/// `session.close` applies `mode` to an in-flight boot claim before removing
/// the session. Existing pane shutdown still uses the GUI's per-pane fan-out.
public enum SessionMethods {
    // MARK: - Wire shapes

    public struct CreateParams: Codable, Sendable {
        public let label: String?
        /// Full GUI tab UUID shared by every terminal session in that tab.
        /// Optional on the wire; only a validated GUI may supply it, and an
        /// omission asks the daemon to self-group under the new session id.
        public let tabId: String?
        /// Optional session name. Mirrors the `name` field on
        /// `SessionState`, and this request is the only thing that
        /// ever sets it: nothing renames a session afterward. The GUI
        /// passes a worktree-derived branch name here (via
        /// `WorktreeName.detect`) so a tab opened in a worktree
        /// auto-labels with its branch; a nil leaves the session
        /// unnamed for good. Optional on the wire so older clients
        /// that don't carry the field encode/decode cleanly.
        public let name: String?
        /// Optional role assignment. Defaults to `.agent` when
        /// omitted; the GUI's "Open Automation Tab" menu is the
        /// product-UI path that passes `.automation` (no CLI verb
        /// does). The handler enforces this: an automation role
        /// is refused over UDS, and over XPC only accepted from a
        /// signature-validated peer. Optional on the wire for skew
        /// tolerance against pre-role clients.
        public let role: SessionRole?
        /// When true, the session is born with the protection flag set,
        /// atomically at create time. The GUI passes this for a terminal
        /// joining a tab that is already protected (or mid-transition to
        /// protected) so the new session is never observable as unprotected on
        /// `tabs.list`: a follow-up protection toggle would race the
        /// create's own persist/publish suspension points. Optional on
        /// the wire; absent/false is the ordinary unprotected session.
        public let initialProtected: Bool?

        /// Defaults preserve backward compatibility with call sites
        /// that don't carry the optional fields; `role` defaults to
        /// nil so the daemon applies its own default of `.agent`.
        public init(
            label: String?,
            name: String? = nil,
            role: SessionRole? = nil,
            initialProtected: Bool? = nil,
            tabId: String? = nil
        ) {
            self.label = label
            self.tabId = tabId
            self.name = name
            self.role = role
            self.initialProtected = initialProtected
        }
    }

    /// Response shape. `shortId` + `name` are the identifier model
    /// for the `--tab <ref>` resolver; `role` carries the role the
    /// daemon assigned (descriptive metadata). All ride alongside the foundational
    /// `sessionId` + `capability` so an older client that hasn't
    /// learned a field yet decodes the response cleanly and just
    /// doesn't use it. `role` is always emitted; the daemon never
    /// leaves it nil so newer callers can rely on it.
    public struct CreateResponse: Codable, Sendable, Equatable {
        public let sessionId: String
        public let capability: String
        public let shortId: String
        public let name: String?
        public let role: SessionRole
    }

    public struct CloseParams: Codable, Sendable {
        public let sessionId: String
        public let cap: String
        /// "detach" (default) or "shutdown": the tab-close
        /// semantic. Recorded for forward-compat; current handler
        /// closes the session record regardless.
        public let mode: String?
    }

    /// Mirrors the wire-side `DaemonProtocol.TabsListEntry`. `tabId` is the
    /// required grouping UUID. Sessions in one GUI tab share it; a session
    /// without a GUI tab uses its `sessionId`. GUI-backed groups support direct
    /// `--tab` resolution. `shortId` and `name` remain per-session convenience
    /// references.
    /// `displayTitle` is the normalized live label the GUI last pushed; it
    /// is never a ref, since it changes as often as the shell redraws its
    /// prompt.
    public struct TabsListEntry: Codable, Sendable, Equatable {
        public let sessionId: String
        public let tabId: String
        public let shortId: String
        public let name: String?
        public let displayTitle: String?
        public let label: String?
    }

    // MARK: - Handlers

    public static func create(using manager: SessionManager) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(CreateParams.self, from: paramsJSON)
            let requestedRole = params.role ?? .agent
            let requestedTabId: UUID?
            if let rawTabId = params.tabId {
                guard let parsed = UUID(uuidString: rawTabId) else {
                    throw RPCMethodError.invalidParams("tabId must be a UUID string")
                }
                guard let context = DispatchPeerContext.current,
                    context.transport == .xpc,
                    context.validatedGUIPeer else {
                    throw RPCMethodError(
                        code: RPCMethodError.scopeViolationCode,
                        message: "session.create tabId can only be supplied by the GUI"
                    )
                }
                requestedTabId = parsed
            } else {
                requestedTabId = nil
            }
            // Every XPC `session.create` (any role) must come from the VALIDATED
            // GUI: XPC is the GUI's transport, and only a validated session is
            // marked restorable (so its close leaves a tombstone that fences a
            // stale inventory). If the peer isn't validated, split on verdict
            // stability: read the resolved verdict stamped by `XPCConnection`,
            // never a fresh `validateGUIPeer` walk:
            //   - a transient `.unavailable` verdict (the signature walk couldn't
            //     complete) returns the RETRYABLE `notReady`, so a recoverable
            //     validation blip doesn't fail opening a tab (the GUI retries);
            //   - a STABLE `.rejected` signature mismatch (a rogue XPC peer) is a
            //     hard `scopeViolation`.
            // UDS creates are agent sessions, never GUI-restorable, and skip this.
            if let context = DispatchPeerContext.current,
                context.transport == .xpc,
                !context.validatedGUIPeer {
                guard context.validationStable else {
                    throw RPCMethodError.notReady("peer validation not ready")
                }
                throw RPCMethodError(
                    code: RPCMethodError.scopeViolationCode,
                    message: "session.create refused: peer failed validation"
                )
            }
            // Mint-time automation gate. Only the human GUI (a validated XPC
            // peer, guaranteed by the check above) may mint an automation
            // session; UDS (and a nil context) can never. The connection-layer
            // scope check covers automation-scoped methods after the mint.
            if requestedRole == .automation,
                DispatchPeerContext.current?.transport != .xpc {
                throw RPCMethodError(
                    code: RPCMethodError.scopeViolationCode,
                    message: "automation sessions can only be minted from the GUI"
                )
            }
            // Capture the owner identity from the transport peer: the audit
            // token on XPC, the LOCAL_PEERTOKEN identity on UDS, never from a
            // wire field. This is the "exact owner" provenance arm and the
            // orphan-liveness pid, both derived server-side so a caller can't
            // name a pid it doesn't own.
            let owner = DispatchPeerContext.current.flatMap { OwnerProcessIdentity.from($0) }
            // The creating connection id stamps the session's asserting epoch,
            // so an authoritative `session.restoreBatch` from a newer connection
            // reconciles it correctly (a session created on the current
            // connection is never mistaken for an older-connection ghost).
            let epoch = DispatchPeerContext.current?.connectionId ?? 0
            // A session the validated GUI mints over XPC is the only kind a GUI
            // restore can later resurrect, so only it needs a close tombstone.
            // A UDS or unvalidated-XPC mint (an agent's own session, or an
            // attacker churning create/close) is never in a GUI inventory.
            let restorable = DispatchPeerContext.current
                .map { $0.transport == .xpc && $0.validatedGUIPeer } ?? false
            let created: CreatedSession
            do {
                created = try await manager.createSession(
                    label: params.label,
                    name: params.name,
                    role: requestedRole,
                    owner: owner,
                    initialProtected: params.initialProtected ?? false,
                    epoch: epoch,
                    restorable: restorable,
                    tabId: requestedTabId
                )
            } catch {
                throw RPCMethodError(
                    code: RPCErrorCode.serverError,
                    message: "session.create: \(error)"
                )
            }
            // The one-time bearer token leaves the daemon here and nowhere
            // else; the stored `state` keeps only the verifier.
            let state = created.state
            let response = CreateResponse(
                sessionId: state.id.uuidString,
                capability: created.capability.token,
                shortId: state.shortId,
                name: state.name,
                role: state.role
            )
            return try JSONEncoder().encode(response)
        }
    }

    /// `session.bindTerminal({sessionId, foregroundPid, ttyName})
    /// → {ok: true}`. Bind a session to its terminal's kernel identity.
    /// `.validatedGUI`-scoped, so the peer's audit token is the authority and
    /// the connection scope check has already refused any non-validated-GUI
    /// caller. The daemon re-derives the anchor from the kernel via `probe`
    /// (never trusting the raw pid/tty) and stores it under the issuing GUI
    /// connection id, so a later close revokes exactly the anchors that
    /// connection bound. A probe that can't verify the terminal fails closed
    /// (`invalidParams`) and the session stays unbound: an in-tab UDS caller
    /// then gets `notReady` until a good bind lands.
    public static func bindTerminal(
        store: TerminalAnchorStore,
        probe: @escaping TerminalProbe = defaultTerminalProbe
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let params: SessionBindTerminalParams
            do {
                params = try JSONDecoder().decode(
                    SessionBindTerminalParams.self,
                    from: paramsJSON
                )
            } catch {
                throw RPCMethodError.invalidParams("malformed session.bindTerminal params")
            }
            guard let sessionId = UUID(uuidString: params.sessionId) else {
                throw RPCMethodError.invalidParams("sessionId must be a UUID string")
            }
            // The issuing GUI connection id attributes the anchor so its close
            // revokes it. A `.validatedGUI` dispatch always carries a peer
            // context; its absence is a wiring bug, not a caller condition.
            guard let connectionId = DispatchPeerContext.current?.connectionId else {
                throw RPCMethodError.invalidParams("no connection context for bindTerminal")
            }
            // Re-derive the anchor from the kernel. A nil result is the
            // fail-closed signal: the tty isn't a character device, the
            // foreground process' controlling tty doesn't match, the session
            // leader is dead, or the pid was reused mid-probe.
            guard let facts = probe(params.foregroundPid, params.ttyName) else {
                throw RPCMethodError.invalidParams("terminal could not be verified")
            }
            switch await store.bind(sessionId: sessionId, facts: facts, issuedBy: connectionId) {
            case .applied:
                return try JSONEncoder().encode(RPCAck(success: true))

            case .conflict:
                throw RPCMethodError.invalidParams(
                    "session already bound to a different terminal"
                )

            case .sessionNotLive:
                throw RPCMethodError.invalidParams("unknown or closed session")

            case .issuerRetired:
                throw RPCMethodError.unauthorized("issuing connection is closing")
            }
        }
    }

    public static func close(
        using manager: SessionManager,
        onClosing: @escaping @Sendable (UUID, PaneCloseMode) async -> Void = { _, _ in }
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(CloseParams.self, from: paramsJSON)
            let (sessionId, capability) = try parseCredentials(
                sessionIdString: params.sessionId,
                capString: params.cap
            )
            // A valid payload cap must not close a session other than the
            // connection's own: a stolen cap can't terminate a victim's tab.
            try requirePayloadMatchesConnection(sessionId)
            do {
                _ = try await manager.validate(
                    sessionId: sessionId,
                    capability: capability
                )
                let mode: PaneCloseMode
                if let rawMode = params.mode {
                    guard let parsed = PaneCloseMode(rawValue: rawMode) else {
                        throw RPCMethodError.invalidParams(
                            "mode must be \"detach\" or \"shutdown\""
                        )
                    }
                    mode = parsed
                } else {
                    mode = .detach
                }
                await onClosing(sessionId, mode)
                try await manager.closeSession(sessionId: sessionId, capability: capability)
            } catch let error as SessionError {
                throw mapSessionError(error)
            }
            return try JSONEncoder().encode(RPCAck(success: true))
        }
    }

    public static func tabsList(using manager: SessionManager) -> MethodRegistry.Handler {
        { _ in
            // Per `docs/ARCHITECTURE.md`, the result is a bare array,
            // not an object wrapper. Encode the entries directly so
            // the wire shape matches the canonical schema and any
            // client following the docs decodes cleanly.
            //
            // Protection filter: a protected session is visible only to
            // its owner. The originating session id comes from the
            // task-local `SessionDispatchContext.originatingSessionId`
            // bound by the dispatcher before this handler runs;
            // unauthenticated callers (no creds in env) have a nil
            // value and therefore never see protected sessions.
            let callerId = SessionDispatchContext.originatingSessionId
                .flatMap(UUID.init(uuidString:))
            let entries = await manager.sessionsWithDisplayTitles(visibleTo: callerId).map {
                TabsListEntry(
                    sessionId: $0.state.id.uuidString,
                    tabId: $0.state.tabId.uuidString,
                    shortId: $0.state.shortId,
                    name: $0.state.name,
                    displayTitle: $0.displayTitle,
                    label: $0.state.label
                )
            }
            return try JSONEncoder().encode(entries)
        }
    }

    /// `session.setDisplayTitle({sessionId, title}) → {ok: true}`. Cache
    /// the tab's normalized live label so `tabs.list` can serve it in place
    /// of the static `name`, falling back to `name` when it is absent.
    /// `.validatedGUI`-scoped, so the scope check has already refused any
    /// non-validated-GUI caller and no capability rides on the wire.
    ///
    /// A null `title` is the clear, not a no-op: normalization can reduce
    /// a non-empty OSC title to nothing, and skipping that push would leave
    /// the superseded label cached until some later update, session close,
    /// or daemon restart.
    ///
    /// An unknown session id is rejected rather than ignored, so a client
    /// bug can't accrete titles for dead sessions. That refusal is the
    /// usual `unauthorized` (-32001) code, but with its own message: the
    /// shared one names a capability, and this method carries none.
    public static func setDisplayTitle(using manager: SessionManager) -> MethodRegistry.Handler {
        { paramsJSON in
            let params: SessionSetDisplayTitleParams
            do {
                params = try JSONDecoder().decode(
                    SessionSetDisplayTitleParams.self,
                    from: paramsJSON
                )
            } catch {
                throw RPCMethodError.invalidParams("malformed session.setDisplayTitle params")
            }
            guard let sessionId = UUID(uuidString: params.sessionId) else {
                throw RPCMethodError.invalidParams("sessionId must be a UUID string")
            }
            // Fail closed: the ordering guard is only sound if every write
            // carries the connection it arrived on, and a `.validatedGUI`
            // dispatch always has a peer context.
            guard let connectionId = DispatchPeerContext.current?.connectionId else {
                throw RPCMethodError.unauthorized("no peer context for session.setDisplayTitle")
            }
            do {
                try await manager.setDisplayTitle(
                    sessionId: sessionId,
                    title: params.title,
                    fromConnection: connectionId
                )
            } catch SessionError.notFound {
                throw RPCMethodError.unauthorized("unknown sessionId")
            } catch let error as SessionError {
                throw mapSessionError(error)
            }
            return try JSONEncoder().encode(RPCAck(success: true))
        }
    }

    /// `session.setProtectedBatch({sessionIds, isProtected, revision})
    /// → {applied, revision, isProtected}`. Atomically flip the protection
    /// flag for every session backing one tab, subject to daemon-side
    /// last-write-wins ordering. `.validatedGUI`-scoped, so the peer's
    /// audit token is the authority: no `(sessionId, cap)` handshake,
    /// and the connection scope check has already refused any
    /// non-validated-GUI caller before this handler runs. The GUI is the
    /// only legitimate caller (it alone resolves a tab to its session
    /// set) and applies the owner check GUI-side before building the
    /// batch.
    ///
    /// Validation runs BEFORE any mutation: each id is parsed to a UUID
    /// here (malformed → `invalidParams`), then `setProtectedBatch`
    /// verifies every one names a live session and that the request's
    /// `(epoch, revision)` key dominates every target before flipping the
    /// set. A thrown error is a definite pre-mutation rejection (nothing
    /// committed); a returned `applied: false` means the batch was stale
    /// (a newer write already won) and, again, nothing changed: the GUI
    /// commits only from an `applied: true` reply.
    public static func setProtectedBatch(using manager: SessionManager) -> MethodRegistry.Handler {
        { paramsJSON in
            // A malformed payload is a *definite* pre-mutation rejection:
            // map it to `invalidParams` (not the dispatcher's catch-all
            // serverError) so the GUI's transition recovery can tell "the
            // daemon refused, nothing committed" apart from an
            // indeterminate transport loss.
            let params: SessionSetProtectedBatchParams
            do {
                params = try JSONDecoder().decode(
                    SessionSetProtectedBatchParams.self,
                    from: paramsJSON
                )
            } catch {
                throw RPCMethodError.invalidParams("malformed session.setProtectedBatch params")
            }
            var ids: [UUID] = []
            for raw in params.sessionIds {
                guard let id = UUID(uuidString: raw) else {
                    throw RPCMethodError.invalidParams("sessionId must be a UUID string")
                }
                ids.append(id)
            }
            // The ordering epoch is the caller's monotonic XPC connection
            // id, server-derived, so the client can't forge or rewind it.
            // A `.validatedGUI` dispatch always carries a peer context; its
            // absence is a wiring bug, not a caller condition.
            guard let epoch = DispatchPeerContext.current?.connectionId else {
                throw RPCMethodError.invalidParams("no connection context for setProtectedBatch")
            }
            do {
                let result = try await manager.setProtectedBatch(
                    sessionIds: ids,
                    isProtected: params.isProtected,
                    revision: params.revision,
                    epoch: epoch
                )
                return try JSONEncoder().encode(result)
            } catch let error as SessionError {
                throw mapSessionError(error)
            }
        }
    }

    /// `session.restoreBatch({sessions: [RestoredSession]})
    /// → {restoredCount, sessionIds}`. A validated GUI re-supplies its COMPLETE
    /// live session inventory to a fresh daemon after a daemon-only restart:
    /// the sole path by which sessions come back (nothing is rehydrated from
    /// disk). `.validatedGUI`-scoped, so the scope check has already refused any
    /// non-validated-GUI caller and the owner is captured from the validated
    /// XPC peer, never the payload.
    ///
    /// Every entry is parsed and validated BEFORE the manager is touched, so a
    /// malformed entry rejects the whole batch (`invalidParams`) with nothing
    /// mutated; the manager then applies the conflict-checked, all-or-none,
    /// `(epoch, tier, revision)`-fenced authoritative reconcile: inserting
    /// absent sessions (but never resurrecting one closed since the inventory was
    /// captured), correcting a present session's protection, and reconciling away a
    /// live session this complete inventory omits. The `restore` tier keeps a
    /// reconnect's inventory below any live user action at the same epoch. The
    /// supplied capability is never logged or interpolated into an error string.
    public static func restoreBatch(using manager: SessionManager) -> MethodRegistry.Handler {
        { paramsJSON in
            let params: SessionRestoreBatchParams
            do {
                params = try JSONDecoder().decode(
                    SessionRestoreBatchParams.self,
                    from: paramsJSON
                )
            } catch {
                throw RPCMethodError.invalidParams("malformed session.restoreBatch params")
            }
            var entries: [RestoreSessionEntry] = []
            entries.reserveCapacity(params.sessions.count)
            for wire in params.sessions {
                guard let id = UUID(uuidString: wire.sessionId) else {
                    throw RPCMethodError.invalidParams("sessionId must be a UUID string")
                }
                let tabId: UUID
                if let rawTabId = wire.tabId {
                    guard let parsed = UUID(uuidString: rawTabId) else {
                        throw RPCMethodError.invalidParams("tabId must be a UUID string")
                    }
                    tabId = parsed
                } else {
                    tabId = id
                }
                guard let capability = Capability(token: wire.capability) else {
                    throw RPCMethodError.invalidParams("cap must be base64-encoded bytes")
                }
                entries.append(
                    RestoreSessionEntry(
                        id: id,
                        capability: capability,
                        shortId: wire.shortId,
                        role: wire.role,
                        name: wire.name,
                        isProtected: wire.isProtected,
                        tabId: tabId
                    )
                )
            }
            // Owner from the validated XPC peer (never the wire) so the restored
            // session is owned by the live GUI: the exact-owner arm then
            // authenticates it and `isAlive` tracks the GUI. The connection id
            // is the server-derived protection-ordering epoch, so restore seeds a
            // last-write-wins baseline a stale older-connection write can't beat.
            // A `.validatedGUI` dispatch always carries a peer context; its
            // absence is a wiring bug, not a caller condition.
            guard let context = DispatchPeerContext.current else {
                throw RPCMethodError.invalidParams("no connection context for restoreBatch")
            }
            let owner = OwnerProcessIdentity.from(context)
            do {
                let result = try await manager.restoreBatch(
                    entries,
                    owner: owner,
                    epoch: context.connectionId,
                    revision: params.revision
                )
                return try JSONEncoder().encode(result)
            } catch let error as RestoreBatchError {
                throw mapRestoreBatchError(error)
            }
        }
    }

    /// `session.protectionSnapshot({sessionIds, revision})
    /// → {fenced, revision, sessions}`. Ordering-fenced authoritative read
    /// (see `SessionManager.protectionSnapshot`). `.validatedGUI`-scoped, same
    /// audit-token authority as `setProtectedBatch`; malformed params →
    /// `invalidParams`. Reads and fences only, never changes protection.
    public static func protectionSnapshot(using manager: SessionManager) -> MethodRegistry.Handler {
        { paramsJSON in
            let params: SessionProtectionSnapshotParams
            do {
                params = try JSONDecoder().decode(
                    SessionProtectionSnapshotParams.self,
                    from: paramsJSON
                )
            } catch {
                throw RPCMethodError.invalidParams("malformed session.protectionSnapshot params")
            }
            var ids: [UUID] = []
            for raw in params.sessionIds {
                guard let id = UUID(uuidString: raw) else {
                    throw RPCMethodError.invalidParams("sessionId must be a UUID string")
                }
                ids.append(id)
            }
            guard let epoch = DispatchPeerContext.current?.connectionId else {
                throw RPCMethodError.invalidParams("no connection context for protectionSnapshot")
            }
            let result = await manager.protectionSnapshot(
                sessionIds: ids,
                revision: params.revision,
                epoch: epoch
            )
            return try JSONEncoder().encode(result)
        }
    }

    // MARK: - Helpers

    /// Parse the on-wire `(sessionId, cap)` pair into the typed
    /// `UUID` / `Capability`. Validation errors throw
    /// `RPCMethodError(invalidParams)` so the dispatcher returns
    /// `-32602` to the client.
    static func parseCredentials(
        sessionIdString: String,
        capString: String
    ) throws -> (UUID, Capability) {
        guard let sessionId = UUID(uuidString: sessionIdString) else {
            throw RPCMethodError.invalidParams("sessionId must be a UUID string")
        }
        guard let capability = Capability(token: capString) else {
            throw RPCMethodError.invalidParams("cap must be base64-encoded bytes")
        }
        return (sessionId, capability)
    }

    /// Enforce that a payload-supplied session target equals the connection's
    /// own provenance-checked session. A handler that takes `(sessionId, cap)`
    /// in its params must not let a *valid* payload cap grant authority over a
    /// session other than the one the connection authenticated as: the cap is
    /// readable by any same-uid process (`ps -E`), so a caller could
    /// authenticate its own session and then drive a victim's by pasting the
    /// victim's stolen `(sessionId, cap)`. The validated GUI XPC peer is the
    /// sole cross-session exception: it legitimately spans sessions. UDS and
    /// unvalidated XPC may target only their own session; a mismatch throws the
    /// same `unauthorized` as a bad cap, so the two are indistinguishable.
    static func requirePayloadMatchesConnection(_ payloadSessionId: UUID) throws {
        guard let context = DispatchPeerContext.current else {
            throw RPCMethodError.unauthorized("invalid sessionId or cap")
        }
        if context.transport == .xpc, context.validatedGUIPeer { return }
        guard context.authenticatedSession?.id == payloadSessionId else {
            throw RPCMethodError.unauthorized("invalid sessionId or cap")
        }
    }

    /// Map `SessionError` to the corresponding RPC error so client-
    /// facing failures distinguish "no such session" from
    /// "session exists but cap doesn't match." Both surface as
    /// `unauthorizedCode` (-32001) on the wire: combining them in
    /// the visible response avoids leaking which sessionIds are
    /// live to unauthenticated callers (a side-channel that doesn't
    /// matter much given UDS access is user-scoped, but it costs
    /// nothing to deny).
    /// Map a `RestoreBatchError` to the client-facing RPC error. Every case is
    /// a definite pre-mutation rejection of the whole batch, so all surface as
    /// `invalidParams`. The message stays generic: the offending id/short id
    /// is daemon-side diagnostics only and the supplied capability is never
    /// echoed. The validated GUI is the only caller; a rejection means it sent
    /// a malformed or conflicting inventory.
    static func mapRestoreBatchError(_ error: RestoreBatchError) -> RPCMethodError {
        switch error {
        case .duplicateSessionId, .duplicateShortId, .malformedShortId,
            .verifierConflict, .metadataConflict, .shortIdCollision:
            return RPCMethodError.invalidParams(
                "session.restoreBatch rejected: malformed or conflicting batch"
            )

        case .staleBatch:
            // A newer restore already applied on a later connection. Nothing
            // mutated; the current GUI's own (newer-epoch) batch is the winner.
            return RPCMethodError.invalidParams(
                "session.restoreBatch rejected: superseded by a newer restore"
            )
        }
    }

    static func mapSessionError(_ error: SessionError) -> RPCMethodError {
        switch error {
        case .notFound, .invalidCapability:
            return RPCMethodError.unauthorized("invalid sessionId or cap")

        case .shortIDExhausted:
            // Unreachable in practice from `validate` / `closeSession`
            // (only `createSession` can throw this), but the switch
            // must be exhaustive. Surface as `serverError` if it ever
            // leaks through.
            return RPCMethodError(
                code: RPCErrorCode.serverError,
                message: "short_id alphabet exhausted; retry the request"
            )
        }
    }
}
