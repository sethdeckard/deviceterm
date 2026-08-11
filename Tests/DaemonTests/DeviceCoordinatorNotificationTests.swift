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

/// Records the UDIDs a coordinator asked to converge, in order.
private actor ConvergedUDIDs {
    private(set) var all: [String] = []

    func record(_ udid: String) { all.append(udid) }
}

extension DeviceCoordinator {
    /// Install the pane-shutdown converger without registering a real
    /// CoreSimulator subscription. Production installs it as a required
    /// parameter of `subscribeToCoreSimulator`, which also stands up the
    /// notifier; these tests drive `noteExternal…` directly.
    func installConverger(_ converger: @escaping @Sendable (String) async -> Void) {
        paneShutdownConverger = converger
    }
}

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
func noteExternalShutdownConvergesAttachedPanes() async {
    // The pane half of an externally-observed shutdown. Quitting
    // Simulator.app shuts down the sims it attached to, and nothing else
    // tells deviceterm: the frames just stop and the pane sits on its
    // last one with controls that no longer do anything. The notifier is
    // the only surface that sees it, so it must converge the panes.
    let coordinator = DeviceCoordinator()
    let converged = ConvergedUDIDs()
    await coordinator.installConverger { await converged.record($0) }

    await coordinator.noteExternalShutdown(udid: validUDID)

    #expect(await converged.all == [validUDID.lowercased()])
}

@Test
func noteExternalBootDoesNotConvergePanes() async {
    // Only the shutdown transition retires panes. A boot notification
    // for a UDID a pane is already attached to (a reboot's second half,
    // say) must leave that pane live.
    let coordinator = DeviceCoordinator()
    let converged = ConvergedUDIDs()
    await coordinator.installConverger { await converged.record($0) }

    await coordinator.noteExternalBoot(udid: validUDID)

    #expect(await converged.all.isEmpty)
}

@Test
func externalShutdownConvergesWithTheNormalizedUDID() async {
    // Pins the hand-off contract: a converger is handed the canonical
    // lowercased UDID and never has to normalize for itself. The
    // production converger normalizes its own argument, so this guards
    // the contract rather than a live failure, and keeps a converger that
    // keys a dictionary directly from inheriting a case-sensitivity bug.
    let coordinator = DeviceCoordinator()
    let converged = ConvergedUDIDs()
    await coordinator.installConverger { await converged.record($0) }

    await coordinator.noteExternalShutdown(udid: validUDID.uppercased())

    #expect(await converged.all == [validUDID.lowercased()])
}

@Test
func externalShutdownPublishesBeforeConverging() async throws {
    // Ordering, not just delivery. Convergence exposes the shutdown while
    // this call is still suspended: retiring the pane tells its
    // subscribers the sim is gone and puts a Reboot affordance in front of
    // the user. A reaction to that publishes a boot, so the shutdown has
    // to publish first or `deviceterm events` describes a live device as
    // shut down. The converger here stands in for that reaction.
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)
    await coordinator.installConverger { udid in
        await broker.publish(.deviceBooted(udid: udid), to: .everyone)
    }

    await coordinator.noteExternalShutdown(udid: validUDID)

    var iterator = stream.makeAsyncIterator()
    let first = try #require(await iterator.next())
    #expect(first.type == DaemonEventType.deviceShutdown)
    let second = try #require(await iterator.next())
    #expect(second.type == DaemonEventType.deviceBooted)

    await broker.unsubscribe(subscriptionId)
}

@Test
func slowPaneConvergenceStillSuppressesADuplicateNotification() async throws {
    // The notifier's consumer loop is serial, so a duplicate shutdown
    // notification for the same UDID can't begin until the first one's
    // convergence finishes. With convergence slower than the debounce
    // window, deciding the debounce after that work would give the
    // duplicate a comparison timestamp far enough from the first to look
    // like a fresh transition, and `deviceterm events` would report the
    // sim shutting down twice. Sequential awaits here model that serial
    // consumer exactly.
    let broker = EventBroker()
    // Short window + short sleep instead of the production 500 ms and a
    // 600 ms sleep: the contract under test is "convergence outlasts the
    // window", and the ratio is what matters, not the absolute duration.
    let coordinator = DeviceCoordinator(eventBroker: broker, debounceWindow: 0.05)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)
    await coordinator.installConverger { _ in
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    // The two arrival timestamps are 10 ms apart, as a duplicate's would
    // be, while serial processing starts them at least 120 ms apart
    // because convergence holds the consumer. Supplying arrival instants
    // models what the notifier does for real (see `NotifierArrival`), and
    // is the whole point: timed by processing instead, these two would
    // land outside the window and both publish.
    let arrived = Date()
    await coordinator.noteExternalShutdown(udid: validUDID, arrivedAt: arrived)
    await coordinator.noteExternalShutdown(
        udid: validUDID,
        arrivedAt: arrived.addingTimeInterval(0.01)
    )

    var iterator = stream.makeAsyncIterator()
    let first = try #require(await iterator.next())
    #expect(first.udid == validUDID.lowercased())
    // Probe with a different UDID: a leaked duplicate drains here instead.
    await coordinator.noteExternalShutdown(udid: otherUDID)
    let next = try #require(await iterator.next())
    #expect(next.udid == otherUDID.lowercased())

    await broker.unsubscribe(subscriptionId)
}

@Test
func slowPaneConvergenceStillDebouncesTheShutdownPublish() async throws {
    // Backend teardown holds the notifier's serial consumer for its whole
    // duration, so a shutdown timed by when it got its turn rather than by
    // when it arrived ages out of the window and emits a second
    // `device.shutdown` for one the authoritative path already announced.
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(eventBroker: broker, debounceWindow: 0.05)
    try await coordinator.recordOwnership(udid: validUDID, sessionId: UUID())
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)
    await coordinator.installConverger { _ in
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    // Shrink the window below the convergence delay so post-convergence
    // processing time would escape it. Supplying an arrival at or before the
    // authoritative stamp removes scheduler latency from the comparison.
    // This test does not constrain admission placement; publication ordering
    // is covered by `externalShutdownPublishesBeforeConverging`.
    let arrived = Date()
    await coordinator.releaseOwnership(udid: validUDID)
    await coordinator.noteExternalShutdown(udid: validUDID, arrivedAt: arrived)

    var iterator = stream.makeAsyncIterator()
    let first = try #require(await iterator.next())
    #expect(first.udid == validUDID.lowercased())
    // Probe with a different UDID: if the slow path published a
    // duplicate, this drains that instead of the probe.
    await coordinator.noteExternalShutdown(udid: otherUDID)
    let next = try #require(await iterator.next())
    #expect(next.udid == otherUDID.lowercased())

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
