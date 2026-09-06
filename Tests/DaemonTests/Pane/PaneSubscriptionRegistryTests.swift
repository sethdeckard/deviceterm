// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// PaneSubscriptionRegistry: the single fan-out point for the side-band
// surface lane, indexed by pane and by connection. JSON pane events fan out
// inside `PaneCoordinator` instead, so nothing here carries them.
//
// Tests pin: registration under caller-provided ids; unregister targeting;
// the per-connection sweep the XPC connection actor calls on invalidation;
// subscriber-count diagnostics. The lease wiring on this same lane is
// covered in `SurfaceLeaseWiringTests`.

/// A subscription registers under an id its caller mints, so two ids on one
/// pane are two entries rather than one overwriting the other.
@Test
func distinctIdsOnOnePaneRegisterSeparately() async {
    let registry = PaneSubscriptionRegistry()
    let paneA = UUID()
    await registry.registerSurfaceDelivery(
        paneId: paneA,
        connectionId: 1,
        subscriptionId: UUID(),
        surfaceDelivery: { _ in }
    )
    await registry.registerSurfaceDelivery(
        paneId: paneA,
        connectionId: 1,
        subscriptionId: UUID(),
        surfaceDelivery: { _ in }
    )
    let count = await registry.subscriberCount(paneId: paneA)
    #expect(count == 2)
}

/// The two entries sit on distinct connections so the survivor is
/// identifiable. Sharing a connection would leave a count the wrong drop
/// satisfies just as well.
@Test
func unregisterDropsTheRightSubscription() async {
    let registry = PaneSubscriptionRegistry()
    let paneA = UUID()
    let idA = UUID()
    await registry.registerSurfaceDelivery(
        paneId: paneA,
        connectionId: 1,
        subscriptionId: idA,
        surfaceDelivery: { _ in }
    )
    await registry.registerSurfaceDelivery(
        paneId: paneA,
        connectionId: 2,
        subscriptionId: UUID(),
        surfaceDelivery: { _ in }
    )

    await registry.unregister(subscriptionId: idA)

    let count = await registry.subscriberCount(paneId: paneA)
    let droppedRemains = await registry.hasEntry(paneId: paneA, connectionId: 1)
    let survivorRemains = await registry.hasEntry(paneId: paneA, connectionId: 2)
    #expect(count == 1)
    #expect(!droppedRemains)
    #expect(survivorRemains)
}

@Test
func dropAllForConnectionRemovesEveryMatchingEntry() async {
    let registry = PaneSubscriptionRegistry()
    let paneA = UUID()
    let paneB = UUID()
    await registry.registerSurfaceDelivery(
        paneId: paneA,
        connectionId: 100,
        subscriptionId: UUID(),
        surfaceDelivery: { _ in }
    )
    await registry.registerSurfaceDelivery(
        paneId: paneB,
        connectionId: 100,
        subscriptionId: UUID(),
        surfaceDelivery: { _ in }
    )
    await registry.registerSurfaceDelivery(
        paneId: paneB,
        connectionId: 200,
        subscriptionId: UUID(),
        surfaceDelivery: { _ in }
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
