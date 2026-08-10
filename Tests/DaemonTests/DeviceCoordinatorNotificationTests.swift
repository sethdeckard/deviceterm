// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// DeviceCoordinator × CoreSimulator notifications: pins the
// debounce + ownership semantics of the two-path attribution
// model.
//
// Two paths converge on the same publish helper:
//
//   - Shim path (`recordOwnership` / `releaseOwnership`): argv
//     intercepted by the shim; ownership recorded for the calling
//     session.
//   - Notification path (`noteExternalBoot` / `noteExternalShutdown`):
//     fed by `CSBDeviceNotifier` so the daemon also sees boots
//     the shim missed (xcodebuild, Simulator.app, absolute-path
//     `/usr/bin/xcrun simctl boot`, FFI callers, pre-existing
//     boots). External boots do NOT bind ownership, so those sims
//     stay claimable via `deviceterm device attach`.
//
// Without the debounce the two paths would double-publish when
// the same transition appears via both routes; the shim usually
// wins by ~tens of ms, but the reverse ordering happens too
// (e.g. notification dispatched before the shim's UDS round-trip
// completes). Either ordering produces exactly one event.

private let validUDID = "11111111-1111-1111-1111-111111111111"
private let otherUDID = "22222222-2222-2222-2222-222222222222"

// MARK: - noteExternalBoot semantics

@Test
func noteExternalBootPublishesDeviceBooted() async throws {
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    await coordinator.noteExternalBoot(udid: validUDID)

    var iterator = stream.makeAsyncIterator()
    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.deviceBooted)
    #expect(event.udid == validUDID.lowercased())

    await broker.unsubscribe(subscriptionId)
}

@Test
func noteExternalBootDoesNotRecordOwnership() async {
    // External boots have no associated session, so the linkage
    // model wants them to surface as unattached and `deviceterm
    // device attach` is the only path to claim them.
    let coordinator = DeviceCoordinator()
    #expect(await coordinator.ownedCount == 0)

    await coordinator.noteExternalBoot(udid: validUDID)

    #expect(await coordinator.ownedCount == 0)
    #expect(await coordinator.ownerSession(forUDID: validUDID) == nil)
}

@Test
func noteExternalBootNormalisesUDIDCase() async throws {
    // The bridge usually hands us lowercased UDIDs, but the
    // canonical key in the daemon is lowercased regardless. Two
    // calls with mixed case for the same UDID hit the debounce
    // and publish once.
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    await coordinator.noteExternalBoot(udid: validUDID.uppercased())
    await coordinator.noteExternalBoot(udid: validUDID.lowercased())

    var iterator = stream.makeAsyncIterator()
    let first = try #require(await iterator.next())
    #expect(first.udid == validUDID.lowercased())
    // Second publish suppressed: drain with a different UDID to
    // confirm no leftover event.
    await coordinator.noteExternalBoot(udid: otherUDID)
    let next = try #require(await iterator.next())
    #expect(next.udid == otherUDID.lowercased())
    await broker.unsubscribe(subscriptionId)
}

// MARK: - Debounce: shim wins, notification suppressed

@Test
func notificationDoesNotDoublePublishAfterShimRecord() async throws {
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    // Shim path arrives first (typical ordering: shim posts
    // before simctl returns to the parent shell).
    try await coordinator.recordOwnership(udid: validUDID, sessionId: UUID())
    // CoreSimulator's notification fires moments later for the
    // same UDID. Inside the debounce window → no second publish.
    await coordinator.noteExternalBoot(udid: validUDID)

    var iterator = stream.makeAsyncIterator()
    // One boot event arrives.
    let first = try #require(await iterator.next())
    #expect(first.type == DaemonEventType.deviceBooted)
    // No second event for the same boot. Probe with a different
    // UDID so we know the iterator is still drainable.
    await coordinator.noteExternalBoot(udid: otherUDID)
    let next = try #require(await iterator.next())
    #expect(next.udid == otherUDID.lowercased())

    await broker.unsubscribe(subscriptionId)
}

@Test
func shimRecordDoesNotDoublePublishAfterNotification() async throws {
    // Reverse ordering: notification arrives first (rare but
    // possible when CoreSimulator publishes before the shim's
    // UDS round-trip completes), then the shim event.
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    await coordinator.noteExternalBoot(udid: validUDID)
    try await coordinator.recordOwnership(udid: validUDID, sessionId: UUID())

    var iterator = stream.makeAsyncIterator()
    let first = try #require(await iterator.next())
    #expect(first.type == DaemonEventType.deviceBooted)
    #expect(first.udid == validUDID.lowercased())
    // No second event. Probe with a different UDID.
    await coordinator.noteExternalBoot(udid: otherUDID)
    let next = try #require(await iterator.next())
    #expect(next.udid == otherUDID.lowercased())

    await broker.unsubscribe(subscriptionId)
}

@Test
func shimRecordAfterNotificationStillRecordsOwnership() async throws {
    // Even when the publish is debounced, ownership must still
    // land, or an external-boot-then-shim-claim sequence
    // would leave the sim unattributed and `device.list` would
    // misreport it as orphaned.
    let coordinator = DeviceCoordinator()
    let sessionId = UUID()

    await coordinator.noteExternalBoot(udid: validUDID)
    try await coordinator.recordOwnership(udid: validUDID, sessionId: sessionId)

    #expect(await coordinator.ownerSession(forUDID: validUDID) == sessionId)
}

// MARK: - noteExternalShutdown semantics

@Test
func noteExternalShutdownReleasesOwnership() async throws {
    // External shutdowns (Simulator.app's File → Shut Down,
    // `simctl shutdown` from a stock terminal, sim crashes)
    // must drop the ownership record: the sim is gone
    // regardless of who shut it down.
    let coordinator = DeviceCoordinator()
    try await coordinator.recordOwnership(udid: validUDID, sessionId: UUID())
    #expect(await coordinator.ownedCount == 1)

    await coordinator.noteExternalShutdown(udid: validUDID)

    #expect(await coordinator.ownedCount == 0)
}

@Test
func noteExternalShutdownPublishesDeviceShutdown() async throws {
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    await coordinator.noteExternalShutdown(udid: validUDID)

    var iterator = stream.makeAsyncIterator()
    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.deviceShutdown)
    #expect(event.udid == validUDID.lowercased())

    await broker.unsubscribe(subscriptionId)
}

@Test
func shutdownPathsDoNotDoublePublish() async throws {
    // Same debounce contract as boot: shim's `releaseOwnership`
    // followed by the notification path (or vice versa) emits
    // exactly one `device.shutdown`.
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker)
    try await coordinator.recordOwnership(udid: validUDID, sessionId: UUID())
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    await coordinator.releaseOwnership(udid: validUDID)
    await coordinator.noteExternalShutdown(udid: validUDID)

    var iterator = stream.makeAsyncIterator()
    let first = try #require(await iterator.next())
    #expect(first.type == DaemonEventType.deviceShutdown)
    // Probe with a different UDID to drain past any duplicate.
    await coordinator.noteExternalShutdown(udid: otherUDID)
    let next = try #require(await iterator.next())
    #expect(next.udid == otherUDID.lowercased())

    await broker.unsubscribe(subscriptionId)
}

// MARK: - handleNotifierEvent dispatch
//
// `handleNotifierEvent` switches on `event.kind` and `event.newState`
// to call `noteExternalBoot` / `noteExternalShutdown`. The CSBNotifierEvent
// type's properties are bridge-private readonly, so we don't drive
// the dispatch directly from a synthesised event here; the live
// sim track exercises the full kind+state mapping in
// `SimDeviceNotifierLiveTests`. The per-state behaviour is covered
// by the direct `noteExternalBoot`/`noteExternalShutdown` tests
// above.

// MARK: - Subscription lifecycle

@Test
func unsubscribeWithoutSubscribeIsHarmless() async {
    // Daemon shutdown calls `unsubscribeFromCoreSimulator()`
    // unconditionally. A daemon that never managed to subscribe
    // (CoreSimulator unloadable on the host) must not crash when
    // teardown runs.
    let coordinator = DeviceCoordinator()
    #expect(await coordinator.isSubscribedToCoreSimulator == false)
    await coordinator.unsubscribeFromCoreSimulator()
    #expect(await coordinator.isSubscribedToCoreSimulator == false)
}
