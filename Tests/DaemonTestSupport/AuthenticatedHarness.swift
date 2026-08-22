// SPDX-License-Identifier: GPL-3.0-or-later

import Daemon
import Foundation

/// One-call test fixture for session-scoped RPC tests.
///
/// Bundles a started server, a freshly-minted session, and a
/// `TestClient` whose connection has already authenticated as that
/// session. Tests that hit `.session`-scoped methods get
/// production-equivalent dispatcher enforcement (no test-only
/// bypass) without per-test boilerplate.
///
/// **Teardown pattern.** Pull the server + client out as locals
/// before the defer so the closure captures Sendable values only
/// (the harness itself isn't Sendable because TestClient isn't):
///
///     let harness = try await startAuthenticatedHarness(path: path)
///     let server = harness.server
///     let client = harness.client
///     defer { client.close(); Task { await server.stop() } }
///
/// Tests that only need daemon-wide methods (no session) stay on
/// the bare `TestClient.connect` path. The harness is for the
/// session-scoped majority.
public struct AuthenticatedHarness {
    public let server: RPCServer
    public let sessionManager: SessionManager
    public let deviceCoordinator: DeviceCoordinator
    public let paneCoordinator: PaneCoordinator
    public let state: SessionState
    /// The one-time bearer capability for `state`. Exposed because the
    /// daemon keeps only the verifier; a test that needs to authenticate
    /// a second connection, or thread creds explicitly, reads it here.
    public let capability: Capability
    public let client: TestClient

    public init(
        server: RPCServer,
        sessionManager: SessionManager,
        deviceCoordinator: DeviceCoordinator,
        paneCoordinator: PaneCoordinator,
        state: SessionState,
        capability: Capability,
        client: TestClient
    ) {
        self.server = server
        self.sessionManager = sessionManager
        self.deviceCoordinator = deviceCoordinator
        self.paneCoordinator = paneCoordinator
        self.state = state
        self.capability = capability
        self.client = client
    }
}

/// Start a server + mint a session + connect an auth'd client in one
/// call. Defaults to `.agent` role; pass `role: .automation` when
/// testing automation-only dispatch behavior.
public func startAuthenticatedHarness(
    path: String,
    sessionManager: SessionManager = SessionManager(),
    deviceCoordinator: DeviceCoordinator = DeviceCoordinator(),
    paneCoordinator: PaneCoordinator = PaneCoordinator(),
    role: SessionRole = .agent,
    // When the test already minted the session it will name in a handler's
    // payload creds, pass it here so the harness authenticates the client as
    // THAT session. Payload-credential handlers now require the payload target
    // to equal the connection's authenticated session (a stolen cap can't
    // drive a foreign session), so a test that authenticated as a different,
    // harness-minted session would be refused. Nil mints a fresh session.
    existingSession: CreatedSession? = nil,
) async throws -> AuthenticatedHarness {
    let server = try await startServer(
        path: path,
        sessionManager: sessionManager,
        deviceCoordinator: deviceCoordinator,
        paneCoordinator: paneCoordinator,
    )
    let created: CreatedSession
    if let existingSession {
        created = existingSession
    } else {
        created = try await sessionManager.createSession(label: nil, role: role)
    }
    let client = try TestClient.connectAuthenticated(
        to: path,
        as: created
    )
    return AuthenticatedHarness(
        server: server,
        sessionManager: sessionManager,
        deviceCoordinator: deviceCoordinator,
        paneCoordinator: paneCoordinator,
        state: created.state,
        capability: created.capability,
        client: client
    )
}
