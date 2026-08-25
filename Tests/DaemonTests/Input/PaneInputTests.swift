// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// Pane input tests cover the validation + dispatch path without
// needing a booted simulator: malformed identifiers and unknown
// enum values. The bridge-level "send an Indigo message and observe
// SpringBoard" behavior is covered by
// `CoreSimulatorBridgeTests/HIDClientTests.swift` against a real
// device when one is available.

// MARK: - Coordinator-level: unknown pane

@Test
func tapOnUnknownPaneThrowsNotFound() async throws {
    let coordinator = PaneCoordinator()
    let strayId = UUID()
    await #expect(throws: PaneError.notFound(paneId: strayId)) {
        try await coordinator.tap(paneId: strayId, as: .guiPeer, x: 0.5, y: 0.5)
    }
}

// MARK: - RPC-level: invalid identifiers

@Test
func paneTapRejectsMalformedPaneId() async throws {
    let path = tempSocketPath(prefix: "deviceterm-paneinp")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.tap",
        body: .params(
            try paramsBytes(
            TapParams(
            paneId: "nope",
            x: 0.5,
            y: 0.5
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
    #expect(rpcError.message.contains("paneId"))
}

@Test
func paneButtonRejectsUnknownButton() async throws {
    let path = tempSocketPath(prefix: "deviceterm-paneinp")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.button",
        body: .params(
            try paramsBytes(
            ButtonParams(
            paneId: UUID().uuidString,
            button: "purple"
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
    #expect(rpcError.message.contains("home") || rpcError.message.contains("lock"))
}

@Test
func paneRotateRejectsUnknownOrientation() async throws {
    let path = tempSocketPath(prefix: "deviceterm-paneinp")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.rotate",
        body: .params(
            try paramsBytes(
            RotateParams(
            paneId: UUID().uuidString,
            orientation: "sideways",
            direction: nil
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
    #expect(rpcError.message.contains("portrait"))
}

// `pane.input.rotate`'s two fields are mutually exclusive, which the
// wire shape can't express. These cover the resolver directly rather
// than through a socket: the four branches are the whole contract, and
// the round-trip above already proves the handler calls it.

@Test(
    "each form resolves to its target",
    arguments: [
        (
            RotateParams(paneId: "p1", orientation: "landscapeLeft", direction: nil),
            RotationTarget.absolute(.landscapeLeft)
        ),
        (
            RotateParams(paneId: "p1", orientation: nil, direction: "left"),
            RotationTarget.relative(.left)
        ),
        (
            RotateParams(paneId: "p1", orientation: nil, direction: "right"),
            RotationTarget.relative(.right)
        )
    ]
)
func rotationTargetResolvesEachForm(params: RotateParams, expected: RotationTarget) throws {
    #expect(try PaneMethods.rotationTarget(params) == expected)
}

@Test
func rotationTargetRejectsAnUnknownDirection() {
    let params = RotateParams(paneId: "p1", orientation: nil, direction: "widdershins")
    #expect(throws: RPCMethodError.invalidParams("direction must be one of: left, right")) {
        try PaneMethods.rotationTarget(params)
    }
}

@Test(
    "neither field and both fields are refused, not silently preferred",
    arguments: [
        (nil, nil),
        ("portrait", "left")
    ] as [(String?, String?)]
)
func rotationTargetRejectsAmbiguousRequests(orientation: String?, direction: String?) {
    // A client sending both has no idea which the daemon would honor, so
    // honoring either would rotate the device somewhere it didn't ask for.
    let params = RotateParams(paneId: "p1", orientation: orientation, direction: direction)
    #expect(throws: RPCMethodError.self) {
        try PaneMethods.rotationTarget(params)
    }
}

@Test
func paneTouchRejectsUnknownPhase() async throws {
    let path = tempSocketPath(prefix: "deviceterm-paneinp")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.touch",
        body: .params(
            try paramsBytes(
            TouchParams(
            paneId: UUID().uuidString,
            x: 0.5,
            y: 0.5,
            phase: "cancelled"
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
    #expect(rpcError.message.contains("down"))
    #expect(rpcError.message.contains("move"))
    #expect(rpcError.message.contains("up"))
}

@Test
func edgeTouchParamsRoundTripsWireKeys() throws {
    let params = EdgeTouchParams(
        paneId: "P-1",
        x: 0.5,
        y: 0.99,
        phase: "down"
    )
    let data = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(EdgeTouchParams.self, from: data)
    #expect(decoded.paneId == "P-1")
    #expect(decoded.x == 0.5)
    #expect(decoded.y == 0.99)
    #expect(decoded.phase == "down")
}

@Test
func paneSwipeRejectsExcessiveDuration() async throws {
    // Int.max as durationMs overflows UInt64 in the ns cast and traps
    // the daemon unless it is bounded first. The handler bounds at
    // `PaneCoordinator.maxGestureDurationMs` and returns invalidParams,
    // so an absurd duration is a rejected request rather than a crash.
    let path = tempSocketPath(prefix: "deviceterm-paneinp")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.swipe",
        body: .params(
            try paramsBytes(
            SwipeParams(
            paneId: UUID().uuidString,
            fromX: 0.5,
            fromY: 0.2,
            toX: 0.5,
            toY: 0.8,
            durationMs: Int.max,
            holdMs: nil,
            startHoldMs: nil
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
    #expect(rpcError.message.contains("durationMs"))

    // Daemon must still be alive, so a second request round-trips.
    let recovery = try TestClient.connect(to: path)
    defer { recovery.close() }
    try recovery.send(
        RPCEnvelope(
        id: 99,
        type: .request,
        method: "daemon.ping",
        body: .empty
    )
        )
    let ping = try recovery.receive()
    #expect(ping.id == 99)
    #expect(ping.type == .response)
}

// MARK: - Crown

@Test
func crownOnUnknownPaneThrowsNotFound() async throws {
    let coordinator = PaneCoordinator()
    let strayId = UUID()
    await #expect(throws: PaneError.notFound(paneId: strayId)) {
        try await coordinator.crown(paneId: strayId, as: .guiPeer, delta: 10, durationMs: 0)
    }
}

@Test
func paneCrownRejectsMalformedPaneId() async throws {
    let path = tempSocketPath(prefix: "deviceterm-paneinp")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.crown",
        body: .params(
            try paramsBytes(
            CrownParams(
            paneId: "nope",
            delta: 10,
            velocity: nil,
            durationMs: nil
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
    #expect(rpcError.message.contains("paneId"))
}

@Test
func paneCrownRejectsExcessiveDuration() async throws {
    let path = tempSocketPath(prefix: "deviceterm-paneinp")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.crown",
        body: .params(
            try paramsBytes(
            CrownParams(
            paneId: UUID().uuidString,
            delta: 10,
            velocity: nil,
            durationMs: Int.max
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
    #expect(rpcError.message.contains("durationMs"))
}

@Test
func paneButtonAcceptsDigitalCrown() async throws {
    // `digitalCrown` is a valid button value, so validation must pass it
    // through and fail later on the unknown pane, not reject it as an
    // unknown button. Both surface as invalidParams, so distinguish by
    // message: the unknown-pane path says "paneId", the enum-rejection
    // path says "must be one of".
    let path = tempSocketPath(prefix: "deviceterm-paneinp")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.button",
        body: .params(
            try paramsBytes(
            ButtonParams(
            paneId: UUID().uuidString,
            button: "digitalCrown"
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
    #expect(rpcError.message.contains("paneId"))
    #expect(!rpcError.message.contains("must be one of"))
}

// MARK: - panes.list

@Test
func panesListReturnsEmptyForNewSession() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let path = tempSocketPath(prefix: "deviceterm-paneinp")
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
    guard case let .result(data) = response.body else {
        Issue.record("expected .result, got \(response.body)")
        return
    }
    let entries = try JSONDecoder().decode([PaneMethods.PanesListEntry].self, from: data)
    #expect(entries.isEmpty)
}

@Test
func panesListRejectsWrongCapability() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let stranger = try Capability.random()
    let path = tempSocketPath(prefix: "deviceterm-paneinp")
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
        method: "panes.list",
        body: .params(
            try paramsBytes(
            PanesListParams(
            sessionId: state.id.uuidString,
            cap: stranger.token
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

@Test
func paneLongPressRejectsNegativeDuration() async throws {
    let path = tempSocketPath(prefix: "deviceterm-paneinp")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.longPress",
        body: .params(
            try paramsBytes(
            LongPressParams(
            paneId: UUID().uuidString,
            x: 0.5,
            y: 0.5,
            durationMs: -10
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
    #expect(rpcError.message.contains("non-negative"))
}

// MARK: - panes.list incarnation pinning

@Test
func panesListPinsTheCallerToItsDispatchCapturedIncarnation() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let sessionId = created.state.id
    let incarnation = try #require(await manager.incarnation(of: sessionId))
    let coordinator = PaneCoordinator()
    await coordinator.noteSessionActive(sessionId, incarnation: incarnation)
    _ = try await coordinator.createPane(
        target: .sim(udid: "udid-pin"),
        sessionId: sessionId,
        ownerIncarnation: incarnation,
        acquire: {
            PaneCoordinator.AcquiredBackend(
                backend: MockDeviceBackend(),
                family: "phone",
                deviceType: "iPhone"
            )
        }
    )
    let handler = PaneMethods.panesList(paneCoordinator: coordinator, sessionManager: manager)
    let params = try JSONEncoder().encode(
        PanesListParams(sessionId: sessionId.uuidString, cap: created.capability.token)
    )
    func list(pinnedTo captured: UInt64?) async throws -> [PaneMethods.PanesListEntry] {
        let context = DispatchPeerContext(
            transport: .uds,
            connectionId: 1,
            authenticatedSession: created.state,
            sessionIncarnation: captured
        )
        let data = try await DispatchPeerContext.$current.withValue(context) {
            try await handler(params)
        }
        return try JSONDecoder().decode([PaneMethods.PanesListEntry].self, from: data)
    }

    #expect(try await list(pinnedTo: incarnation).count == 1)
    // A request admitted under an earlier incarnation can resume after the
    // same UUID was reaped and restored. Its dispatch-captured pin no longer
    // matches, so the restored session's panes stay invisible to it; a fresh
    // manager read here would hand the old caller the new authority instead.
    #expect(try await list(pinnedTo: incarnation &+ 7).isEmpty)
    // No captured pin means an un-incarnation-pinned caller (a manager that
    // doesn't track incarnations), listed by UUID owner match exactly as its
    // control calls would authorize.
    #expect(try await list(pinnedTo: nil).count == 1)
}
