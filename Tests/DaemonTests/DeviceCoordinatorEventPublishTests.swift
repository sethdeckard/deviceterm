// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// DeviceCoordinator × EventBroker: pins the publish wiring for
// BOTH lifecycle paths:
//
//   - Direct daemon RPC `device.boot` / `device.shutdown` → calls
//     `boot(...)` / `shutdown(...)` directly. Tested via
//     reflection-on-a-real-coordinator below (those methods also
//     hit CoreSimulator, so we don't cover them in unit-tests).
//
//   - Shim-detected in-tab boot/shutdown → ShimMethods calls
//     `recordOwnership(...)` / `releaseOwnership(udid:)`. THESE are
//     the load-bearing path: without
//     publishing here, the primary in-tab workflow (`xcrun simctl
//     boot` inside the tab) would never emit `device.booted` to
//     `deviceterm events` subscribers.

private let validUDID = "11111111-1111-1111-1111-111111111111"

@Test
func recordOwnershipPublishesDeviceBooted() async throws {
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    try await coordinator.recordOwnership(
        udid: validUDID,
        sessionId: UUID()
    )

    var iterator = stream.makeAsyncIterator()
    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.deviceBooted)
    #expect(event.udid == validUDID.lowercased())

    await broker.unsubscribe(subscriptionId)
}

@Test
func recordOwnershipPublishesEvenOnReclaim() async throws {
    // A session-B reclaim of a session-A-owned UDID corresponds to
    // a fresh shim-intercepted boot, so the publish must fire even
    // though the ownership map already had an entry.
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker)

    // First record (session A): drain its event so the iterator
    // starts on the second.
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)
    try await coordinator.recordOwnership(
        udid: validUDID,
        sessionId: UUID()
    )
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()

    // Reclaim by session B.
    try await coordinator.recordOwnership(
        udid: validUDID,
        sessionId: UUID()
    )
    let secondEvent = try #require(await iterator.next())
    #expect(secondEvent.type == DaemonEventType.deviceBooted)

    await broker.unsubscribe(subscriptionId)
}

@Test
func releaseOwnershipPublishesDeviceShutdown() async throws {
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker)
    try await coordinator.recordOwnership(
        udid: validUDID,
        sessionId: UUID()
    )
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    await coordinator.releaseOwnership(udid: validUDID)

    var iterator = stream.makeAsyncIterator()
    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.deviceShutdown)
    #expect(event.udid == validUDID.lowercased())

    await broker.unsubscribe(subscriptionId)
}

@Test
func releaseOwnershipPublishesEvenWithoutPriorRecord() async throws {
    // Shim-detected shutdown for a UDID we didn't track. The
    // shim's view is truth; publish anyway.
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    await coordinator.releaseOwnership(udid: validUDID)

    var iterator = stream.makeAsyncIterator()
    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.deviceShutdown)

    await broker.unsubscribe(subscriptionId)
}

@Test
func deviceCoordinatorWorksWithoutBroker() async throws {
    // Default initializer keeps broker nil. Tests that don't care
    // stay terse; production wires the broker via DeviceTermDaemon.
    let coordinator = DeviceCoordinator()
    try await coordinator.recordOwnership(
        udid: validUDID,
        sessionId: UUID()
    )
    await coordinator.releaseOwnership(udid: validUDID)
}
