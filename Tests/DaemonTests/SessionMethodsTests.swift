// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// Round-trip a single envelope through a fresh server instance. The
// server is torn down before this helper returns so each test gets a
// clean slate without manually wiring `defer { stop() }` everywhere.
//
// `authenticatedAs:` opt-in: when provided, the helper sends a
// `session.authenticate` frame before the test's envelope so
// `.session`-scoped methods (e.g. `session.close`) pass the
// dispatcher's auth gate. Tests calling daemon-wide methods (e.g.
// `session.create`, `tabs.list`) omit it.
private func roundTrip(
    _ envelope: RPCEnvelope,
    manager: SessionManager,
    authenticatedAs created: CreatedSession? = nil
) async throws -> RPCEnvelope {
    let path = tempSocketPath(prefix: "deviceterm-sess")
    let server = RPCServer(
        socketPath: path,
        methods: DaemonMethods.defaultRegistry(
            sessionManager: manager,
            deviceCoordinator: DeviceCoordinator(),
            paneCoordinator: PaneCoordinator(),
            provenance: TestPeerIdentity.udsProvenance(manager)
        ),
        authValidator: { sessionId, capability in
            try await manager.validate(
                sessionId: sessionId,
                capability: capability
            )
        },
        peerIdentityResolver: TestPeerIdentity.udsResolver
    )
    try await server.start()
    defer { Task { await server.stop() } }
    try await Task.sleep(nanoseconds: 50_000_000)

    let fd = try UDSSocket.connectClient(to: path)
    defer { Darwin.close(fd) }

    if let created {
        let authParams = SessionAuthenticateParams(
            sessionId: created.state.id.uuidString,
            cap: created.capability.token
        )
        let authEnvelope = RPCEnvelope(
            id: 0,
            type: .request,
            method: RPCMethod.sessionAuthenticate.rawValue,
            body: .params(try JSONEncoder().encode(authParams))
        )
        try UDSSocket.writeAll(
            fd: fd,
            data: RPCFraming.encode(try authEnvelope.encode())
        )
        // Drain + discard the auth ack so the subsequent waitForFrame
        // returns the test's actual response.
        _ = try waitForFrame(fd: fd)
    }
    try UDSSocket.writeAll(fd: fd, data: RPCFraming.encode(try envelope.encode()))
    return try waitForFrame(fd: fd)
}

private func waitForFrame(fd: Int32, timeoutSeconds: Double = 2) throws -> RPCEnvelope {
    let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
    var buffer = Data()
    while Date() < deadline {
        if let frame = try RPCFraming.decodeNext(from: buffer) {
            return try RPCEnvelope.decode(frame.payload)
        }
        if let chunk = try UDSSocket.readAvailable(fd: fd), !chunk.isEmpty {
            buffer.append(chunk)
            continue
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw RoundTripError.timedOut
}

private enum RoundTripError: Error { case timedOut }

// Decode the result body of an envelope into a typed response.
// Records an Issue and returns nil if the envelope isn't a .result.
private func decodeResult<R: Decodable>(
    _ envelope: RPCEnvelope,
    as type: R.Type
) throws -> R? {
    guard case let .result(bytes) = envelope.body else {
        Issue.record("expected .result body, got \(envelope.body)")
        return nil
    }
    return try JSONDecoder().decode(R.self, from: bytes)
}

// MARK: - session.create

@Test
func sessionCreateReturnsUuidAndBase64Capability() async throws {
    let manager = SessionManager()
    let envelope = RPCEnvelope(
        id: 1,
        type: .request,
        method: "session.create",
        body: .params(try paramsBytes(SessionMethods.CreateParams(label: "auth-feature")))
    )
    let response = try await roundTrip(envelope, manager: manager)
    #expect(response.id == 1)
    let create = try #require(try decodeResult(response, as: SessionMethods.CreateResponse.self))
    let uuid = try #require(UUID(uuidString: create.sessionId))
    let capability = try #require(Capability(token: create.capability))
    #expect(capability.bytes.count == Capability.standardByteCount)

    // The session is live on the manager side with the matching cap.
    let validated = try await manager.validate(sessionId: uuid, capability: capability)
    #expect(validated.label == "auth-feature")
}

@Test
func sessionCreateAcceptsEmptyBody() async throws {
    let manager = SessionManager()
    let envelope = RPCEnvelope(
        id: 2,
        type: .request,
        method: "session.create",
        body: .empty
    )
    let response = try await roundTrip(envelope, manager: manager)
    let create = try #require(try decodeResult(response, as: SessionMethods.CreateResponse.self))
    #expect(UUID(uuidString: create.sessionId) != nil)
    #expect(Capability(token: create.capability) != nil)
    let count = await manager.sessionCount
    #expect(count == 1)
}

@Test
func sessionCreateDefaultsToAgentRole() async throws {
    // A `session.create` call with no `role` field in params yields
    // an `.agent` session. The default lives in two places
    // (CreateParams init + SessionManager.createSession's role
    // argument); this test pins the end-to-end default.
    let manager = SessionManager()
    let envelope = RPCEnvelope(
        id: 1,
        type: .request,
        method: "session.create",
        body: .params(try paramsBytes(SessionMethods.CreateParams(label: nil)))
    )
    let response = try await roundTrip(envelope, manager: manager)
    let create = try #require(
        try decodeResult(
        response,
        as: SessionMethods.CreateResponse.self
    )
        )
    #expect(create.role == .agent)
    // Storage side reflects it.
    let uuid = try #require(UUID(uuidString: create.sessionId))
    let capability = try #require(Capability(token: create.capability))
    let state = try await manager.validate(
        sessionId: uuid,
        capability: capability
    )
    #expect(state.role == .agent)
}

@Test
func sessionCreateRejectsAutomationRoleOverUDS() async throws {
    // The post-lifecycle trust boundary: automation mints over
    // UDS are unconditionally rejected. UDS carries no audit token,
    // so the daemon can't validate the peer against its own signature
    // (kernel terminal provenance authenticates the SESSION, but not
    // human-GUI escalation), so the dispatcher refuses the mint before
    // SessionManager.createSession can run. Wire
    // callers that need automation must go through XPC where
    // PeerIdentity validates the peer against the daemon's
    // own signature.
    let manager = SessionManager()
    let envelope = RPCEnvelope(
        id: 1,
        type: .request,
        method: "session.create",
        body: .params(
            try paramsBytes(
            SessionMethods.CreateParams(
            label: nil,
            name: nil,
            role: .automation
        )
            )
            )
    )
    let response = try await roundTrip(envelope, manager: manager)
    guard case let .error(error) = response.body else {
        let bodyDescription = "\(response.body)"
        Issue.record("expected .error body rejecting automation mint, got \(bodyDescription)")
        return
    }
    #expect(error.code == RPCMethodError.scopeViolationCode)
    let count = await manager.sessionCount
    #expect(count == 0)
}

@Test
func sessionManagerStillSupportsInternalAutomationMinting() async throws {
    // The transport handler rejects unauthorized mints, while the
    // validated-GUI XPC path delegates to
    // `SessionManager.createSession(role:)`. Keep the manager
    // role-agnostic: pin that it doesn't develop its own rejection.
    let manager = SessionManager()
    let state = try await manager.makeSessionState(
        label: nil,
        role: .automation
    )
    #expect(state.role == .automation)
}

@Test
func sessionCreateResponseAlwaysCarriesRoleField() async throws {
    // Wire-level: the daemon must always emit `role` (it's
    // non-Optional on the daemon-side response type). The CLI's
    // older-daemon skew path tolerates a missing field via
    // `DaemonProtocol.SessionCreateResponse.role: SessionRole?`;
    // this test pins that the daemon-side shape itself doesn't go
    // soft on the field.
    let manager = SessionManager()
    let envelope = RPCEnvelope(
        id: 1,
        type: .request,
        method: "session.create",
        body: .empty
    )
    let response = try await roundTrip(envelope, manager: manager)
    guard case let .result(bytes) = response.body else {
        Issue.record("expected .result body, got \(response.body)")
        return
    }
    let payload = try JSONSerialization.jsonObject(with: bytes)
        as? [String: Any]
    #expect(payload?["role"] as? String == "agent")
}

// MARK: - session.close

@Test
func sessionCloseSucceedsWithMatchingCredentials() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let envelope = RPCEnvelope(
        id: 3,
        type: .request,
        method: "session.close",
        body: .params(
            try paramsBytes(
            SessionMethods.CloseParams(
            sessionId: state.id.uuidString,
            cap: created.capability.token,
            mode: "detach"
        )
            )
            )
    )
    let response = try await roundTrip(
        envelope,
        manager: manager,
        authenticatedAs: created
    )
    let result = try #require(try decodeResult(response, as: RPCAck.self))
    #expect(result.success)
    let count = await manager.sessionCount
    #expect(count == 0)
}

@Test
func sessionCloseRejectsUnknownModeWithoutClosingSession() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let envelope = RPCEnvelope(
        id: 31,
        type: .request,
        method: RPCMethod.sessionClose.rawValue,
        body: .params(
            try paramsBytes(
                SessionMethods.CloseParams(
                    sessionId: created.state.id.uuidString,
                    cap: created.capability.token,
                    mode: "shudown"
                )
            )
        )
    )

    let response = try await roundTrip(
        envelope,
        manager: manager,
        authenticatedAs: created
    )

    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error body, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.invalidParamsCode)
    #expect(await manager.sessionCount == 1)
}

@Test
func sessionCloseRejectsWrongCapability() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let stranger = try Capability.random()
    let envelope = RPCEnvelope(
        id: 4,
        type: .request,
        method: "session.close",
        body: .params(
            try paramsBytes(
            SessionMethods.CloseParams(
            sessionId: state.id.uuidString,
            cap: stranger.token,
            mode: nil
        )
            )
            )
    )
    // Auth with the real cap so the dispatcher lets the request
    // through to the handler: the handler then rejects the
    // wrong-cap-in-params shape with unauthorized. Confirms the
    // handler's own cred check still works after the connection-
    // layer gate was added.
    let response = try await roundTrip(
        envelope,
        manager: manager,
        authenticatedAs: created
    )
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error body, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.unauthorizedCode)
    // Session must still be alive: a bad cap can't close it.
    let count = await manager.sessionCount
    #expect(count == 1)
}

@Test
func sessionCloseRejectsMalformedSessionId() async throws {
    let manager = SessionManager()
    // Need a real session for connection auth: without it the
    // dispatcher rejects session-scoped methods before the
    // handler's UUID-malformed check ever runs, masking the case
    // we're trying to test.
    let created = try await manager.createSession(label: nil)
    let envelope = RPCEnvelope(
        id: 5,
        type: .request,
        method: "session.close",
        body: .params(
            try paramsBytes(
            SessionMethods.CloseParams(
            sessionId: "not-a-uuid",
            cap: (try Capability.random()).token,
            mode: nil
        )
            )
            )
    )
    let response = try await roundTrip(
        envelope,
        manager: manager,
        authenticatedAs: created
    )
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error body, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.invalidParamsCode)
    #expect(rpcError.message.contains("UUID"))
}

@Test
func sessionCloseRejectsMalformedCapability() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let envelope = RPCEnvelope(
        id: 6,
        type: .request,
        method: "session.close",
        body: .params(
            try paramsBytes(
            SessionMethods.CloseParams(
            sessionId: state.id.uuidString,
            cap: "not&base64*",
            mode: nil
        )
            )
            )
    )
    let response = try await roundTrip(
        envelope,
        manager: manager,
        authenticatedAs: created
    )
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error body, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.invalidParamsCode)
    #expect(rpcError.message.contains("base64"))
}

// MARK: - tabs.list

@Test
func tabsListExposesLabelsButNotCapabilities() async throws {
    let manager = SessionManager()
    _ = try await manager.makeSessionState(label: "alpha")
    _ = try await manager.makeSessionState(label: nil)  // unlabeled tab
    _ = try await manager.makeSessionState(label: "beta")

    let envelope = RPCEnvelope(
        id: 7,
        type: .request,
        method: "tabs.list",
        body: .empty
    )
    let response = try await roundTrip(envelope, manager: manager)
    let tabs = try #require(try decodeResult(response, as: [SessionMethods.TabsListEntry].self))
    #expect(tabs.count == 3)
    let labels = tabs.map(\.label)
    #expect(labels == ["alpha", nil, "beta"])
    // Tabs entries don't carry the capability. It is returned by the one-time
    // `session.create` response and injected into that terminal's environment,
    // not exposed through daemon-wide inventory. (No structural assertion is
    // needed; TabsListEntry simply has no capability field.)
    for entry in tabs {
        #expect(UUID(uuidString: entry.sessionId) != nil)
    }
}

@Test
func tabsListIsBareArrayOnWire() async throws {
    // Direct schema check: the result body is JSON `[…]`, not
    // `{"tabs":[…]}`. docs/ARCHITECTURE.md's canonical shape is the
    // bare array; we verify by parsing the raw result bytes as
    // an Any and checking the root type.
    let manager = SessionManager()
    _ = try await manager.makeSessionState(label: "only-tab")
    let envelope = RPCEnvelope(
        id: 8,
        type: .request,
        method: "tabs.list",
        body: .empty
    )
    let response = try await roundTrip(envelope, manager: manager)
    guard case let .result(bytes) = response.body else {
        Issue.record("expected .result body, got \(response.body)")
        return
    }
    let parsed = try JSONSerialization.jsonObject(with: bytes, options: [])
    #expect(parsed is [Any], "tabs.list result should be a bare array, got \(type(of: parsed))")
}

@Test
func tabsListIsEmptyOnFreshManager() async throws {
    let manager = SessionManager()
    let envelope = RPCEnvelope(
        id: 9,
        type: .request,
        method: "tabs.list",
        body: .empty
    )
    let response = try await roundTrip(envelope, manager: manager)
    let tabs = try #require(try decodeResult(response, as: [SessionMethods.TabsListEntry].self))
    #expect(tabs.isEmpty)
}

@Test
func tabsListHidesPrivateFromUnauthenticatedCaller() async throws {
    // Private session: no auth on the connection → the daemon
    // filters it out. This is the locked design's "private tab is
    // opaque to other principals" rule applied to the
    // out-of-tab / stock-terminal case.
    let manager = SessionManager()
    let priv = try await manager.makeSessionState(
        label: nil,
        name: "private"
    )
    try await manager.setPrivateBatch(sessionIds: [priv.id], isPrivate: true, revision: 1, epoch: 1)
    _ = try await manager.makeSessionState(label: nil, name: "public")
    let envelope = RPCEnvelope(
        id: 1,
        type: .request,
        method: "tabs.list",
        body: .empty
    )
    let response = try await roundTrip(envelope, manager: manager)
    let tabs = try #require(
        try decodeResult(
        response,
        as: [SessionMethods.TabsListEntry].self
    )
        )
    #expect(tabs.map(\.name) == ["public"])
}

@Test
func tabsListShowsOwnPrivateToAuthenticatedOwner() async throws {
    // The owning session DOES see its own private tab when
    // authenticated on the connection. Sibling-private sessions
    // stay hidden.
    let manager = SessionManager()
    let created = try await manager.createSession(
        label: nil,
        name: "owner"
    )
    let owner = created.state
    try await manager.setPrivateBatch(sessionIds: [owner.id], isPrivate: true, revision: 1, epoch: 1)
    let other = try await manager.makeSessionState(
        label: nil,
        name: "other"
    )
    try await manager.setPrivateBatch(sessionIds: [other.id], isPrivate: true, revision: 1, epoch: 1)
    let envelope = RPCEnvelope(
        id: 1,
        type: .request,
        method: "tabs.list",
        body: .empty
    )
    let response = try await roundTrip(
        envelope,
        manager: manager,
        authenticatedAs: created
    )
    let tabs = try #require(
        try decodeResult(
        response,
        as: [SessionMethods.TabsListEntry].self
    )
        )
    #expect(tabs.map(\.name) == ["owner"])
}

@Test
func setDisplayTitleRefusedOverUDS() async throws {
    // `session.setDisplayTitle` is `.validatedGUI`-scoped: the peer's audit
    // token is the authority. UDS carries none, so the dispatcher's scope
    // gate refuses the method outright (even on an authenticated
    // connection) before the handler runs, and nothing is cached. Only the
    // GUI sees OSC titles, so only the GUI writes them.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, name: nil)
    let body = try JSONEncoder().encode(
        SessionSetDisplayTitleParams(
            sessionId: created.state.id.uuidString,
            title: "spoofed"
        )
    )
    let envelope = RPCEnvelope(
        id: 1,
        type: .request,
        method: RPCMethod.sessionSetDisplayTitle.rawValue,
        body: .params(body)
    )
    let response = try await roundTrip(
        envelope,
        manager: manager,
        authenticatedAs: created
    )
    guard case let .error(error) = response.body else {
        Issue.record("expected .error body for UDS setDisplayTitle; got \(response.body)")
        return
    }
    #expect(error.code == RPCMethodError.scopeViolationCode)
    #expect(await manager.displayTitle(created.state.id) == nil)
}

@Test
func tabsListCarriesTheLiveDisplayTitle() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, name: "branch")
    try await manager.setDisplayTitle(sessionId: created.state.id, title: "vim foo", fromConnection: 1)
    let envelope = RPCEnvelope(id: 1, type: .request, method: "tabs.list", body: .empty)
    let response = try await roundTrip(envelope, manager: manager)
    let tabs = try #require(
        try decodeResult(response, as: [TabsListEntry].self)
    )
    #expect(tabs.map(\.displayTitle) == ["vim foo"])
    #expect(tabs.map(\.name) == ["branch"])
}

@Test
func setPrivateBatchRefusedOverUDS() async throws {
    // `session.setPrivateBatch` is `.validatedGUI`-scoped: the peer's
    // audit token is the authority. UDS carries no audit token, so the
    // dispatcher's scope gate refuses the method outright (even on an
    // authenticated connection) before the handler runs. Nothing
    // mutates. The cap-readable UDS path can never flip a tab's privacy;
    // only the signature-validated GUI peer can.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, name: nil)
    let state = created.state
    let body = try JSONEncoder().encode(
        SessionSetPrivateBatchParams(
        sessionIds: [state.id.uuidString],
        isPrivate: true,
        revision: 1
    )
        )
    let envelope = RPCEnvelope(
        id: 1,
        type: .request,
        method: "session.setPrivateBatch",
        body: .params(body)
    )
    let response = try await roundTrip(
        envelope,
        manager: manager,
        authenticatedAs: created
    )
    guard case let .error(error) = response.body else {
        Issue.record("expected .error body for UDS setPrivateBatch; got \(response.body)")
        return
    }
    #expect(error.code == RPCMethodError.scopeViolationCode)
    #expect(await manager.isPrivate(state.id) == false)
}
