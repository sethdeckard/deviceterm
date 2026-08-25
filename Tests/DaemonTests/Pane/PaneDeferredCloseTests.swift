// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// Closing a pane whose gesture is still holding contact.
//
// The pane leaves every caller's view immediately, but its machinery stays
// alive until the gesture releases: tearing the backend out mid-gesture strands
// the contact, and handing the target to a new pane puts two producers on one
// digitizer.

/// Start a swipe long enough to still be running when the close lands.
private func startHeldSwipe(
    on coordinator: PaneCoordinator,
    paneId: UUID
) -> Task<Void, Error> {
    Task {
        _ = try await coordinator.swipe(
            paneId: paneId,
            as: .guiPeer,
            fromX: 0,
            fromY: 0,
            toX: 1,
            toY: 1,
            durationMs: 300
        )
    }
}

@Test
func aCloseDuringAGestureDefersTeardownAndReportsNoExternalActions() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "udid-defer", sessionId: UUID(), backend: backend)
    let gesture = startHeldSwipe(on: coordinator, paneId: pane.paneId)
    try await Task.sleep(nanoseconds: 20_000_000)

    let external = ExternalCleanupRecorder()
    let closed = await coordinator.close(
        paneId: pane.paneId,
        as: .guiPeer,
        mode: .shutdown,
        externalCleanup: { actions in
            external.record(actions)
            return nil
        }
    )
    let deferral = try #require(closed.deferral)
    // The ack carries neither field, so the RPC layer cannot shut the device
    // down while the gesture is still driving it.
    #expect(closed.outcome.udidToShutdown == nil)
    #expect(closed.outcome.deviceTunnelToRelease == nil)
    #expect(!backend.shutdownCalled)
    #expect(external.recorded.isEmpty)

    try await gesture.value
    await coordinator.awaitDeferredTeardown(deferral)
    #expect(backend.shutdownCalled)
    // The external shutdown ran inside the deferred sequence, after the
    // backend went down.
    #expect(external.recorded.map(\.udidToShutdown) == ["udid-defer"])
}

/// Records the external cleanup a deferred close asks the RPC layer to run.
private final class ExternalCleanupRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deviceterm.tests.external-cleanup")
    private var actions: [PaneCloseOutcome] = []

    var recorded: [PaneCloseOutcome] {
        queue.sync { actions }
    }

    func record(_ outcome: PaneCloseOutcome) {
        queue.sync { actions.append(outcome) }
    }
}

@Test
func aCloseWithNoActiveGestureTearsDownImmediately() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "udid-plain", sessionId: UUID(), backend: backend)
    let external = ExternalCleanupRecorder()
    let closed = await coordinator.close(
        paneId: pane.paneId,
        as: .guiPeer,
        mode: .shutdown,
        externalCleanup: { actions in
            external.record(actions)
            return nil
        }
    )
    // No gesture to wait for, so it all ran inline. The ack names no actions
    // because they already happened, inside the target's reservation.
    #expect(closed.deferral == nil)
    #expect(closed.outcome.udidToShutdown == nil)
    #expect(backend.shutdownCalled)
    #expect(external.recorded.map(\.udidToShutdown) == ["udid-plain"])
}

@Test
func aRetiredPaneIsInvisibleWhileItsGestureFinishes() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "udid-hidden", sessionId: session, backend: backend)
    let gesture = startHeldSwipe(on: coordinator, paneId: pane.paneId)
    try await Task.sleep(nanoseconds: 20_000_000)
    let closed = await coordinator.close(paneId: pane.paneId, as: .guiPeer, mode: .detach)
    let deferral = try #require(closed.deferral)

    // Gone to every caller: listing, and any further request against it.
    let count = await coordinator.paneCount
    #expect(count == 0)
    await #expect(throws: PaneError.notFound(paneId: pane.paneId)) {
        try await coordinator.tap(paneId: pane.paneId, as: .guiPeer, x: 0.5, y: 0.5)
    }
    // The gesture that captured it still reaches it, and still lifts.
    try await gesture.value
    await coordinator.awaitDeferredTeardown(deferral)
    #expect(backend.tapUpPoints.count == 1)
}

@Test
func aRecreateOnARetiringTargetWaitsForTheGesture() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "udid-reuse", sessionId: UUID(), backend: backend)
    let gesture = startHeldSwipe(on: coordinator, paneId: pane.paneId)
    try await Task.sleep(nanoseconds: 20_000_000)
    _ = await coordinator.close(paneId: pane.paneId, as: .guiPeer, mode: .detach)

    let replacement = MockDeviceBackend()
    let recreate = Task {
        try await coordinator.createMockPane(
            udid: "udid-reuse",
            sessionId: UUID(),
            backend: replacement
        )
    }
    try await Task.sleep(nanoseconds: 30_000_000)
    // Parked: attaching now would drive the same device the old gesture is
    // still holding.
    #expect(!replacement.startFramesCalled)
    try await gesture.value
    _ = try await recreate.value
    #expect(replacement.startFramesCalled)
}

@Test
func deferredCleanupHoldsTheDaemonOpenUntilItCompletes() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "udid-idle", sessionId: UUID(), backend: backend)
    let gesture = startHeldSwipe(on: coordinator, paneId: pane.paneId)
    try await Task.sleep(nanoseconds: 20_000_000)
    let closed = await coordinator.close(paneId: pane.paneId, as: .guiPeer, mode: .detach)
    let deferral = try #require(closed.deferral)
    // The owning session left `liveOwnerSessionIds` the moment the record left
    // `panes`, so without this the idle monitor could exit mid-gesture.
    #expect(await coordinator.hasDeferredCleanup)
    try await gesture.value
    await coordinator.awaitDeferredTeardown(deferral)
    #expect(await coordinator.hasDeferredCleanup == false)
}

@Test
func aSecondCloseOfARetiredPaneDoesNotDoubleFireItsCleanup() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "udid-twice", sessionId: UUID(), backend: backend)
    let gesture = startHeldSwipe(on: coordinator, paneId: pane.paneId)
    try await Task.sleep(nanoseconds: 20_000_000)
    let first = await coordinator.close(paneId: pane.paneId, as: .guiPeer, mode: .shutdown)
    let deferral = try #require(first.deferral)
    // The pane is already gone, so the second close finds nothing and asks for
    // no further teardown.
    let second = await coordinator.close(paneId: pane.paneId, as: .guiPeer, mode: .shutdown)
    #expect(second.deferral == nil)
    #expect(second.outcome.udidToShutdown == nil)
    try await gesture.value
    await coordinator.awaitDeferredTeardown(deferral)
    #expect(backend.shutdownCalled)
}

@Test
func aRecreateWaitsForTheDeferredShutdownNotJustTheTeardown() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "udid-order", sessionId: UUID(), backend: backend)
    let gesture = startHeldSwipe(on: coordinator, paneId: pane.paneId)
    try await Task.sleep(nanoseconds: 20_000_000)

    let attachedDuringCleanup = Sealed()
    _ = await coordinator.close(
        paneId: pane.paneId,
        as: .guiPeer,
        mode: .shutdown,
        externalCleanup: { _ in
            // Waking a re-create at backend teardown would let it attach here,
            // and this close's own shutdown would then kill the device under it.
            attachedDuringCleanup.set(await coordinator.paneCount > 0)
            try? await Task.sleep(for: .milliseconds(40))
            return nil
        }
    )
    let replacement = MockDeviceBackend()
    let recreate = Task {
        try await coordinator.createMockPane(udid: "udid-order", sessionId: UUID(), backend: replacement)
    }
    try await gesture.value
    _ = try await recreate.value
    #expect(attachedDuringCleanup.value == false)
}

/// A one-shot boolean an escaping closure can report through.
private final class Sealed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deviceterm.tests.sealed")
    private var stored: Bool?

    var value: Bool? {
        queue.sync { stored }
    }

    func set(_ newValue: Bool) {
        queue.sync { if stored == nil { stored = newValue } }
    }
}

@Test
func anOrdinaryShutdownCloseReservesItsTargetUntilTheDeviceIsGone() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "udid-plain-race", sessionId: UUID(), backend: backend)
    let replacement = MockDeviceBackend()
    let attachedDuringCleanup = Sealed()
    // No gesture in flight, so this is the ordinary path. The record leaves
    // `panes` well before the shutdown runs, and a create resolving in that
    // window would attach to a device this close is about to kill.
    let entered = Sealed()
    let closing = Task {
        await coordinator.close(
            paneId: pane.paneId,
            as: .guiPeer,
            mode: .shutdown,
            externalCleanup: { _ in
                entered.set(true)
                attachedDuringCleanup.set(await coordinator.paneCount > 0)
                try? await Task.sleep(for: .milliseconds(60))
                return nil
            }
        )
    }
    // Start the create once the close is inside its cleanup, which is the
    // window where the pane is already gone but the device is not.
    for _ in 0..<1_000 where entered.value == nil {
        await Task.yield()
    }
    let recreate = Task {
        try await coordinator.createMockPane(
            udid: "udid-plain-race",
            sessionId: UUID(),
            backend: replacement
        )
    }
    _ = await closing.value
    _ = try await recreate.value
    #expect(attachedDuringCleanup.value == false)
    #expect(replacement.startFramesCalled)
}

@Test
func aDetachWhoseContactWontReleaseDefersInsteadOfBlocking() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    backend.failReleaseHeldContact = true
    let pane = try await coordinator.createMockPane(udid: "udid-stuck", sessionId: UUID(), backend: backend)

    // The close must still answer promptly: the retry cannot sit in front of
    // the caller's ack, the backend teardown, or the tunnel release.
    let closed = await coordinator.close(paneId: pane.paneId, as: .guiPeer, mode: .detach)
    #expect(closed.deferral != nil)
    // Still reserved, because a detach leaves the device running and its
    // contact may still be down.
    #expect(await coordinator.hasDeferredCleanup)

    backend.failReleaseHeldContact = false
    await coordinator.awaitDeferredTeardown(try #require(closed.deferral))
    #expect(backend.shutdownCalled)
    #expect(await coordinator.hasDeferredCleanup == false)
}

@Test
func aDetachDuringAGestureSendsNoLiftIntoIt() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "udid-midflight", sessionId: UUID(), backend: backend)
    let gesture = startHeldSwipe(on: coordinator, paneId: pane.paneId)
    try await Task.sleep(nanoseconds: 20_000_000)
    let before = backend.tapUpPoints.count

    let closed = await coordinator.close(paneId: pane.paneId, as: .guiPeer, mode: .detach)
    // The gesture owns the contact. Probing the backend for a stray one here
    // would put a lift in the middle of the swipe.
    #expect(backend.tapUpPoints.count == before)

    try await gesture.value
    await coordinator.awaitDeferredTeardown(try #require(closed.deferral))
    // Exactly the gesture's own release: one up, not two.
    #expect(backend.tapUpPoints.count == 1)
}

@Test
func aShutdownCloseCompletesEvenWhenTheGestureFailsHolding() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "udid-stuck-shutdown", sessionId: UUID(), backend: backend)
    let gesture = startHeldSwipe(on: coordinator, paneId: pane.paneId)
    try await Task.sleep(nanoseconds: 20_000_000)

    let external = ExternalCleanupRecorder()
    let closed = await coordinator.close(
        paneId: pane.paneId,
        as: .guiPeer,
        mode: .shutdown,
        externalCleanup: { actions in
            external.record(actions)
            return nil
        }
    )
    // The gesture fails partway and its contact will not release.
    backend.failReleaseHeldContact = true
    backend.failSends = true
    _ = try? await gesture.value

    // The device shutdown is what clears that contact, so waiting on recovery
    // before reaching it would wait forever.
    await coordinator.awaitDeferredTeardown(try #require(closed.deferral))
    #expect(external.recorded.map(\.udidToShutdown) == ["udid-stuck-shutdown"])
    #expect(await coordinator.hasDeferredCleanup == false)
}
