// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// PaneSubscriptionRegistry: the single fan-out point for pane events,
// keyed by `(paneId, connectionId)`. The registry carries two lanes:
// the JSON-event continuation, covered here, and the side-band surface
// lane, whose lease wiring is covered in `SurfaceLeaseWiringTests`.
//
// Tests pin: register/unregister round-trip; per-pane fan-out;
// per-connection sweep (the XPC connection actor's invalidation
// hook); event delivery; subscriber-count diagnostics.

@Test
func registerReturnsDistinctIds() async {
    let registry = PaneSubscriptionRegistry()
    let paneA = UUID()
    let (_, contA) = AsyncStream<PaneEvent>.makeStream()
    let (_, contB) = AsyncStream<PaneEvent>.makeStream()
    let idA = await registry.register(
        paneId: paneA,
        connectionId: 1,
        continuation: contA
    )
    let idB = await registry.register(
        paneId: paneA,
        connectionId: 1,
        continuation: contB
    )
    #expect(idA != idB)
    let count = await registry.subscriberCount(paneId: paneA)
    #expect(count == 2)
}

@Test
func unregisterDropsTheRightSubscription() async {
    let registry = PaneSubscriptionRegistry()
    let paneA = UUID()
    let (_, contA) = AsyncStream<PaneEvent>.makeStream()
    let (_, contB) = AsyncStream<PaneEvent>.makeStream()
    let idA = await registry.register(
        paneId: paneA,
        connectionId: 1,
        continuation: contA
    )
    _ = await registry.register(
        paneId: paneA,
        connectionId: 1,
        continuation: contB
    )

    await registry.unregister(subscriptionId: idA)
    let count = await registry.subscriberCount(paneId: paneA)
    #expect(count == 1)
}

@Test
func dropAllForConnectionRemovesEveryMatchingEntry() async {
    let registry = PaneSubscriptionRegistry()
    let paneA = UUID()
    let paneB = UUID()
    let (_, contA) = AsyncStream<PaneEvent>.makeStream()
    let (_, contB) = AsyncStream<PaneEvent>.makeStream()
    let (_, contC) = AsyncStream<PaneEvent>.makeStream()
    _ = await registry.register(
        paneId: paneA,
        connectionId: 100,
        continuation: contA
    )
    _ = await registry.register(
        paneId: paneB,
        connectionId: 100,
        continuation: contB
    )
    _ = await registry.register(
        paneId: paneB,
        connectionId: 200,
        continuation: contC
    )
    var count100 = await registry.subscriberCount(connectionId: 100)
    var count200 = await registry.subscriberCount(connectionId: 200)
    #expect(count100 == 2)
    #expect(count200 == 1)

    await registry.dropAllForConnection(connectionId: 100)

    count100 = await registry.subscriberCount(connectionId: 100)
    count200 = await registry.subscriberCount(connectionId: 200)
    let countA = await registry.subscriberCount(paneId: paneA)
    let countB = await registry.subscriberCount(paneId: paneB)
    #expect(count100 == 0)
    #expect(count200 == 1)
    #expect(countA == 0)
    #expect(countB == 1)
}

@Test
func yieldEventFansToEverySubscriberOnPane() async {
    let registry = PaneSubscriptionRegistry()
    let paneA = UUID()
    let (streamA, contA) = AsyncStream<PaneEvent>.makeStream()
    let (streamB, contB) = AsyncStream<PaneEvent>.makeStream()
    _ = await registry.register(
        paneId: paneA,
        connectionId: 1,
        continuation: contA
    )
    _ = await registry.register(
        paneId: paneA,
        connectionId: 2,
        continuation: contB
    )
    let event = PaneEvent.stateChanged(paneId: paneA, state: .rendering)
    await registry.yieldEvent(paneId: paneA, event: event)

    var iterA = streamA.makeAsyncIterator()
    var iterB = streamB.makeAsyncIterator()
    #expect(eventKind(await iterA.next()) == "stateChanged")
    #expect(eventKind(await iterB.next()) == "stateChanged")
}

@Test
func yieldEventIgnoresOtherPanes() async {
    let registry = PaneSubscriptionRegistry()
    let paneA = UUID()
    let paneB = UUID()
    let (streamA, contA) = AsyncStream<PaneEvent>.makeStream()
    _ = await registry.register(
        paneId: paneA,
        connectionId: 1,
        continuation: contA
    )
    let foreign = PaneEvent.stateChanged(paneId: paneB, state: .rendering)
    await registry.yieldEvent(paneId: paneB, event: foreign)
    // Pane A's stream should not receive the pane-B event. We
    // yield a sentinel event for pane A and check that the pane
    // id on the first observed event matches pane A, not the
    // foreign pane.
    let sentinel = PaneEvent.stateChanged(paneId: paneA, state: .booting)
    await registry.yieldEvent(paneId: paneA, event: sentinel)
    var iterA = streamA.makeAsyncIterator()
    let firstOnA = await iterA.next()
    #expect(observedPaneId(firstOnA) == paneA)
}

// MARK: - Helpers

/// Map a `PaneEvent` to a short string tag for assertion
/// convenience. `PaneEvent` isn't `Equatable` in the daemon
/// (it carries non-equatable IOSurface payloads), but the tests
/// only need to confirm the case discriminator round-trips
/// through the registry.
private func eventKind(_ event: PaneEvent?) -> String {
    switch event {
    case .none:
        return "nil"

    case .stateChanged:
        return "stateChanged"

    case .surfaceChanged:
        return "surfaceChanged"

    case .orientationChanged:
        return "orientationChanged"
    }
}

private func observedPaneId(_ event: PaneEvent?) -> UUID? {
    switch event {
    case .none:
        return nil

    case let .stateChanged(paneId, _):
        return paneId

    case let .surfaceChanged(paneId, _):
        return paneId

    case let .orientationChanged(paneId, _):
        return paneId
    }
}
