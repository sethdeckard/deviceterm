// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

// The automation surface (`tab.sendInput` / `tab.capture`) is reachable over
// UDS, but ONLY for a session holding a live automation grant. A UDS caller
// authenticates via cap + kernel terminal-process provenance, and the grant is
// minted by the validated GUI, so cap + provenance + live grant (never a role)
// is the authority. These run against the real UDS dispatch path so advertising
// and enforcement are proven to agree.
//
// Grants can't be issued over UDS (`automation.grant` is `.validatedGUI`), so
// the tests place them directly on the shared store, modelling the GUI having
// granted the session, then drive the verbs over the wire.

private let liveGrantKey = GrantOrderingKey(epoch: 1, revision: 1)

/// The workspace-wide verbs. They create or rearrange workspace surfaces or
/// change which one has focus, so they need the same live grant
/// `tab.sendInput`/`tab.capture` do. The scope gate runs before target
/// resolution, so the refusal never depends on which tab is named.
private let workspaceWideMethods: [RPCMethod] = [
    .tabOpen, .tabSelect, .tabMove, .windowOpen, .windowFocus
]

/// The handler-reached signal: `AppCommandMethods.publishVerb` returns
/// `guiUnavailable` (-32099) when no GUI is subscribed. An error only
/// producible PAST the scope check, so it unambiguously proves the granted
/// call cleared the `.automationTab` gate, without standing up a fake GUI.
private let guiUnavailableCode = -32_099

private func errorCode(_ response: RPCEnvelope) -> Int? {
    guard case let .error(error) = response.body else { return nil }
    return error.code
}

private extension PaneCoordinator {
    /// Seed a sim pane owned by `session` with a mock backend: no
    /// CoreSimulator touched. Mirrors the file-private helpers in the pane
    /// test suites (each keeps its own to avoid a shared-fixture coupling).
    func seedSimPane(udid: String, session: UUID) async throws -> PaneCreateResult {
        try await createPane(
            target: .sim(udid: udid),
            sessionId: session,
            acquire: { AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone") }
        )
    }
}

private func send(
    _ method: RPCMethod,
    over client: TestClient,
    id: UInt32 = 1
) throws -> RPCEnvelope {
    try client.send(
        RPCEnvelope(id: id, type: .request, method: method.rawValue, body: .params(Data("{}".utf8)))
    )
    return try client.receive()
}

@Test(arguments: [RPCMethod.tabSendInput, RPCMethod.tabCapture])
func grantedSessionReachesAutomationVerbOverUDS(method: RPCMethod) async throws {
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    // A plain .agent session, proving the GRANT, not a role, opens the surface.
    let created = try await manager.createSession(label: nil)
    await grants.grant(sessionIds: [created.state.id], key: liveGrantKey, issuedBy: 1)

    let path = tempSocketPath(prefix: "deviceterm-orch-uds")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    // Reaches the handler (no GUI subscribed → guiUnavailable), which is only
    // reachable past the scope gate.
    #expect(errorCode(try send(method, over: client)) == guiUnavailableCode)
}

@Test(arguments: workspaceWideMethods)
func grantedSessionReachesWorkspaceVerbOverUDS(method: RPCMethod) async throws {
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)
    await grants.grant(sessionIds: [created.state.id], key: liveGrantKey, issuedBy: 1)

    let path = tempSocketPath(prefix: "deviceterm-orch-uds")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    #expect(errorCode(try send(method, over: client)) == guiUnavailableCode)
}

@Test(arguments: workspaceWideMethods)
func ungrantedSessionRefusedWorkspaceVerbOverUDS(method: RPCMethod) async throws {
    // Authentication succeeds without a grant; the scope gate must still
    // refuse the request.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)

    let path = tempSocketPath(prefix: "deviceterm-orch-uds")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    #expect(errorCode(try send(method, over: client)) == RPCMethodError.scopeViolationCode)
}

@Test
func ungrantedSessionRefusedAutomationVerbOverUDS() async throws {
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)  // no grant placed

    let path = tempSocketPath(prefix: "deviceterm-orch-uds")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    // Authenticated but ungranted → hard scopeViolation (creds valid, no grant).
    #expect(errorCode(try send(.tabCapture, over: client)) == RPCMethodError.scopeViolationCode)
}

@Test
func ungrantedAutomationRoleRefusedOverUDS() async throws {
    // Even an .automation-ROLE session is refused with no live grant: the
    // role is descriptive metadata, not authority, over UDS just as over XPC.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil, role: .automation)

    let path = tempSocketPath(prefix: "deviceterm-orch-uds")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    #expect(errorCode(try send(.tabCapture, over: client)) == RPCMethodError.scopeViolationCode)
}

@Test
func unauthenticatedConnectionRefusedAutomationVerbOverUDS() async throws {
    // No session at all → unauthorized, not scopeViolation: the connection isn't
    // just ungranted, it never authenticated.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)

    let path = tempSocketPath(prefix: "deviceterm-orch-uds")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connect(to: path)
    defer { client.close() }

    #expect(errorCode(try send(.tabCapture, over: client)) == RPCMethodError.unauthorizedCode)
}

@Test
func revokingGrantRefusesSameUDSSocket() async throws {
    // The grant is re-checked live on every request: revoking it mid-connection
    // closes the surface again on the already-authenticated socket.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)
    let sid = created.state.id
    await grants.grant(sessionIds: [sid], key: liveGrantKey, issuedBy: 1)

    let path = tempSocketPath(prefix: "deviceterm-orch-uds")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    #expect(errorCode(try send(.tabCapture, over: client, id: 1)) == guiUnavailableCode)

    // Revoke with a newer key (the session is still live, just ungranted now).
    _ = await grants.revoke(sessionIds: [sid], key: GrantOrderingKey(epoch: 1, revision: 2))
    #expect(errorCode(try send(.tabCapture, over: client, id: 2)) == RPCMethodError.scopeViolationCode)
}

@Test
func capabilitiesAdvertisesAutomationForGrantedSessionOverUDS() async throws {
    // Advertising follows the grant on UDS too: a granted session sees the
    // automation verbs in its allowedMethods, matching what dispatch enforces.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil)
    await grants.grant(sessionIds: [created.state.id], key: liveGrantKey, issuedBy: 1)

    let path = tempSocketPath(prefix: "deviceterm-orch-uds")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    let response = try send(.daemonCapabilities, over: client)
    guard case let .result(bytes) = response.body else {
        Issue.record("expected a capabilities result; got \(response.body)")
        return
    }
    let allowed = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: bytes).allowedMethods
    #expect(allowed.contains(RPCMethod.tabSendInput.rawValue))
    #expect(allowed.contains(RPCMethod.tabCapture.rawValue))
    for method in workspaceWideMethods {
        #expect(allowed.contains(method.rawValue))
    }
}

@Test
func grantGivesZeroExtraPaneReachOverUDS() async throws {
    // A grant opens `tab.sendInput`/`tab.capture`, NOT cross-session pane
    // input. Pane methods are `.session`-scoped and authorized by the caller's
    // pane OWNERSHIP (`PaneAccessPrincipal`), which never consults grant state,
    // so a granted session A still cannot drive a pane owned by session B. This
    // pins that the grant is architecturally incapable of widening pane reach.
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let paneCoordinator = PaneCoordinator()
    let sessionA = try await manager.createSession(label: nil)  // will be granted
    let sessionB = try await manager.createSession(label: nil)  // owns the pane
    await grants.grant(sessionIds: [sessionA.state.id], key: liveGrantKey, issuedBy: 1)
    let bPane = try await paneCoordinator.seedSimPane(
        udid: "B-OWNED-UDID",
        session: sessionB.state.id
    )

    let path = tempSocketPath(prefix: "deviceterm-orch-uds")
    let server = try await startServer(
        path: path,
        sessionManager: manager,
        paneCoordinator: paneCoordinator
    )
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: sessionA)
    defer { client.close() }

    // Granted A taps B's pane → the ownership gate rejects it, indistinguishably
    // from an unknown pane (`invalidParams`, "unknown paneId"). The grant buys
    // nothing here.
    try client.send(
        RPCEnvelope(
            id: 1,
            type: .request,
            method: RPCMethod.paneInputTap.rawValue,
            body: .params(try JSONEncoder().encode(
                TapParams(paneId: bPane.paneId.uuidString, x: 0.5, y: 0.5)
            ))
        )
    )
    #expect(errorCode(try client.receive()) == RPCMethodError.invalidParamsCode)
}

@Test
func capabilitiesOmitsAutomationForUngrantedSessionOverUDS() async throws {
    let grants = AutomationGrantStore()
    let manager = SessionManager(automationGrantStore: grants)
    let created = try await manager.createSession(label: nil, role: .automation)  // ungranted

    let path = tempSocketPath(prefix: "deviceterm-orch-uds")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    let response = try send(.daemonCapabilities, over: client)
    guard case let .result(bytes) = response.body else {
        Issue.record("expected a capabilities result; got \(response.body)")
        return
    }
    let allowed = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: bytes).allowedMethods
    #expect(!allowed.contains(RPCMethod.tabSendInput.rawValue))
    #expect(!allowed.contains(RPCMethod.tabCapture.rawValue))
    // `allowedMethods` reports the connection's callable surface, so it
    // must omit verbs the dispatcher will refuse.
    for method in workspaceWideMethods {
        #expect(!allowed.contains(method.rawValue))
    }
}
