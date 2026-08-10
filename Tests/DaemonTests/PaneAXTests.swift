// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// AX tests cover the validation + wrapping path without needing a
// booted simulator. Bridge-level AX (frontmostTree against a real
// device, recursive children walks, AXPTranslator multi-tenant
// behavior) is covered by `CoreSimulatorBridgeTests/
// AccessibilityTests.swift` when a real device is available.

// MARK: - Coordinator-level: unknown pane

@Test
func accessibilityTreeOnUnknownPaneThrowsNotFound() async throws {
    let coordinator = PaneCoordinator()
    let strayId = UUID()
    await #expect(throws: PaneError.notFound(paneId: strayId)) {
        _ = try await coordinator.accessibilityTree(paneId: strayId, as: .guiPeer)
    }
}

// MARK: - RPC: validation

@Test
func paneAXTreeRejectsMalformedPaneId() async throws {
    let path = tempSocketPath(prefix: "deviceterm-paneax")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.ax.tree",
        body: .params(try paramsBytes(AXTreeParams(paneId: "nope")))
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
func paneAXPointRejectsMalformedPaneId() async throws {
    let path = tempSocketPath(prefix: "deviceterm-paneax")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.ax.point",
        body: .params(
            try paramsBytes(
            AXPointParams(
            paneId: "still-nope",
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
}

// MARK: - PaneError → RPCMethodError mapping

@Test
func bridgeFailedMapsToDedicatedWireCode() {
    // Wire-contract pin: a systemic bridge failure surfaces as
    // `error.bridgeFailed` (code -32020), distinct from the
    // catch-all `serverError` (-32000). Machine consumers
    // dispatch on the code field, not the message string. The
    // operation name + bridge message ride through unchanged.
    let mapped = PaneMethods.mapPaneError(
        .bridgeFailed(
        paneId: UUID(),
        operation: .axSweep,
        message: "AX server not ready"
    )
        )
    #expect(mapped.code == RPCMethodError.bridgeFailedCode)
    #expect(mapped.code != RPCErrorCode.serverError)
    #expect(mapped.message.contains("ax.sweep"))
    #expect(mapped.message.contains("AX server not ready"))
}

// MARK: - Response wrapping

@Test
func wrapAXResultProducesObjectWithKey() throws {
    // Sanity-check the helper that wraps a coordinator-side AX blob
    // into the canonical {tree: …} / {element: …} shape. Pinning
    // this means downstream clients can decode the response with a
    // small Codable struct without parsing surprises.
    let inner = try JSONSerialization.data(
        withJSONObject: ["role": "Button", "label": "OK"],
        options: []
    )
    let wrapped = try PaneMethods.wrapAXResult(key: "tree", innerJSON: inner)
    let parsed = try JSONSerialization.jsonObject(with: wrapped) as? [String: Any]
    let tree = parsed?["tree"] as? [String: Any]
    #expect(tree?["role"] as? String == "Button")
    #expect(tree?["label"] as? String == "OK")
}
