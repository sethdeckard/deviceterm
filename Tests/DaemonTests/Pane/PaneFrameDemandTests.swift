// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

@Test
func frameDemandCountsConsumersIndependentlyOfEventObservers() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "demand", sessionId: UUID(), backend: backend)
    try await commitHiddenInitialFrame(coordinator, backend: backend, paneId: pane.paneId)
    #expect(backend.frameDemandChanges == [false])
    let observer = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer, frames: false)
    #expect(backend.frameDemandChanges == [false])
    let first = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    let second = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    #expect(backend.frameDemandChanges == [false, true, true])
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: first.subscriptionId)
    #expect(backend.frameDemandChanges == [false, true, true])
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: second.subscriptionId)
    #expect(backend.frameDemandChanges == [false, true, true, false])
    #expect(backend.stopDisplayOrientationCalls == 0)
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: observer.subscriptionId)
    #expect(backend.frameDemandChanges == [false, true, true, false])
}

@Test
func eventOnlySubscribersReceiveOrientationWithoutSurfaceReplay() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "events", sessionId: UUID(), backend: backend)
    let observer = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer, frames: false)
    var iterator = observer.stream.makeAsyncIterator()
    guard case .stateChanged? = await iterator.next() else {
        Issue.record("missing lifecycle replay")
        return
    }
    guard case .orientationChanged? = await iterator.next() else {
        Issue.record("missing orientation replay")
        return
    }
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: observer.subscriptionId)
    #expect(await iterator.next() == nil)
}

@Test
func legacyPaneSubscriptionsDefaultToFrames() throws {
    let legacy = try JSONDecoder().decode(
        PaneMethods.SubscribeParams.self,
        from: JSONEncoder().encode(["paneId": UUID().uuidString])
    )
    #expect(legacy.frames == nil)
    let explicit = PaneMethods.SubscribeParams(paneId: UUID().uuidString, frames: false)
    let decoded = try JSONDecoder().decode(
        PaneMethods.SubscribeParams.self, from: JSONEncoder().encode(explicit)
    )
    #expect(decoded.frames == false)
}

@Test
func revokingTheLastFrameConsumerSuspendsCapture() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let owner = UUID()
    let pane = try await coordinator.createMockPane(udid: "revoked", sessionId: owner, backend: backend)
    try await commitHiddenInitialFrame(coordinator, backend: backend, paneId: pane.paneId)
    _ = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer, frames: false)
    _ = try await coordinator.subscribe(paneId: pane.paneId, as: .session(owner))
    #expect(backend.frameDemandChanges == [false, true])
    await coordinator.revokeSubscriptions(forSession: owner)
    #expect(backend.frameDemandChanges == [false, true, false])
}

/// Await lifecycle delivery so the assertion observes the committed first frame.
private func commitHiddenInitialFrame(
    _ coordinator: PaneCoordinator, backend: MockDeviceBackend, paneId: UUID
) async throws {
    #expect(backend.frameDemandChanges.isEmpty)
    let observer = try await coordinator.subscribe(paneId: paneId, as: .guiPeer, frames: false)
    let surface = RetainedSurface(try #require(SurfaceCopy.makeSurface(width: 4, height: 4)))
    let publish = try #require(backend.onSurface)
    publish(PublishedSurface(owned: LeasedSurface(surface: surface), lease: nil))
    for await event in observer.stream {
        if case .stateChanged(_, .rendering) = event { break }
    }
    #expect(await coordinator.subscriberCount(paneId: paneId) == 1)
    #expect(backend.frameDemandChanges == [false])
    await coordinator.unsubscribe(paneId: paneId, subscriptionId: observer.subscriptionId)
}

@Test
func hiddenPaneCapturesUntilItsFirstCommittedFrame() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let owner = UUID()
    let pane = try await coordinator.createMockPane(udid: "hidden-boot", sessionId: owner, backend: backend)
    #expect(await coordinator.panesForSession(owner).first?.state == .booting)
    try await commitHiddenInitialFrame(coordinator, backend: backend, paneId: pane.paneId)
    #expect(await coordinator.panesForSession(owner).first?.state == .rendering)
}
