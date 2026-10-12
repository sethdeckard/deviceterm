// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// `input.changed`: whether a pane's input is reaching its device, worked out
// from the backend's transport and the pane's contact lane.

/// Every input state a stream carried, in order.
private func publishedInputStates(_ stream: PaneEventStream) async -> [InputHealth] {
    var states: [InputHealth] = []
    for await event in stream {
        if case let .inputChanged(_, health) = event { states.append(health) }
    }
    return states
}

private struct InputHealthPane {
    let coordinator: PaneCoordinator
    let backend: MockDeviceBackend
    let paneId: UUID
}

private func makePane(_ udid: String) async throws -> InputHealthPane {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: udid, sessionId: UUID(), backend: backend)
    return InputHealthPane(coordinator: coordinator, backend: backend, paneId: pane.paneId)
}

@Test
func aStallAndItsClearingReachTheSubscriber() async throws {
    let pane = try await makePane("input-stall")
    let (subscriptionId, stream) = try await pane.coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    pane.backend.inputRefusing = true
    await pane.coordinator.refreshInputHealth(paneId: pane.paneId)
    pane.backend.inputRefusing = false
    await pane.coordinator.refreshInputHealth(paneId: pane.paneId)
    await pane.coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)
    #expect(await publishedInputStates(stream) == [.stalled, .ok])
}

@Test
func anUnchangedInputStateIsPublishedOnce() async throws {
    // Repeated refreshes with unchanged health must not publish duplicate events.
    let pane = try await makePane("input-steady")
    let (subscriptionId, stream) = try await pane.coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    pane.backend.inputRefusing = true
    await pane.coordinator.refreshInputHealth(paneId: pane.paneId)
    await pane.coordinator.refreshInputHealth(paneId: pane.paneId)
    await pane.coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)
    #expect(await publishedInputStates(stream) == [.stalled])
}

@Test
func aLateSubscriberIsToldOfAStall() async throws {
    // A GUI that reconnects mid-stall would otherwise show a healthy pane.
    let pane = try await makePane("input-replay")
    pane.backend.inputRefusing = true
    await pane.coordinator.refreshInputHealth(paneId: pane.paneId)
    let (subscriptionId, stream) = try await pane.coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    await pane.coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)
    #expect(await publishedInputStates(stream) == [.stalled])
}

@Test
func aHealthyPaneReplaysNoInputState() async throws {
    // A subscriber starts from `ok`, and an older CLI waiting on a surface
    // treats an event name it doesn't know as an error.
    let pane = try await makePane("input-healthy")
    let (subscriptionId, stream) = try await pane.coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    await pane.coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)
    #expect(await publishedInputStates(stream).isEmpty)
}

@Test
func anInputStateEventEncodesItsState() throws {
    let envelope = try #require(
        encodeSubscriptionEvent(.inputChanged(paneId: UUID(), health: .stalled), paneId: "p1")
    )
    #expect(envelope.method == PaneEventName.inputChanged.rawValue)
    let decoded = try JSONDecoder().decode(InputChangedEvent.self, from: envelope.params)
    #expect(decoded == InputChangedEvent(paneId: "p1", state: .stalled))
}
