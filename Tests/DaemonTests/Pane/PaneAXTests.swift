// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import Daemon
import DaemonProtocol
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

// MARK: - Coordinator-level: coordinate mapping

@Test("a point query follows the pane's own orientation")
func accessibilityElementFollowsThePanesOrientation() async throws {
    // `AXSweepTests` pins the transform; this pins that the coordinator
    // hands it the pane's live orientation rather than a constant. The
    // same displayed coordinate has to reach two different panel points
    // before and after the device turns.
    //
    // The fixture is a control whose interface frame is
    // {x: 232, y: 298, w: 100, h: 24} against an 874×402 landscape root,
    // so its displayed centre is (282/874, 310/402) and the panel it
    // sits on is 402×874.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    backend.frontmostTree = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 402, "h": 874],
        "children": []
    ]
    let result = try await coordinator.createMockPane(
        udid: "udid-ax-orientation",
        sessionId: UUID(),
        backend: backend
    )
    let centre = (x: 282.0 / 874.0, y: 310.0 / 402.0)

    // Portrait first: the pane starts there, and the transform is the
    // identity, so the query scales against the root frame as it reads.
    _ = try await coordinator.accessibilityElement(
        paneId: result.paneId,
        as: .guiPeer,
        x: centre.x,
        y: centre.y
    )
    let inPortrait = try #require(backend.accessibilityPoints.last)
    #expect(abs(inPortrait.x - centre.x * 402) < 0.001)
    #expect(abs(inPortrait.y - centre.y * 874) < 0.001)

    // Turn the device. The tree now reports the interface transposed,
    // as the real bridge does, while the panel underneath is unchanged.
    backend.frontmostTree = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 874, "h": 402],
        "children": []
    ]
    let (subscriptionId, stream) = try await coordinator.subscribe(
        paneId: result.paneId,
        as: .guiPeer
    )
    backend.emitDisplayOrientation(.landscapeLeft)
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(2))
        await coordinator.unsubscribe(paneId: result.paneId, subscriptionId: subscriptionId)
    }
    var turned = false
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event, orientation == .landscapeLeft {
            turned = true
            break
        }
    }
    watchdog.cancel()
    #expect(turned, "the rotation never reached the pane")

    _ = try await coordinator.accessibilityElement(
        paneId: result.paneId,
        as: .guiPeer,
        x: centre.x,
        y: centre.y
    )
    let inLandscape = try #require(backend.accessibilityPoints.last)
    #expect(
        abs(inLandscape.x - 92) < 0.001 && abs(inLandscape.y - 282) < 0.001,
            "landscape query hit \(inLandscape); unrotated it would hit (282.0, 310.0)"
        )
    await coordinator.unsubscribe(paneId: result.paneId, subscriptionId: subscriptionId)
}

@Test("a point query reads the orientation beside the tree, not before")
func accessibilityElementReadsOrientationBesideTheTree() async throws {
    // The orientation and the tree have to describe one screen. The AX
    // queue is shared with `sweep`, so a read can wait on it for as long
    // as a whole grid walk, and a value captured before that wait can be
    // stale by the time the tree is read.
    //
    // The fake turns the device as the tree is read, which is the moment
    // the two designs diverge: a query that sampled earlier maps through
    // portrait, one that reads beside the tree maps through landscape.
    let backend = MockDeviceBackend()
    backend.frontmostTree = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 874, "h": 402],
        "children": []
    ]
    backend.onFrontmostTree = { [weak backend] in backend?.displayOrientation = .landscapeLeft }

    _ = try await PaneAccessibility.element(
        backend: backend,
        queue: BlockingWorkQueue(label: "com.deviceterm.test.pane-ax"),
        paneId: UUID(),
        orientation: { backend.displayOrientation ?? .portrait },
        x: 282.0 / 874.0,
        y: 310.0 / 402.0
    )
    let queried = try #require(backend.accessibilityPoints.last)
    #expect(
        abs(queried.x - 92) < 0.001 && abs(queried.y - 282) < 0.001,
            "query hit \(queried); want landscape (92.0, 282.0), not a pre-read portrait (282.0, 310.0)"
        )
}

@Test("a pane with no display source maps through its commanded orientation")
func accessibilityElementUsesTheCommandedOrientation() async throws {
    // A backend that vends no orientation source never publishes an
    // observation, so its pane turns only by command. The record is the
    // only evidence there is, and the mapping has to follow it.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    backend.displayOrientationAvailable = false
    backend.frontmostTree = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 874, "h": 402],
        "children": []
    ]
    let result = try await coordinator.createMockPane(
        udid: "udid-ax-no-source",
        sessionId: UUID(),
        backend: backend
    )
    #expect(backend.currentDisplayOrientation() == nil)
    try await coordinator.rotate(
        paneId: result.paneId,
        as: .guiPeer,
        target: .absolute(.landscapeLeft)
    )

    _ = try await coordinator.accessibilityElement(
        paneId: result.paneId,
        as: .guiPeer,
        x: 282.0 / 874.0,
        y: 310.0 / 402.0
    )
    let queried = try #require(backend.accessibilityPoints.last)
    #expect(abs(queried.x - 92) < 0.001)
    #expect(abs(queried.y - 282) < 0.001)
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
