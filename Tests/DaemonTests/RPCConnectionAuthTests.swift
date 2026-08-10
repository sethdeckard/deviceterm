// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// Dispatcher-level connection-auth gate. Together with
// `MethodRegistryScopeTests` (advertising) and the per-handler tests
// in this directory (handler logic), these tests pin the dispatcher's
// scope-check responsibility: `.session` methods require an
// authenticated connection; `.orchestratorTab` and `.validatedGUI`
// methods are refused outright on this transport (UDS carries no audit
// token); `.daemonWide` methods work regardless. The CLI never threads
// creds. The connection's auth state is the source of truth.

@Test
func sessionMethodWithoutAuthRejectedByDispatcher() async throws {
    let manager = SessionManager()
    _ = try await manager.makeSessionState(label: nil)
    let path = tempSocketPath(prefix: "deviceterm-cxn-auth")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connect(to: path)
    defer { client.close() }

    // No `session.authenticate` frame. Dispatcher should reject any
    // .session call before the handler sees it. `panes.list` is the
    // simplest session-scoped call.
    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "panes.list",
        body: .params(
            try paramsBytes(
            PanesListParams(
            sessionId: UUID().uuidString,
            cap: (try Capability.random()).token
        )
            )
            )
    )
        )
    let response = try client.receive()
    guard case let .error(error) = response.body else {
        Issue.record("expected dispatcher rejection, got \(response.body)")
        return
    }
    #expect(error.code == RPCMethodError.unauthorizedCode)
    #expect(error.message.contains("session.authenticate"))
}

@Test
func daemonWideMethodWorksWithoutAuth() async throws {
    let path = tempSocketPath(prefix: "deviceterm-cxn-auth")
    let server = try await startServer(path: path)
    defer { Task { await server.stop() } }
    let client = try TestClient.connect(to: path)
    defer { client.close() }

    // No auth: `daemon.ping` must still respond cleanly. Confirms
    // the dispatcher only gates .session/.orchestratorTab/.validatedGUI
    // scopes, not .daemonWide ones; out-of-tab `deviceterm tabs list` /
    // `deviceterm version` work for stock-terminal callers.
    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "daemon.ping",
        body: .empty
    )
        )
    let response = try client.receive()
    guard case .result = response.body else {
        Issue.record("expected .result for daemon.ping, got \(response.body)")
        return
    }
}

@Test
func sessionMethodWorksAfterExplicitAuth() async throws {
    // Exercises the production path end-to-end: connect, auth, then
    // call a session-scoped method. `TestClient.connectAuthenticated`
    // bundles connect + auth; this test confirms a session-scoped
    // call dispatches successfully after.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let path = tempSocketPath(prefix: "deviceterm-cxn-auth")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "panes.list",
        body: .params(
            try paramsBytes(
            PanesListParams(
            sessionId: state.id.uuidString,
            cap: created.capability.token
        )
            )
            )
    )
        )
    let response = try client.receive()
    guard case .result = response.body else {
        Issue.record("expected .result for auth'd panes.list, got \(response.body)")
        return
    }
}

@Test
func authenticateWithStaleCredsRejected() async throws {
    let manager = SessionManager()
    let path = tempSocketPath(prefix: "deviceterm-cxn-auth")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }

    // No session exists in the manager; `connectAuthenticated` runs
    // the auth handshake which the daemon rejects, and the helper
    // throws `authFailed` rather than handing back a half-broken
    // client. Present a random (sessionId, cap) that can't validate:
    // no `CreatedSession` exists for a stray, so use the raw primitive.
    let strayCap = try Capability.random()
    do {
        _ = try TestClient.connectAuthenticated(
            to: path,
            sessionId: UUID().uuidString,
            cap: strayCap.token
        )
        Issue.record("expected authFailed, got a connected client")
    } catch let error as TestClientError {
        #expect(error == .authFailed)
    }
}

@Test
func authenticateReplacesPriorAuthState() async throws {
    // Re-authing on the same connection is last-write-wins (the
    // dispatcher's check is `authenticatedSession != nil`). After
    // re-auth, the connection is treated as the second session.
    let manager = SessionManager()
    let firstCreated = try await manager.createSession(label: nil)
    let secondCreated = try await manager.createSession(label: nil)
    let secondState = secondCreated.state
    let path = tempSocketPath(prefix: "deviceterm-cxn-auth")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(
        to: path,
        as: firstCreated
    )
    defer { client.close() }

    // Send a second auth frame for the other session. The daemon
    // accepts and replaces; the connection is now bound to
    // secondState (verified by sending a session-scoped call after).
    let reauthParams = SessionAuthenticateParams(
        sessionId: secondState.id.uuidString,
        cap: secondCreated.capability.token
    )
    try client.send(
        RPCEnvelope(
        id: 0,
        type: .request,
        method: RPCMethod.sessionAuthenticate.rawValue,
        body: .params(try JSONEncoder().encode(reauthParams))
    )
        )
    let reauthResponse = try client.receive()
    guard case .result = reauthResponse.body else {
        Issue.record("expected re-auth .result, got \(reauthResponse.body)")
        return
    }

    // Session-scoped call after re-auth still succeeds.
    try client.send(
        RPCEnvelope(
        id: 2,
        type: .request,
        method: "panes.list",
        body: .params(
            try paramsBytes(
            PanesListParams(
            sessionId: secondState.id.uuidString,
            cap: secondCreated.capability.token
        )
            )
            )
    )
        )
    let panesResponse = try client.receive()
    guard case .result = panesResponse.body else {
        Issue.record("expected .result post-reauth, got \(panesResponse.body)")
        return
    }
}

// MARK: - Orchestrator scope over UDS
//
// An UNGRANTED session (whatever role it holds) cannot reach orchestrator
// scope over UDS. Authority is a live orchestration grant, not the cap and not
// the role: the cap is deliberately readable by every child process in the tab
// (so it can't prove orchestrator authority on its own), and the role is
// descriptive metadata. So an authenticated-but-ungranted UDS caller is refused
// at the scope check with `role_violation`, exactly as it would be over XPC.
// The complementary GRANTED-session positive path (a UDS caller inside a
// granted tab DOES reach the surface) lives in `OrchestratorGrantUDSScopeTests`;
// these two pin the refusal half: that neither role opens the surface without
// a grant.

@Test
func orchestratorScopeRejectedOverUDSEvenWithOrchestratorRole() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, role: .orchestrator)
    let path = tempSocketPath(prefix: "deviceterm-cxn-orch")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: RPCMethod.tabCapture.rawValue,
        body: .params(
            try paramsBytes(
            AppCommandParams.TabCapture(tab: Wire.TabRef(type: "current", value: nil))
        )
            )
    )
        )
    let response = try client.receive()
    guard case let .error(error) = response.body else {
        Issue.record(
            """
            an ungranted orchestrator-role session reached a handler over \
            UDS; the live-grant check is the only thing standing between a \
            tab-readable cap and cross-tab input
            """
        )
        return
    }
    #expect(error.code == RPCMethodError.roleViolationCode)
}

@Test
func orchestratorScopeRejectedOverUDSWithAgentRole() async throws {
    // Same rejection for an agent-role session. Authority is the grant,
    // not the role, so an ungranted session of either role is refused.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let path = tempSocketPath(prefix: "deviceterm-cxn-orch")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: RPCMethod.tabCapture.rawValue,
        body: .params(
            try paramsBytes(
            AppCommandParams.TabCapture(tab: Wire.TabRef(type: "current", value: nil))
        )
            )
    )
        )
    let response = try client.receive()
    guard case let .error(error) = response.body else {
        Issue.record("expected .error for agent-role orchestrator call")
        return
    }
    #expect(error.code == RPCMethodError.roleViolationCode)
}
