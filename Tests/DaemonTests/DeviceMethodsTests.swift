// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
@testable import Daemon
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// Device RPC tests exercise the full server path: framing, dispatch,
// and the DeviceCoordinator + CoreSimulatorBridge wiring underneath.
// Live cases require a host with CoreSimulator loadable; pure error-
// path cases run everywhere.

private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

// MARK: - Pure error paths

@Test
func deviceListRejectsUnknownScope() async throws {
    let coordinator = DeviceCoordinator()
    let path = tempSocketPath(prefix: "deviceterm-dev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        deviceCoordinator: coordinator
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "device.list",
        body: .params(try paramsBytes(DeviceMethods.ListParams(scope: "neither")))
    )
        )
    let response = try client.receive()
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.invalidParamsCode)
    #expect(rpcError.message.contains("scope"))
}

@Test
func deviceBootRejectsCapWithoutSessionId() async throws {
    // The optional-session attribution on device.boot is all-or-
    // nothing: a `cap` field without a matching `sessionId` is
    // either a buggy caller or a probe attempt. Reject it before we
    // pay for any coordinator round-trip.
    let coordinator = DeviceCoordinator()
    let path = tempSocketPath(prefix: "deviceterm-dev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        deviceCoordinator: coordinator
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    let stranger = try Capability.random()
    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "device.boot",
        body: .params(
            try paramsBytes(
            DeviceMethods.BootParams(
            udid: UUID().uuidString,
            sessionId: nil,
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
    #expect(rpcError.code == RPCMethodError.invalidParamsCode)
}

@Test
func deviceBootRejectsSessionIdWithoutCap() async throws {
    let coordinator = DeviceCoordinator()
    let path = tempSocketPath(prefix: "deviceterm-dev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        deviceCoordinator: coordinator
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "device.boot",
        body: .params(
            try paramsBytes(
            DeviceMethods.BootParams(
            udid: UUID().uuidString,
            sessionId: UUID().uuidString,
            cap: nil
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
func deviceBootRejectsWrongCapability() async throws {
    let coordinator = DeviceCoordinator()
    let sessionManager = SessionManager()
    let state = try await sessionManager.createSession(label: nil).state
    let path = tempSocketPath(prefix: "deviceterm-dev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        sessionManager: sessionManager,
        deviceCoordinator: coordinator
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    let stranger = try Capability.random()
    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "device.boot",
        body: .params(
            try paramsBytes(
            DeviceMethods.BootParams(
            udid: UUID().uuidString,
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
func deviceBootRejectsEmptyUDID() async throws {
    let coordinator = DeviceCoordinator()
    let path = tempSocketPath(prefix: "deviceterm-dev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        deviceCoordinator: coordinator
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "device.boot",
        body: .params(try paramsBytes(DeviceMethods.BootParams(udid: "")))
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
func deviceShutdownRejectsBlankUDID() async throws {
    let coordinator = DeviceCoordinator()
    let path = tempSocketPath(prefix: "deviceterm-dev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        deviceCoordinator: coordinator
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "device.shutdown",
        body: .params(try paramsBytes(DeviceMethods.ShutdownParams(udid: "   ")))
    )
        )
    let response = try client.receive()
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCMethodError.invalidParamsCode)
}

// MARK: - Shutdown convergence

@Test
func shutdownConvergedRethrowsUnderlyingDeviceError() async throws {
    // A malformed udid makes coordinator.shutdown throw before any
    // CoreSimulator call, so this runs on every host. shutdownConverged
    // must rethrow that error (the device.shutdown RPC still has to
    // report the failure) while having taken the already-stopped branch
    // (isBooted() check + markPanesShutdown) without crashing. The
    // pane-transition half (a real pane flipping to .shutdown) needs a
    // live sim and is covered by the manual app-shell checklist.
    let coordinator = DeviceCoordinator()
    let paneCoordinator = PaneCoordinator()
    await #expect(throws: DeviceError.malformedUDID(udid: "not-a-uuid")) {
        try await DeviceMethods.shutdownConverged(
            udid: "not-a-uuid",
            coordinator: coordinator,
            paneCoordinator: paneCoordinator
        )
    }
}

// MARK: - State name vocabulary

@Test
func stateNameMapsAllKnownCases() {
    #expect(DeviceMethods.stateName(.creating) == "Creating")
    #expect(DeviceMethods.stateName(.shutdown) == "Shutdown")
    #expect(DeviceMethods.stateName(.booting) == "Booting")
    #expect(DeviceMethods.stateName(.booted) == "Booted")
    #expect(DeviceMethods.stateName(.shuttingDown) == "ShuttingDown")
    #expect(DeviceMethods.stateName(.unknown) == "Unknown")
}

// MARK: - Live RPC

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveDeviceListAllReturnsBareArray() async throws {
    // The result body is JSON `[…]`, not `{"devices": […]}`, matching
    // tabs.list's wire shape and the canonical schema in
    // docs/ARCHITECTURE.md.
    let coordinator = DeviceCoordinator()
    let path = tempSocketPath(prefix: "deviceterm-dev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        deviceCoordinator: coordinator
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "device.list",
        body: .params(try paramsBytes(DeviceMethods.ListParams(scope: "all")))
    )
        )
    let response = try client.receive()
    guard case let .result(bytes) = response.body else {
        Issue.record("expected .result, got \(response.body)")
        return
    }
    let parsed = try JSONSerialization.jsonObject(with: bytes)
    #expect(parsed is [Any], "device.list result should be a bare array")
    let entries = try JSONDecoder().decode([DeviceMethods.ListEntry].self, from: bytes)
    #expect(!entries.isEmpty)
    for entry in entries {
        #expect(!entry.udid.isEmpty)
        #expect(!entry.name.isEmpty)
        // ownedBySession should be nil for a fresh coordinator:
        // we haven't recorded anything.
        #expect(entry.ownedBySession == nil)
    }
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveDeviceListOwnedFiltersByOwnership() async throws {
    let coordinator = DeviceCoordinator()
    // Find a real UDID and claim it before sending the RPC.
    let all = try await coordinator.listAll()
    guard let pick = all.first else {
        Issue.record("host has no devices to fixture against")
        return
    }
    let sessionId = UUID()
    try await coordinator.recordOwnership(udid: pick.udid, sessionId: sessionId)

    let path = tempSocketPath(prefix: "deviceterm-dev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        deviceCoordinator: coordinator
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "device.list",
        body: .params(try paramsBytes(DeviceMethods.ListParams(scope: "owned")))
    )
        )
    let response = try client.receive()
    guard case let .result(bytes) = response.body else {
        Issue.record("expected .result, got \(response.body)")
        return
    }
    let entries = try JSONDecoder().decode([DeviceMethods.ListEntry].self, from: bytes)
    #expect(entries.count == 1)
    #expect(entries.first?.udid.lowercased() == pick.udid.lowercased())
    #expect(entries.first?.ownedBySession == sessionId.uuidString)
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveDeviceBootRejectsUnknownUDID() async throws {
    // Well-formed-looking UDID that doesn't exist in CoreSimulator's
    // device set. Maps from DeviceError.notFound to invalidParams on
    // the wire.
    let coordinator = DeviceCoordinator()
    let path = tempSocketPath(prefix: "deviceterm-dev")
    let harness = try await startAuthenticatedHarness(
        path: path,
        deviceCoordinator: coordinator
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "device.boot",
        body: .params(
            try paramsBytes(
            DeviceMethods.BootParams(
            udid: "DEADBEEF-DEAD-DEAD-DEAD-DEADBEEFDEAD"
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
