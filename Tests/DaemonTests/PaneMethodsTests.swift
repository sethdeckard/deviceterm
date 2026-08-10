// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// Pane RPC tests cover the full server path for pane.create
// validation and pane.close / pane.subscribe error handling. Live
// sim-pane behavior is covered by `PaneCoordinatorTests` plus the
// CoreSimulatorBridge tests against a real device.

// MARK: - pane.create validation

@Test
func paneCreateRejectsUnknownKind() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let path = tempSocketPath(prefix: "deviceterm-pane")
    let harness = try await startAuthenticatedHarness(
        path: path,
        sessionManager: manager,
        existingSession: created
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.create",
        body: .params(
            try paramsBytes(
            PaneMethods.CreateParams(
            sessionId: state.id.uuidString,
            cap: created.capability.token,
            kind: "drone",
            udid: nil
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
    #expect(rpcError.message.contains("sim"))
}

@Test
func paneCreateSimRequiresUDID() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let path = tempSocketPath(prefix: "deviceterm-pane")
    let harness = try await startAuthenticatedHarness(
        path: path,
        sessionManager: manager,
        existingSession: created
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.create",
        body: .params(
            try paramsBytes(
            PaneMethods.CreateParams(
            sessionId: state.id.uuidString,
            cap: created.capability.token,
            kind: "sim",
            udid: nil
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
    #expect(rpcError.message.contains("udid"))
}

@Test
func paneCreateRejectsWrongCapability() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let stranger = try Capability.random()
    let path = tempSocketPath(prefix: "deviceterm-pane")
    let harness = try await startAuthenticatedHarness(
        path: path,
        sessionManager: manager,
        existingSession: created
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.create",
        body: .params(
            try paramsBytes(
            PaneMethods.CreateParams(
            sessionId: state.id.uuidString,
            cap: stranger.token,
            kind: "sim",
            udid: UUID().uuidString
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
}

// MARK: - pane.close validation

@Test
func paneCloseRejectsInvalidMode() async throws {
    let path = tempSocketPath(prefix: "deviceterm-pane")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    // `pane.closeById` is the daemon-internal by-paneId handler the
    // GUI Router fan-out hits; the user-facing `pane.close` verb
    // routes through the back-channel publish-verb instead. This
    // test exercises the by-paneId mode validation.
    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.closeById",
        body: .params(
            try paramsBytes(
            PaneMethods.CloseParams(
            paneId: UUID().uuidString,
            mode: "burn"
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

@Test
func paneSubscribeRejectsMalformedPaneId() async throws {
    let path = tempSocketPath(prefix: "deviceterm-pane")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.subscribe",
        body: .params(try paramsBytes(PaneMethods.SubscribeParams(paneId: "nope")))
    )
        )
    let response = try client.receive()
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.invalidParamsCode)
}
