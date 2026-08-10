// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// shim.event tests exercise the daemon's provenance-validation +
// ownership-mutation path end-to-end through the wire. The shim
// binary's own pure helpers (`detectEvent` for argv parsing,
// `resolveDevice` for the snapshot diff) are covered in
// `Tests/ShimTests/`.

// MARK: - Happy path: booted → ownership recorded

@Test
func shimBootedEventRecordsOwnership() async throws {
    let manager = SessionManager()
    let coordinator = DeviceCoordinator()
    let created = try await manager.createSession(label: "tab")
    let state = created.state
    let path = tempSocketPath(prefix: "deviceterm-shimev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        sessionManager: manager,
        deviceCoordinator: coordinator,
        existingSession: created
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    let udid = UUID().uuidString
    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "shim.event",
        body: .params(
            try paramsBytes(
            ShimMethods.EventParams(
            event: "booted",
            sessionId: state.id.uuidString,
            cap: created.capability.token,
            udid: udid,
            deviceName: "iPhone 17 Pro",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
            invokedAs: "xcrun",
            argv: ["xcrun", "simctl", "boot", udid]
        )
            )
            )
    )
        )
    let response = try client.receive()
    guard case let .result(bytes) = response.body else {
        Issue.record("expected .result, got \(response.body)")
        return
    }
    let ack = try JSONDecoder().decode(ShimMethods.EventResponse.self, from: bytes)
    #expect(ack.success)

    let owner = await coordinator.ownerSession(forUDID: udid)
    #expect(owner == state.id)
}

// MARK: - Production-shim path: auth then event on one connection

@Test
func shimEventOnFreshConnectionRequiresAuthFirst() async throws {
    // Regression guard for the production shim binary's wire flow.
    // The shim opens a fresh UDS connection per boot/shutdown
    // invocation; it must send `session.authenticate` BEFORE its
    // `shim.event` frame, otherwise the dispatcher's session-scope
    // gate silently rejects the event with `error.unauthorized`
    // and the GUI never gets pane attribution. The existing happy-
    // path test uses `startAuthenticatedHarness`, which pre-auths
    // the connection, which masks this exact regression. This test
    // exercises the raw send-auth-then-event sequence.
    let manager = SessionManager()
    let coordinator = DeviceCoordinator()
    let paneCoordinator = PaneCoordinator()
    let created = try await manager.createSession(label: "tab")
    let state = created.state
    let path = tempSocketPath(prefix: "deviceterm-shimev-unauth")
    let server = try await startServer(
        path: path,
        sessionManager: manager,
        deviceCoordinator: coordinator,
        paneCoordinator: paneCoordinator
    )
    defer { Task { await server.stop() } }
    let client = try TestClient.connect(to: path)
    defer { client.close() }

    // Step 1: send `session.authenticate` on the bare connection.
    let authParams = SessionAuthenticateParams(
        sessionId: state.id.uuidString,
        cap: created.capability.token
    )
    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: RPCMethod.sessionAuthenticate.rawValue,
        body: .params(try JSONEncoder().encode(authParams))
    )
        )
    _ = try client.receive()  // drain the auth ack

    // Step 2: send `shim.event` on the same now-authenticated
    // connection. The daemon's dispatcher sees
    // `authenticatedSession != nil` and lets the handler run.
    let udid = UUID().uuidString
    try client.send(
        RPCEnvelope(
        id: 2,
        type: .request,
        method: RPCMethod.shimEvent.rawValue,
        body: .params(
            try paramsBytes(
            ShimMethods.EventParams(
            event: "booted",
            sessionId: state.id.uuidString,
            cap: created.capability.token,
            udid: udid,
            deviceName: "iPhone 17 Pro",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
            invokedAs: "xcrun",
            argv: ["xcrun", "simctl", "boot", udid]
        )
            )
            )
    )
        )
    let response = try client.receive()
    guard case let .result(bytes) = response.body else {
        Issue.record("expected .result, got \(response.body)")
        return
    }
    let ack = try JSONDecoder().decode(ShimMethods.EventResponse.self, from: bytes)
    #expect(ack.success)
    let owner = await coordinator.ownerSession(forUDID: udid)
    #expect(owner == state.id)
}

@Test
func shimEventOnFreshConnectionWithoutAuthIsRejected() async throws {
    // The dispatcher MUST reject a session-scoped call on a
    // never-authenticated connection. Without this gate, anything
    // that knows the socket path could attribute a sim to a
    // sessionId it happens to guess. The shim's regression in the
    // wild, sending shim.event without `session.authenticate`,
    // would be papered over if this rejection ever silently
    // became permissive.
    let manager = SessionManager()
    let coordinator = DeviceCoordinator()
    let paneCoordinator = PaneCoordinator()
    let created = try await manager.createSession(label: "tab")
    let state = created.state
    let path = tempSocketPath(prefix: "deviceterm-shimev-rej")
    let server = try await startServer(
        path: path,
        sessionManager: manager,
        deviceCoordinator: coordinator,
        paneCoordinator: paneCoordinator
    )
    defer { Task { await server.stop() } }
    let client = try TestClient.connect(to: path)
    defer { client.close() }

    let udid = UUID().uuidString
    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: RPCMethod.shimEvent.rawValue,
        body: .params(
            try paramsBytes(
            ShimMethods.EventParams(
            event: "booted",
            sessionId: state.id.uuidString,
            cap: created.capability.token,
            udid: udid,
            deviceName: "iPhone 17 Pro",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
            invokedAs: "xcrun",
            argv: ["xcrun", "simctl", "boot", udid]
        )
            )
            )
    )
        )
    let response = try client.receive()
    guard case let .error(error) = response.body else {
        Issue.record(
            "expected .error from unauthenticated shim.event; got \(response.body)"
        )
        return
    }
    #expect(error.code == RPCMethodError.unauthorizedCode)
    let owner = await coordinator.ownerSession(forUDID: udid)
    #expect(owner == nil)
}

// MARK: - shutdown → ownership released

@Test
func shimShutdownEventReleasesOwnership() async throws {
    let manager = SessionManager()
    let coordinator = DeviceCoordinator()
    let created = try await manager.createSession(label: "tab")
    let state = created.state
    let udid = UUID().uuidString
    // Pre-record ownership so we can observe it get cleared.
    try await coordinator.recordOwnership(udid: udid, sessionId: state.id)
    let beforeCount = await coordinator.ownedCount
    #expect(beforeCount == 1)

    let path = tempSocketPath(prefix: "deviceterm-shimev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        sessionManager: manager,
        deviceCoordinator: coordinator,
        existingSession: created
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "shim.event",
        body: .params(
            try paramsBytes(
            ShimMethods.EventParams(
            event: "shutdown",
            sessionId: state.id.uuidString,
            cap: created.capability.token,
            udid: udid,
            deviceName: nil,
            runtime: nil,
            invokedAs: nil,
            argv: nil
        )
            )
            )
    )
        )
    _ = try client.receive()

    let owner = await coordinator.ownerSession(forUDID: udid)
    #expect(owner == nil)
    let afterCount = await coordinator.ownedCount
    #expect(afterCount == 0)
}

// MARK: - Cap mismatch: provenance rejection

@Test
func shimEventRejectsWrongCapability() async throws {
    let manager = SessionManager()
    let coordinator = DeviceCoordinator()
    let created = try await manager.createSession(label: "tab")
    let state = created.state
    let stranger = try Capability.random()
    let path = tempSocketPath(prefix: "deviceterm-shimev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        sessionManager: manager,
        deviceCoordinator: coordinator,
        existingSession: created
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "shim.event",
        body: .params(
            try paramsBytes(
            ShimMethods.EventParams(
            event: "booted",
            sessionId: state.id.uuidString,
            cap: stranger.token,
            udid: UUID().uuidString,
            deviceName: nil,
            runtime: nil,
            invokedAs: nil,
            argv: nil
        )
            )
            )
    )
        )
    let response = try client.receive()
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.unauthorizedCode)
    // No ownership recorded: the bad cap must not have side
    // effects on the daemon's state.
    let count = await coordinator.ownedCount
    #expect(count == 0)
}

// MARK: - Unknown event kind

@Test
func shimEventRejectsUnknownEventKind() async throws {
    let manager = SessionManager()
    let coordinator = DeviceCoordinator()
    let created = try await manager.createSession(label: "tab")
    let state = created.state
    let path = tempSocketPath(prefix: "deviceterm-shimev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        sessionManager: manager,
        deviceCoordinator: coordinator,
        existingSession: created
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "shim.event",
        body: .params(
            try paramsBytes(
            ShimMethods.EventParams(
            event: "erased",
            sessionId: state.id.uuidString,
            cap: created.capability.token,
            udid: UUID().uuidString,
            deviceName: nil,
            runtime: nil,
            invokedAs: nil,
            argv: nil
        )
            )
            )
    )
        )
    let response = try client.receive()
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.invalidParamsCode)
    #expect(rpcError.message.contains("booted") || rpcError.message.contains("shutdown"))
}

// MARK: - Malformed UDID

@Test
func shimEventRejectsMalformedUDID() async throws {
    let manager = SessionManager()
    let coordinator = DeviceCoordinator()
    let created = try await manager.createSession(label: "tab")
    let state = created.state
    let path = tempSocketPath(prefix: "deviceterm-shimev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        sessionManager: manager,
        deviceCoordinator: coordinator,
        existingSession: created
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "shim.event",
        body: .params(
            try paramsBytes(
            ShimMethods.EventParams(
            event: "booted",
            sessionId: state.id.uuidString,
            cap: created.capability.token,
            udid: "not-a-uuid",
            deviceName: nil,
            runtime: nil,
            invokedAs: nil,
            argv: nil
        )
            )
            )
    )
        )
    let response = try client.receive()
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.invalidParamsCode)
}
