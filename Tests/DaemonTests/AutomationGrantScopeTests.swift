// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing
@preconcurrency import XPC

// Automation authority is a LIVE grant, not a cached role, enforced over
// the real XPC dispatch path. And the grant/revoke verbs are
// validated-GUI-only. Payloads are atomic. Session close and GUI disconnect
// revoke on the same already-authenticated socket.

private let validatedGUIPeer: PeerValidator = { _ in
    .production(peerTeamID: "TEST", peerBundleID: "test.host")
}

private func automationServer(
    manager: SessionManager,
    grants: AutomationGrantStore,
    coordinator: AppCommandCoordinator = AppCommandCoordinator()
) -> XPCServer {
    let registry = MethodRegistry(
        handlers: [
            RPCMethod.automationGrant.rawValue:
                .validatedGUI(AutomationMethods.grant(store: grants)),
            RPCMethod.automationRevoke.rawValue:
                .validatedGUI(AutomationMethods.revoke(store: grants)),
            RPCMethod.tabCapture.rawValue:
                .automationTab(AppCommandMethods.publishVerb(kind: .tabCapture, coordinator: coordinator))
        ],
        provenance: TestPeerIdentity.xpcProvenance(manager),
        automationGrant: grants
    )
    let authValidator: AuthValidator = { try await manager.validate(sessionId: $0, capability: $1) }
    return XPCServer(
        methods: registry,
        authValidator: authValidator,
        peerValidator: validatedGUIPeer
    )
}

private func errorCode(_ reply: xpc_object_t) throws -> Int? {
    guard case let .error(error) = try decodeEnvelope(reply: reply).body else { return nil }
    return error.code
}

private func authenticate(_ created: CreatedSession, client: xpc_connection_t, replyBox: ReplyBox) async throws {
    let params = try JSONEncoder().encode(
        SessionAuthenticateParams(sessionId: created.state.id.uuidString, cap: created.capability.token)
    )
    sendRequest(envelopeId: 1, method: RPCMethod.sessionAuthenticate.rawValue, params: params, client: client)
    _ = try await replyBox.awaitReply()
}

private func grantBody(_ ids: [UUID], revision: Int) throws -> Data {
    try JSONEncoder().encode(AutomationGrantParams(sessionIds: ids, revision: revision))
}

private func send(_ id: UInt32, _ method: RPCMethod, _ body: Data, to client: xpc_connection_t) {
    sendRequest(envelopeId: id, method: method.rawValue, params: body, client: client)
}

/// Coordinates the first-validation/disconnect race test: the validator marks
/// `entered` on its first call and blocks; the test polls `entered` (it can't
/// wait a semaphore in an async context), disconnects, then releases.
private final class ValidationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var didEnter = false
    let release = DispatchSemaphore(value: 0)

    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }

    /// True on the first call only; marks entry.
    func enterFirst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        didEnter = true
        return true
    }
}

@Test
func automationScopeIsGatedByLiveGrantNotRole() async throws {
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    // A plain .agent session, proving ROLE is not the authority.
    let created = try await manager.createSession(label: nil)
    let sid = created.state.id
    let server = automationServer(manager: manager, grants: grants)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)
    try await authenticate(created, client: clientPair, replyBox: replyBox)

    // No grant → refused at the scope gate.
    sendRequest(envelopeId: 2, method: RPCMethod.tabCapture.rawValue, params: Data("{}".utf8), client: clientPair)
    #expect(try errorCode(try await replyBox.awaitReply()) == RPCMethodError.scopeViolationCode)

    // Grant → the call reaches the handler (guiUnavailable, -32099).
    send(3, .automationGrant, try grantBody([sid], revision: 1), to: clientPair)
    _ = try await replyBox.awaitReply()
    sendRequest(envelopeId: 4, method: RPCMethod.tabCapture.rawValue, params: Data("{}".utf8), client: clientPair)
    #expect(try errorCode(try await replyBox.awaitReply()) == -32_099)

    // Revoke → the SAME authenticated socket is refused again (live recheck).
    send(5, .automationRevoke, try grantBody([sid], revision: 2), to: clientPair)
    _ = try await replyBox.awaitReply()
    sendRequest(envelopeId: 6, method: RPCMethod.tabCapture.rawValue, params: Data("{}".utf8), client: clientPair)
    #expect(try errorCode(try await replyBox.awaitReply()) == RPCMethodError.scopeViolationCode)
}

@Test
func automationRoleWithoutGrantIsRefused() async throws {
    // Even a .automation-role session is refused with no live grant:
    // the role is metadata, not authority.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil, role: .automation)
    let server = automationServer(manager: manager, grants: grants)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)
    try await authenticate(created, client: clientPair, replyBox: replyBox)

    sendRequest(envelopeId: 2, method: RPCMethod.tabCapture.rawValue, params: Data("{}".utf8), client: clientPair)
    #expect(try errorCode(try await replyBox.awaitReply()) == RPCMethodError.scopeViolationCode)
}

/// The workspace-wide verbs, which affect workspace structure or focus rather
/// than anything inside the caller's own tab. Duplicated from the UDS suite
/// deliberately: each file names the set it drives, and
/// `registryTagsExactlyTheAutomationSurface` is what pins the real one.
private let workspaceWideMethods: [RPCMethod] = [
    .tabOpen, .tabSelect, .tabMove, .windowOpen, .windowFocus
]

@Test(arguments: workspaceWideMethods)
func workspaceVerbGatedByLiveGrantOverXPC(method: RPCMethod) async throws {
    // Both halves of the matrix over the real registry and the real XPC
    // dispatch path: refused for an ordinary tab, reached once the grant
    // lands. Driving the same authenticated socket for both proves the grant
    // is read per request rather than cached at authentication.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)
    let server = defaultRegistryServer(manager: manager)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)
    try await authenticate(created, client: clientPair, replyBox: replyBox)

    sendRequest(envelopeId: 2, method: method.rawValue, params: Data("{}".utf8), client: clientPair)
    #expect(try errorCode(try await replyBox.awaitReply()) == RPCMethodError.scopeViolationCode)

    // Granted → past the gate and into the handler, which reports
    // guiUnavailable (-32099) with no GUI subscribed.
    await grants.grant(
        sessionIds: [created.state.id],
        key: GrantOrderingKey(epoch: 1, revision: 1),
        issuedBy: 1
    )
    sendRequest(envelopeId: 3, method: method.rawValue, params: Data("{}".utf8), client: clientPair)
    #expect(try errorCode(try await replyBox.awaitReply()) == -32_099)
}

@Test
func grantForNonLiveSessionIsRejected() async throws {
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)
    let server = automationServer(manager: manager, grants: grants)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)
    try await authenticate(created, client: clientPair, replyBox: replyBox)

    // Grant a batch with one live + one unknown session → invalidParams,
    // and NOTHING is granted (all-or-none).
    sendRequest(
        envelopeId: 2,
        method: RPCMethod.automationGrant.rawValue,
        params: try grantBody([created.state.id, UUID()], revision: 1),
        client: clientPair
    )
    #expect(try errorCode(try await replyBox.awaitReply()) == RPCMethodError.invalidParamsCode)
    #expect(await grants.hasGrant(created.state.id) == false)
}

@Test
func malformedIdBatchIsRejectedWithNoMutation() async throws {
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)
    // Pre-grant the valid session so we can prove a later malformed batch
    // doesn't disturb it.
    await grants.grant(sessionIds: [created.state.id], key: GrantOrderingKey(epoch: 1, revision: 1), issuedBy: 1)
    let server = automationServer(manager: manager, grants: grants)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)
    try await authenticate(created, client: clientPair, replyBox: replyBox)

    // A revoke batch with a malformed id → invalidParams at decode, no
    // mutation: the pre-existing grant survives.
    let malformed = Data(#"{"sessionIds":["\#(created.state.id.uuidString)","not-a-uuid"],"revision":9}"#.utf8)
    sendRequest(envelopeId: 2, method: RPCMethod.automationRevoke.rawValue, params: malformed, client: clientPair)
    #expect(try errorCode(try await replyBox.awaitReply()) == RPCMethodError.invalidParamsCode)
    #expect(await grants.hasGrant(created.state.id))
}

@Test
func sessionCloseRevokesGrantAndRefusesSameSocket() async throws {
    // The grant store is injected into the manager, so closeSession revokes.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)
    let sid = created.state.id
    let server = automationServer(manager: manager, grants: grants)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)
    try await authenticate(created, client: clientPair, replyBox: replyBox)

    // Grant, confirm reach.
    send(2, .automationGrant, try grantBody([sid], revision: 1), to: clientPair)
    _ = try await replyBox.awaitReply()
    sendRequest(envelopeId: 3, method: RPCMethod.tabCapture.rawValue, params: Data("{}".utf8), client: clientPair)
    #expect(try errorCode(try await replyBox.awaitReply()) == -32_099)

    // Close the session out from under the socket → grant revoked → refused.
    // The per-request provenance re-check now sees the session gone and
    // downgrades the socket's cached principal to unauthenticated, so the
    // refusal is `unauthorized` (the session no longer exists) rather than
    // `scopeViolation` (a live session lacking a grant). A stronger statement:
    // the socket isn't just ungranted, it's no longer authenticated at all.
    try await manager.closeSession(sessionId: sid, capability: created.capability)
    #expect(await grants.hasGrant(sid) == false)
    sendRequest(envelopeId: 4, method: RPCMethod.tabCapture.rawValue, params: Data("{}".utf8), client: clientPair)
    #expect(try errorCode(try await replyBox.awaitReply()) == RPCMethodError.unauthorizedCode)
}

@Test(arguments: [RPCMethod.automationGrant, RPCMethod.automationRevoke])
func grantAndRevokeRefusedOverUDS(method: RPCMethod) async throws {
    // Both are .validatedGUI: an authenticated UDS caller (any role) can't
    // reach them, so no same-uid CLI process can issue itself a grant.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, role: .automation)
    let path = tempSocketPath(prefix: "deviceterm-orch-grant")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    let body = try JSONEncoder().encode(
        AutomationGrantParams(sessionIds: [created.state.id], revision: 1)
    )
    try client.send(RPCEnvelope(id: 1, type: .request, method: method.rawValue, body: .params(body)))
    let response = try client.receive()
    guard case let .error(error) = response.body else {
        Issue.record("expected \(method.rawValue) refused over UDS; got \(response.body)")
        return
    }
    #expect(error.code == RPCMethodError.scopeViolationCode)
}

@Test
func guiDisconnectRevokesItsGrants() async throws {
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)
    let sid = created.state.id
    let server = automationServer(manager: manager, grants: grants)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)
    try await authenticate(created, client: clientPair, replyBox: replyBox)

    send(2, .automationGrant, try grantBody([sid], revision: 1), to: clientPair)
    _ = try await replyBox.awaitReply()
    #expect(await grants.hasGrant(sid))

    // The GUI disappears: cancel the connection. The server sees the XPC
    // error, runs `close()`, which revokes every grant this connection held.
    xpc_connection_cancel(clientPair)
    var revoked = false
    for _ in 0..<200 where !revoked {
        if await grants.hasGrant(sid) {
            try await Task.sleep(nanoseconds: 10_000_000)
        } else {
            revoked = true
        }
    }
    #expect(revoked)
}

@Test(arguments: [RPCMethod.automationGrant, RPCMethod.automationRevoke])
func grantAndRevokeRefusedOverUnvalidatedXPC(method: RPCMethod) async throws {
    // An XPC peer whose signature doesn't validate can't grant/revoke: the
    // `.validatedGUI` scope refuses it, so a rogue local XPC client can't
    // mint itself authority.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)
    let registry = MethodRegistry(
        handlers: [
            RPCMethod.automationGrant.rawValue:
                .validatedGUI(AutomationMethods.grant(store: grants)),
            RPCMethod.automationRevoke.rawValue:
                .validatedGUI(AutomationMethods.revoke(store: grants))
        ],
        provenance: TestPeerIdentity.xpcProvenance(manager),
        automationGrant: grants
    )
    let authValidator: AuthValidator = { try await manager.validate(sessionId: $0, capability: $1) }
    let server = XPCServer(
        methods: registry,
        authValidator: authValidator,
        peerValidator: { _ in .rejected(reason: "test") }
    )
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    send(1, method, try grantBody([created.state.id], revision: 1), to: clientPair)
    #expect(try errorCode(try await replyBox.awaitReply()) == RPCMethodError.scopeViolationCode)
    #expect(await grants.hasGrant(created.state.id) == false)
}

@Test
func grantReplyReportsAppliedForFreshAndStaleBatches() async throws {
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)
    let sid = created.state.id
    let server = automationServer(manager: manager, grants: grants)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)
    try await authenticate(created, client: clientPair, replyBox: replyBox)

    func applied(_ reply: xpc_object_t) throws -> Bool? {
        guard case let .result(bytes) = try decodeEnvelope(reply: reply).body else { return nil }
        return try JSONDecoder().decode(AutomationGrantResult.self, from: bytes).applied
    }

    // A fresh grant applies.
    send(2, .automationGrant, try grantBody([sid], revision: 5), to: clientPair)
    #expect(try applied(try await replyBox.awaitReply()) == true)
    // A stale re-grant (lower revision, same connection epoch) does not.
    send(3, .automationGrant, try grantBody([sid], revision: 1), to: clientPair)
    #expect(try applied(try await replyBox.awaitReply()) == false)
}

@Test
func firstGrantSuspendedInValidationThenDisconnectDoesNotGrant() async throws {
    // The verdict-resolution race: a first grant request suspends inside
    // peer validation; the connection disconnects during that suspension
    // (so `close()` sees no resolved verdict and records no tombstone); the
    // request then resumes with a `true` verdict. The post-verdict `closed`
    // recheck must abort it: no grant for the dead connection.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)
    let sid = created.state.id

    // A validator that blocks on its first call, letting the test disconnect
    // mid-validation. `PeerVerdictCache` runs the validator in a detached
    // task and the connection awaits it, so blocking here suspends the
    // connection's dispatch (leaving its actor free for `close()`) without
    // wedging any actor's executor.
    let gate = ValidationGate()
    let validator: PeerValidator = { _ in
        if gate.enterFirst() {
            _ = gate.release.wait(timeout: .now() + 5)
        }
        return .production(peerTeamID: "TEST", peerBundleID: "test.host")
    }
    let registry = MethodRegistry(
        handlers: [
            RPCMethod.automationGrant.rawValue:
                .validatedGUI(AutomationMethods.grant(store: grants))
        ],
        provenance: TestPeerIdentity.xpcProvenance(manager),
        automationGrant: grants
    )
    let authValidator: AuthValidator = { try await manager.validate(sessionId: $0, capability: $1) }
    let server = XPCServer(
        methods: registry,
        authValidator: authValidator,
        peerValidator: validator
    )
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    // Send the grant (no auth needed: .validatedGUI). Its verdict
    // resolution blocks in the validator.
    send(1, .automationGrant, try grantBody([sid], revision: 1), to: clientPair)
    var enteredValidation = false
    for _ in 0..<200 where !enteredValidation {
        if gate.entered { enteredValidation = true } else { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    #expect(enteredValidation)

    // Disconnect and wait until the server has fully removed the connection
    // (teardown complete) BEFORE releasing validation, so the resumed
    // request is guaranteed to observe `closed`. A fixed sleep wouldn't
    // prove the ordering.
    xpc_connection_cancel(clientPair)
    var torndown = false
    for _ in 0..<300 where !torndown {
        if await server.connectionCount == 0 { torndown = true } else { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    #expect(torndown)
    gate.release.signal()

    // Now the resumed request runs. Poll for a grant. WITHOUT the
    // post-verdict guard it would apply here (close ran with no tombstone,
    // so it would NOT be revoked); with the guard it aborts. Give the bad
    // path ample time to manifest, then assert it never granted.
    var leaked = false
    for _ in 0..<50 where !leaked {
        if await grants.hasGrant(sid) { leaked = true } else { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    #expect(leaked == false)
}

@Test
func daemonRestartBeginsWithNoGrants() async {
    // Grants are never persisted; a fresh store (models a restart) is empty.
    let store = AutomationGrantStore()
    #expect(await store.hasGrant(UUID()) == false)
}

// MARK: - Capability advertising matches the grant matrix

private func defaultRegistryServer(manager: SessionManager) -> XPCServer {
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: manager,
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator(),
        provenance: TestPeerIdentity.xpcProvenance(manager)
    )
    let authValidator: AuthValidator = { try await manager.validate(sessionId: $0, capability: $1) }
    return XPCServer(
        methods: registry,
        authValidator: authValidator,
        peerValidator: validatedGUIPeer
    )
}

private func advertisedMethods(
    for created: CreatedSession,
    server: XPCServer
) async throws -> [String] {
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    setupClient(clientPair, replyBox: replyBox)
    // Capabilities advertises for the connection's authenticated principal
    // (not payload creds), so authenticate the connection first.
    try await authenticate(created, client: clientPair, replyBox: replyBox)
    // No payload creds: capabilities derives from the authenticated connection.
    sendRequest(
        envelopeId: 2,
        method: RPCMethod.daemonCapabilities.rawValue,
        params: Data("{}".utf8),
        client: clientPair
    )
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .result(bytes) = envelope.body else { return [] }
    return try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: bytes).allowedMethods
}

@Test
func capabilitiesAdvertisesAutomationForGrantedAgentOverXPC() async throws {
    // A GRANTED .agent session, over validated XPC, is advertised the
    // automation surface: advertising follows the grant, not the role.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)  // .agent
    await grants.grant(sessionIds: [created.state.id], key: GrantOrderingKey(epoch: 1, revision: 1), issuedBy: 1)
    let server = defaultRegistryServer(manager: manager)
    defer { Task { await server.stop() } }
    let methods = try await advertisedMethods(for: created, server: server)
    #expect(methods.contains(RPCMethod.tabCapture.rawValue))
    #expect(methods.contains(RPCMethod.tabSendInput.rawValue))
    for method in workspaceWideMethods {
        #expect(methods.contains(method.rawValue))
    }
}

@Test
func capabilitiesOmitsAutomationForUngrantedAutomationOverXPC() async throws {
    // An UNGRANTED .automation session is NOT advertised the surface,
    // matching what dispatch enforces: no over-advertising.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil, role: .automation)
    let server = defaultRegistryServer(manager: manager)
    defer { Task { await server.stop() } }
    let methods = try await advertisedMethods(for: created, server: server)
    #expect(!methods.contains(RPCMethod.tabCapture.rawValue))
    #expect(!methods.contains(RPCMethod.tabSendInput.rawValue))
    for method in workspaceWideMethods {
        #expect(!methods.contains(method.rawValue))
    }
}
