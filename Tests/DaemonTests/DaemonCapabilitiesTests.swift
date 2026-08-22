// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

// `daemon.capabilities` handler. Driven through the real
// `defaultRegistry(...)` so the responses reflect the actual method
// set the daemon ships. The automation surface in `allowedMethods`
// follows the session's live automation GRANT, not its role (see
// the XPC grant-matrix tests in `AutomationGrantScopeTests`); these
// exercise the no-grant paths: an ungranted session (any role) over
// UDS sees only the daemon-wide/session subset. Scenarios:
//   1. valid agent creds → role: .agent + session subset
//   2. valid automation creds → role: .automation, no grant → same subset
//   3. no creds → role: nil + daemon-wide subset

private func makeRegistry() -> (MethodRegistry, SessionManager) {
    let manager = SessionManager()
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: manager,
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator()
    )
    return (registry, manager)
}

private func capabilitiesHandler(
    _ registry: MethodRegistry
) throws -> MethodRegistry.Handler {
    guard let handler = registry.handler(for: "daemon.capabilities") else {
        throw CapabilitiesTestError.notRegistered
    }
    return handler
}

private enum CapabilitiesTestError: Error { case notRegistered }

/// Invoke the capabilities handler under a bound dispatch context, mirroring
/// the transport dispatcher. `daemon.capabilities` derives its advertised
/// role/grants from the PROVENANCE-CHECKED connection (`authenticatedSession`),
/// not from payload creds (a stolen payload cap must not surface a victim's
/// capabilities) so these direct-handler tests bind the session as the
/// connection's authenticated principal here. A nil `session` is the
/// unauthenticated/discovery path.
private func invokeCapabilities(
    _ handler: MethodRegistry.Handler,
    session: SessionState? = nil,
    validatedGUI: Bool = false,
    transport: DispatchPeerContext.Transport = .uds
) async throws -> DaemonCapabilitiesResponse {
    let context = DispatchPeerContext(
        transport: transport,
        connectionId: 1,
        authenticatedSession: session,
        validatedGUIPeer: validatedGUI
    )
    let result = try await DispatchPeerContext.$current.withValue(context) {
        try await handler(Data("{}".utf8))
    }
    return try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: result)
}

@Test
func capabilitiesIsTaggedDaemonWide() {
    let (registry, _) = makeRegistry()
    #expect(registry.scope(of: "daemon.capabilities") == .daemonWide)
}

@Test
func capabilitiesWithNoCredsReturnsNullRoleAndDaemonWideSubset() async throws {
    let (registry, _) = makeRegistry()
    let handler = try capabilitiesHandler(registry)
    let result = try await handler(Data("{}".utf8))
    let response = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: result)
    #expect(response.role == nil)
    // No-session callers see the daemon-wide subset only: every
    // .session-tagged method must be absent. Sanity-check via a
    // session method that exists.
    #expect(!response.allowedMethods.contains("pane.input.tap"))
    #expect(!response.allowedMethods.contains("panes.list"))
    // Regression guard: `shim.event` validates session creds
    // internally and rejects unauthenticated callers, so the
    // capability advertising must NOT list it for no-session
    // callers (would be a lie that makes `allowedMethods`
    // unreliable for discovery).
    #expect(!response.allowedMethods.contains("shim.event"))
    // The daemon-wide subset must contain capabilities itself
    // (otherwise out-of-tab callers couldn't discover it).
    #expect(response.allowedMethods.contains("daemon.capabilities"))
    #expect(response.allowedMethods.contains("daemon.ping"))
    #expect(response.allowedMethods.contains("tabs.list"))
}

@Test
func capabilitiesWithAgentCredsReturnsAgentRoleAndSessionSubset() async throws {
    let (registry, manager) = makeRegistry()
    let created = try await manager.createSession(label: nil, role: .agent)
    let state = created.state
    let handler = try capabilitiesHandler(registry)
    let response = try await invokeCapabilities(handler, session: state)
    #expect(response.role == .agent)
    // Agent sees daemon-wide + session methods. Sanity-check via
    // representative members of each scope.
    #expect(response.allowedMethods.contains("daemon.ping"))
    #expect(response.allowedMethods.contains("pane.input.tap"))
    #expect(response.allowedMethods.contains("panes.list"))
    // shim.event is .session, so agents (who have creds) DO see
    // it in their allowedMethods. Pin both directions of the
    // tagging: visible to agents (here) and absent for no-creds
    // callers (regression guard above).
    #expect(response.allowedMethods.contains("shim.event"))
}

@Test
func capabilitiesWithAutomationCredsReturnsAutomationRole() async throws {
    let (registry, manager) = makeRegistry()
    let created = try await manager.createSession(
        label: nil,
        role: .automation
    )
    let state = created.state
    let handler = try capabilitiesHandler(registry)
    let response = try await invokeCapabilities(handler, session: state)
    #expect(response.role == .automation)
    // The role is reported, but it grants nothing: an ungranted UDS session
    // omits automation capabilities. The grant-based advertising matrix is
    // exercised over XPC in `AutomationGrantScopeTests`.
    #expect(!response.allowedMethods.contains(RPCMethod.tabCapture.rawValue))
    #expect(!response.allowedMethods.contains(RPCMethod.tabSendInput.rawValue))
    // The `.validatedGUI` back-channel is never advertised to a
    // credentialed CLI caller: only a validated XPC GUI peer reaches
    // it, and this path has no such peer.
    #expect(!response.allowedMethods.contains(RPCMethod.appCommands.rawValue))
    #expect(!response.allowedMethods.contains(RPCMethod.appCommandResult.rawValue))
    // Same for the `.validatedGUI` privacy-batch write: a credentialed
    // CLI caller (even an automation) never sees it advertised.
    #expect(!response.allowedMethods.contains(RPCMethod.sessionSetPrivateBatch.rawValue))
}

@Test
func capabilitiesWithAgentCredsOmitsAutomationMethods() async throws {
    // The other half of the pairing above: an ungranted session doesn't
    // see the automation surface. An agent without a live grant omits
    // automation capabilities; a granted agent sees them over UDS or XPC
    // (per `AutomationGrantScopeTests`).
    let (registry, manager) = makeRegistry()
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let handler = try capabilitiesHandler(registry)
    let response = try await invokeCapabilities(handler, session: state)
    #expect(response.role == .agent)
    #expect(!response.allowedMethods.contains(RPCMethod.tabCapture.rawValue))
    #expect(!response.allowedMethods.contains(RPCMethod.tabSendInput.rawValue))
    #expect(!response.allowedMethods.contains(RPCMethod.sessionSetPrivateBatch.rawValue))
}

@Test
func capabilitiesIgnoresPayloadCredentialsAndUsesConnection() async throws {
    // Security: `daemon.capabilities` advertises for the PROVENANCE-CHECKED
    // connection, never a payload cap. An unauthenticated connection sees the
    // daemon-wide subset (nil role) even when the request body carries a
    // valid `(sessionId, cap)`: a stolen cap must not surface a victim's
    // role/grant advertising.
    let (registry, manager) = makeRegistry()
    let created = try await manager.createSession(label: nil, role: .agent)
    let handler = try capabilitiesHandler(registry)
    let params: [String: Any] = [
        "sessionId": created.state.id.uuidString,
        "cap": created.capability.token
    ]
    let paramsData = try JSONSerialization.data(withJSONObject: params)
    // Unauthenticated connection context, but a body carrying real creds.
    let context = DispatchPeerContext(
        transport: .uds,
        connectionId: 1,
        authenticatedSession: nil
    )
    let result = try await DispatchPeerContext.$current.withValue(context) {
        try await handler(paramsData)
    }
    let response = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: result)
    #expect(response.role == nil)
    #expect(!response.allowedMethods.contains("pane.input.tap"))
}

@Test
func capabilitiesAdvertisesCurrentWireAndLinkagePolicyVersion() async throws {
    let (registry, _) = makeRegistry()
    let handler = try capabilitiesHandler(registry)
    let result = try await handler(Data("{}".utf8))
    let response = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: result)
    #expect(response.wireVersion == DaemonInfo.version)
    #expect(response.linkagePolicyVersion == LinkagePolicy.currentVersion)
}

@Test
func capabilitiesIsAdvertisedAsCallable() async throws {
    // Capabilities advertises itself: without this, an out-of-tab
    // caller couldn't discover the method to call. A subtle but
    // load-bearing self-reference; pin it.
    let (registry, _) = makeRegistry()
    let handler = try capabilitiesHandler(registry)
    let result = try await handler(Data("{}".utf8))
    let response = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: result)
    #expect(response.allowedMethods.contains("daemon.capabilities"))
}

@Test
func capabilitiesOverUDSOmitsAutomationMethods() async throws {
    // End-to-end through the UDS dispatcher rather than the handler
    // in isolation, because the transport is exactly what's under
    // test. The CLI calls this at startup with its session cap and
    // filters `--help` off the result, so an automation tab must
    // not be told it can run verbs the dispatcher will refuse. The
    // session here is UNGRANTED, so advertising omits the automation
    // verbs: it follows the live grant, not the role or the transport
    // (a granted session over UDS *is* advertised them; see
    // `AutomationGrantUDSScopeTests`).
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, role: .automation)
    let path = tempSocketPath(prefix: "deviceterm-caps-uds")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    // Capabilities now reflects the authenticated connection (not payload
    // creds), so authenticate as the automation session first.
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: RPCMethod.daemonCapabilities.rawValue,
        body: .empty
    )
        )
    let response = try client.receive()
    guard case let .result(payload) = response.body else {
        Issue.record("expected .result for daemon.capabilities; got \(response.body)")
        return
    }
    let decoded = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: payload)
    #expect(decoded.role == .automation)
    #expect(!decoded.allowedMethods.contains(RPCMethod.tabCapture.rawValue))
    #expect(!decoded.allowedMethods.contains(RPCMethod.tabSendInput.rawValue))
    // The rest of the surface is unaffected.
    #expect(decoded.allowedMethods.contains(RPCMethod.panesList.rawValue))
}
