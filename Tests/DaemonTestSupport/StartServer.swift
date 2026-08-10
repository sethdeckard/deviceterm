// SPDX-License-Identifier: GPL-3.0-or-later

import Daemon
import Foundation

/// Bring up an `RPCServer` bound to `path` with `DaemonMethods.defaultRegistry`.
/// All three service actors are optional: tests pass only the ones they
/// care to introspect; the rest get fresh default-constructed instances.
///
/// The 50ms post-`start` sleep gives the server's accept loop time to
/// bind the socket before the test's `TestClient.connect` runs.
/// Without it, fast-pathed tests occasionally raced and saw ECONNREFUSED.
///
/// Tests that need a `shutdownTrigger` (e.g. `DaemonShutdownTests`)
/// reach for `DaemonMethods.defaultRegistry` directly. This helper
/// only covers the common three-actor case.
///
/// Lives in `DaemonTestSupport` (a plain library, public Daemon API
/// only) so both `DaemonTests` and `CoreSimulatorLiveTests` can share it.
public func startServer(
    path: String,
    sessionManager: SessionManager = SessionManager(),
    deviceCoordinator: DeviceCoordinator = DeviceCoordinator(),
    paneCoordinator: PaneCoordinator = PaneCoordinator(),
    appCommandCoordinator: AppCommandCoordinator = AppCommandCoordinator(),
) async throws -> RPCServer {
    // Always wire the AuthValidator to the session manager so tests
    // exercise the production dispatcher behavior: session-scoped
    // calls require the connection to authenticate first. Tests
    // that hit those methods use `TestClient.connectAuthenticated`
    // and pass the same `sessionManager` so the validator agrees;
    // tests that only hit daemon-wide methods use `TestClient.connect`
    // unchanged.
    let server = RPCServer(
        socketPath: path,
        methods: DaemonMethods.defaultRegistry(
            sessionManager: sessionManager,
            deviceCoordinator: deviceCoordinator,
            paneCoordinator: paneCoordinator,
            appCommandCoordinator: appCommandCoordinator,
            // Both the grant store and the provenance context ride ON the
            // registry now (the grant store sourced from `sessionManager`), so
            // the stores the handlers write are the same ones the connections'
            // scope check / lookup read. Inject a deterministic peer identity
            // plus a provenance context whose anchor facts match it, so every
            // session authenticated over this harness passes the terminal arm
            // (see `TestPeerIdentity`).
            provenance: TestPeerIdentity.udsProvenance(sessionManager)
        ),
        authValidator: { sessionId, capability in
            try await sessionManager.validate(
                sessionId: sessionId,
                capability: capability
            )
        },
        peerIdentityResolver: TestPeerIdentity.udsResolver,
    )
    // Wire the pane-producer seams the same way `main.swift` does, so a create
    // through the handler (which requires a concrete, tracked owner incarnation)
    // finds the session's active incarnation registered, matching production.
    await sessionManager.setPaneRevoker { sessionId in
        await paneCoordinator.revokeSubscriptions(forSession: sessionId)
    }
    await sessionManager.setPaneActivator { sessionId, incarnation in
        await paneCoordinator.noteSessionActive(sessionId, incarnation: incarnation)
    }
    try await server.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    return server
}
