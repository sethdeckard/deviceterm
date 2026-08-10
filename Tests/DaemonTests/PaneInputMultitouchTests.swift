// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import Daemon
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// pane.input.multitouch validation: the live two-finger stream. Same
// shape as the other pane.input RPC tests: pure error paths over a real
// UDS round-trip, no live bridge. The exactly-2-points contract is the
// new constraint this method adds on top of the shared paneId/phase
// validation. Live HID behavior against a real sim is the manual track.

private func multitouchPoints(_ count: Int) -> [MultitouchPoint] {
    (0..<count).map { MultitouchPoint(id: $0, x: 0.5, y: 0.5) }
}

@Test
func multitouchOnUnknownPaneThrowsNotFound() async throws {
    let coordinator = PaneCoordinator()
    let strayId = UUID()
    await #expect(throws: PaneError.notFound(paneId: strayId)) {
        try await coordinator.multitouch(
            paneId: strayId,
            as: .guiPeer,
            phase: .down,
            points: [CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)]
        )
    }
}

@Test
func paneInputMultitouchRejectsMalformedPaneId() async throws {
    let path = tempSocketPath(prefix: "deviceterm-multitouch")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.multitouch",
        body: .params(
            try paramsBytes(
            MultitouchParams(
            paneId: "nope",
            phase: "down",
            points: multitouchPoints(2)
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

@Test(arguments: [0, 1, 3])
func paneInputMultitouchRejectsWrongPointCount(_ count: Int) async throws {
    let path = tempSocketPath(prefix: "deviceterm-multitouch")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.multitouch",
        body: .params(
            try paramsBytes(
            MultitouchParams(
            paneId: UUID().uuidString,
            phase: "move",
            points: multitouchPoints(count)
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
    #expect(rpcError.message.contains("points"))
}

@Test
func paneInputMultitouchRejectsUnknownPhase() async throws {
    let path = tempSocketPath(prefix: "deviceterm-multitouch")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.multitouch",
        body: .params(
            try paramsBytes(
            MultitouchParams(
            paneId: UUID().uuidString,
            phase: "hover",
            points: multitouchPoints(2)
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
    #expect(rpcError.message.contains("phase"))
}

@Test
func paneInputMultitouchValidRequestUnknownPaneIsRejected() async throws {
    // Well-formed paneId/phase/points but no such pane → the coordinator
    // throws notFound, mapped to invalidParams "unknown paneId".
    let path = tempSocketPath(prefix: "deviceterm-multitouch")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.multitouch",
        body: .params(
            try paramsBytes(
            MultitouchParams(
            paneId: UUID().uuidString,
            phase: "down",
            points: multitouchPoints(2)
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
    #expect(rpcError.message.contains("unknown paneId"))
}
