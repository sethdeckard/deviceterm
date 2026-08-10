// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// Pinch + text round out the pane.input surface. Same testing
// shape as the other input methods: pure error paths + ASCII
// keymap coverage. Live gesture/keystroke behavior against a real
// sim is covered by the bridge's HIDClientTests.

// MARK: - ASCII keymap coverage

@Test
func asciiKeyMapCoversLettersDigitsCommonPunctuation() {
    let map = KeyboardInputMap.asciiKeyMap
    for character in "abcdefghijklmnopqrstuvwxyz" {
        #expect(map[character] != nil, "lowercase '\(character)' must be mapped")
        #expect(map[character]?.shift == false)
    }
    for character in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
        #expect(map[character] != nil, "uppercase '\(character)' must be mapped")
        #expect(map[character]?.shift == true)
    }
    for character in "0123456789" {
        #expect(map[character] != nil, "digit '\(character)' must be mapped")
        #expect(map[character]?.shift == false)
    }
    for character in "!@#$%^&*()" {
        #expect(map[character] != nil, "shifted symbol '\(character)' must be mapped")
        #expect(map[character]?.shift == true)
    }
    for character in " \n\t-_=+[]{};:'\",.<>/?\\|`~" {
        #expect(map[character] != nil, "punctuation '\(character)' must be mapped")
    }
}

@Test
func asciiKeyMapAssignsSameKeyCodeAcrossCases() {
    // Shift is the only thing that should differ between 'a' and
    // 'A'. The Indigo digitizer's case handling relies on this.
    let map = KeyboardInputMap.asciiKeyMap
    for lower in "abcdefghijklmnopqrstuvwxyz" {
        guard let upper = lower.uppercased().first else { continue }
        #expect(
            map[lower]?.keyCode == map[upper]?.keyCode,
                "'\(lower)' and '\(upper)' must share a keyCode"
            )
    }
}

// MARK: - Coordinator-level error paths

@Test
func textOnUnknownPaneThrowsNotFound() async throws {
    let coordinator = PaneCoordinator()
    let strayId = UUID()
    await #expect(throws: PaneError.notFound(paneId: strayId)) {
        try await coordinator.text(paneId: strayId, as: .guiPeer, text: "x")
    }
}

// MARK: - RPC: validation

@Test
func paneInputPinchRejectsMalformedPaneId() async throws {
    let path = tempSocketPath(prefix: "deviceterm-pinch")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.pinch",
        body: .params(
            try paramsBytes(
            PinchParams(
            paneId: "nope",
            fromF1X: 0.4,
            fromF1Y: 0.5,
            fromF2X: 0.6,
            fromF2Y: 0.5,
            toF1X: 0.3,
            toF1Y: 0.5,
            toF2X: 0.7,
            toF2Y: 0.5,
            durationMs: 200
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
func paneInputPinchRejectsExcessiveDuration() async throws {
    // Same overflow-safety contract as swipe/longPress.
    let path = tempSocketPath(prefix: "deviceterm-pinch")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.pinch",
        body: .params(
            try paramsBytes(
            PinchParams(
            paneId: UUID().uuidString,
            fromF1X: 0.4,
            fromF1Y: 0.5,
            fromF2X: 0.6,
            fromF2Y: 0.5,
            toF1X: 0.3,
            toF1Y: 0.5,
            toF2X: 0.7,
            toF2Y: 0.5,
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
func paneInputTextRejectsMalformedPaneId() async throws {
    let path = tempSocketPath(prefix: "deviceterm-pinch")
    let harness = try await startAuthenticatedHarness(path: path)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "pane.input.text",
        body: .params(
            try paramsBytes(
            TextParams(
            paneId: "still-nope",
            text: "hello"
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
func unsupportedCharacterMapsToInvalidParams() {
    // unsupportedCharacter is the coordinator's signal for "not in
    // the ASCII keymap"; the RPC layer maps it to invalidParams
    // with the offending character in the message so the caller
    // can fix or split.
    let mapped = PaneMethods.mapPaneError(
        .unsupportedCharacter(paneId: UUID(), character: "é")
    )
    #expect(mapped.code == RPCMethodError.invalidParamsCode)
    #expect(mapped.message.contains("é"))
}
