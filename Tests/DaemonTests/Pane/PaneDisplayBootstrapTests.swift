// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import IOSurface
import Testing

// The display bootstrap is the one suspension in `createPane` that happens
// with a half-built pane in hand. These cover what has to hold across it: the
// coordinator stays answerable, an abandoned attempt keeps its slot until the
// bridge returns and its cleanup finishes, competing creates park instead of
// racing, and nothing the backend reports during the window is lost.
//
// The tests that exercise that half-built window park the bootstrap
// explicitly, because nothing else reaches it. The rest cover the admission
// accounting and dimension caching around it, which a promptly-completing
// create does reach.

/// A coordinator whose display bootstraps are bounded on test-sized terms.
/// `sleep` is injected so a deadline fires without wall-clock waiting.
private func bootstrapCoordinator(
    deadlineNanoseconds: UInt64 = 10_000_000_000,
    maxInFlight: Int = 3,
    eventBroker: EventBroker? = nil,
    sleep: @escaping @Sendable (UInt64) async throws -> Void = {
        try await Task.sleep(nanoseconds: $0)
    }
) -> PaneCoordinator {
    PaneCoordinator(
        mintShortID: { ShortID.generate() },
        eventBroker: eventBroker,
        subscriptionRegistry: nil,
        rotationConfirmationTimeoutNanoseconds: 10_000_000,
        simBackendAcquirer: SimBackendAcquirer(),
        displayBootstrapSupervisor: DisplayBootstrapSupervisor(
            deadlineNanoseconds: deadlineNanoseconds,
            maxInFlight: maxInFlight,
            sleep: sleep
        )
    )
}

/// A published surface for a pane test. Local because the equivalents in the
/// sibling suites are private to their files.
private func bootstrapTestSurface(
    width: Int = 4,
    height: Int = 4,
    generation: UInt64? = nil
) throws -> PublishedSurface {
    let properties: [String: Any] = [
        kIOSurfaceWidth as String: width,
        kIOSurfaceHeight as String: height,
        kIOSurfaceBytesPerElement as String: 4,
        kIOSurfacePixelFormat as String: Int(0x4247_5241)
    ]
    let created = try #require(IOSurfaceCreate(properties as CFDictionary))
    // A generation makes it a leased (device-shaped) frame, which is the only
    // kind the sequence fence can reject.
    let lease = generation.map {
        LeaseMetadata(epoch: 1, generation: $0, acquireHold: { _ in nil })
    }
    return PublishedSurface(
        owned: LeasedSurface(surface: RetainedSurface(created)),
        lease: lease
    )
}

/// Fires the injected deadline a fixed number of times, then stops. Needed
/// when one test both times an attempt out and later expects a normal attach:
/// a sleep that always returns immediately would time out every attempt.
private final class DeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(fireCount: Int) { remaining = fireCount }

    func shouldFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

/// Spin until `condition` holds, so a test never depends on how many actor
/// hops a resumption takes. Bounded so a genuine failure ends the test.
private func waitUntil(
    _ condition: @Sendable () async -> Bool,
    limit: Int = 20_000
) async -> Bool {
    for _ in 0..<limit {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

@Test
func aParkedDisplayBootstrapLeavesPaneListingResponsive() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    backend.parkBootstrap = true

    let create = Task {
        try await coordinator.createMockPane(udid: "udid-parked", sessionId: session, backend: backend)
    }
    #expect(await waitUntil { backend.bootstrapParked })

    // This in-memory read has to answer while the display start is stuck
    // inside the bridge.
    let listed = await coordinator.panesForSession(session)
    #expect(listed.isEmpty)

    backend.releaseBootstrap()
    _ = try await create.value
    let after = await coordinator.panesForSession(session)
    #expect(after.count == 1)
}

@Test
func aTimedOutBootstrapKeepsItsSlotUntilTheCallReturns() async throws {
    let coordinator = bootstrapCoordinator(sleep: { _ in })
    let session = UUID()
    let backend = MockDeviceBackend()
    backend.parkBootstrap = true

    await #expect(throws: PaneError.displayStartTimedOut(udid: "udid-slow")) {
        try await coordinator.createMockPane(udid: "udid-slow", sessionId: session, backend: backend)
    }

    // The caller gave up; the attempt did not. Nothing can cancel the bridge
    // call, so the slot stays charged until it answers and its cleanup is
    // done.
    let held = await coordinator.displayStartsInFlight()
    #expect(held == 1)
    #expect(await coordinator.hasCreateInFlight)

    backend.releaseBootstrap()
    #expect(await waitUntil { await coordinator.displayStartsInFlight() == 0 })
}

@Test
func repeatedParkedBootstrapsCannotExceedTheCap() async throws {
    let coordinator = bootstrapCoordinator(maxInFlight: 1, sleep: { _ in })
    let session = UUID()
    let first = MockDeviceBackend()
    first.parkBootstrap = true

    await #expect(throws: PaneError.displayStartTimedOut(udid: "udid-1")) {
        try await coordinator.createMockPane(udid: "udid-1", sessionId: session, backend: first)
    }
    #expect(await coordinator.displayStartsInFlight() == 1)

    // The abandoned attempt still holds the only slot, so the next create is
    // refused outright rather than waiting out its own deadline.
    let second = MockDeviceBackend()
    await #expect(throws: PaneError.displayStartBusy(udid: "udid-2")) {
        try await coordinator.createMockPane(udid: "udid-2", sessionId: session, backend: second)
    }
    #expect(second.bootstrapCalls == 0)

    first.releaseBootstrap()
    #expect(await waitUntil { await coordinator.displayStartsInFlight() == 0 })
}

@Test
func aLateBootstrapIsTornDownExactlyOnceAndPublishesNothing() async throws {
    let coordinator = bootstrapCoordinator(sleep: { _ in })
    let session = UUID()
    let backend = MockDeviceBackend()
    backend.parkBootstrap = true

    await #expect(throws: PaneError.displayStartTimedOut(udid: "udid-late")) {
        try await coordinator.createMockPane(udid: "udid-late", sessionId: session, backend: backend)
    }
    // The coordinator must not tear down here: that would queue behind the
    // same wedged lane it just gave up on.
    #expect(!backend.shutdownCalled)

    backend.releaseBootstrap()
    #expect(await waitUntil { backend.shutdownCalled })
    #expect(await waitUntil { await coordinator.displayStartsInFlight() == 0 })
    #expect(backend.shutdownCalls == 1)
    // Nothing was published for a pane the caller already gave up on.
    let panes = await coordinator.panesForSession(session)
    #expect(panes.isEmpty)
}

@Test
func aCompetingCreateParksRatherThanSeeingAHalfStartedPane() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let first = MockDeviceBackend()
    first.parkBootstrap = true

    let firstCreate = Task {
        try await coordinator.createMockPane(udid: "udid-race", sessionId: session, backend: first)
    }
    #expect(await waitUntil { first.bootstrapParked })

    let second = MockDeviceBackend()
    let secondCreate = Task {
        try await coordinator.createMockPane(udid: "udid-race", sessionId: session, backend: second)
    }
    // Wait for it to actually park on the reservation. A bare yield would
    // pass just as well against a create that had not started yet, which is
    // the opposite of the contract: it must park rather than build a second
    // backend for a device the first create already claimed.
    #expect(await waitUntil { await coordinator.creatingWaiterCount == 1 })
    #expect(second.bootstrapCalls == 0)

    first.releaseBootstrap()
    let firstResult = try await firstCreate.value
    let secondResult = try await secondCreate.value

    #expect(secondResult.paneId == firstResult.paneId)
    #expect(second.bootstrapCalls == 0)
    let panes = await coordinator.panesForSession(session)
    #expect(panes.count == 1)
}

@Test
func aFrameDeliveredDuringBootstrapSurvivesIntoThePublishedPane() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    backend.parkBootstrap = true

    let create = Task {
        try await coordinator.createMockPane(udid: "udid-frame", sessionId: session, backend: backend)
    }
    #expect(await waitUntil { backend.bootstrapParked })

    // Delivered while the record is deliberately absent from `panes`. The
    // drain has not started yet, so only the stream's buffer keeps this.
    let onFrame = try #require(backend.onSurface)
    onFrame(try bootstrapTestSurface())

    backend.releaseBootstrap()
    let result = try await create.value

    // Once the drain starts it commits the buffered frame, which is what moves
    // the pane off `.booting`.
    #expect(await waitUntil {
        await coordinator.panesForSession(session)
            .first { $0.paneId == result.paneId }?.state == .rendering
    })
}

@Test
func aFatalDeliveredDuringBootstrapIsNotSwallowed() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    backend.parkBootstrap = true

    let create = Task {
        try await coordinator.createMockPane(udid: "udid-fatal", sessionId: session, backend: backend)
    }
    #expect(await waitUntil { backend.bootstrapParked })

    // The backend reports a terminal fault while the record is deliberately
    // absent from `panes`. `markPaneFailed` is keyed by paneId and would no-op
    // against an unpublished record, so this has to be buffered.
    let onFatal = try #require(backend.onFatalHandler)
    onFatal("surface pool stayed unavailable")

    backend.releaseBootstrap()
    let result = try await create.value

    #expect(await waitUntil {
        await coordinator.panesForSession(session)
            .first { $0.paneId == result.paneId }?.state == .failed
    })
}

@Test
func theInitialStateEventPrecedesAFrameBufferedDuringBootstrap() async throws {
    let broker = EventBroker()
    let coordinator = bootstrapCoordinator(eventBroker: broker)
    let session = UUID()
    let backend = MockDeviceBackend()
    backend.parkBootstrap = true
    let (_, events) = await broker.subscribe(as: .session(session, incarnation: nil))
    var iterator = events.makeAsyncIterator()

    let create = Task {
        try await coordinator.createMockPane(udid: "udid-order", sessionId: session, backend: backend)
    }
    #expect(await waitUntil { backend.bootstrapParked })

    // Buffered, so the surface pump has work waiting the moment the create
    // starts it. That pump is detached: it runs as soon as it is created and
    // parks at the coordinator's door, which is what makes this ordering
    // observable rather than a coin flip.
    let onFrame = try #require(backend.onSurface)
    onFrame(try bootstrapTestSurface())

    backend.releaseBootstrap()
    let result = try await create.value

    // Publishing the initial state has to be the create's first suspension
    // after the record goes into `panes`. Yield for anything else and the
    // pump's `rendering` lands first, leaving the stream describing a pane as
    // booting after it had already started rendering.
    let first = try #require(await iterator.next())
    #expect(first.type == DaemonEventType.paneStateChanged)
    #expect(first.paneId == PublicIdentifier.string(result.paneId))
    #expect(first.state == PaneLifecycle.booting.rawValue)

    let second = try #require(await iterator.next())
    #expect(second.type == DaemonEventType.paneStateChanged)
    #expect(second.paneId == PublicIdentifier.string(result.paneId))
    #expect(second.state == PaneLifecycle.rendering.rawValue)
}

@Test
func aBootstrapFailureFollowsTheNormalShutdownPath() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    backend.bootstrapError = NSError(domain: "BootstrapTest", code: 1, userInfo: nil)

    await #expect(throws: PaneError.self) {
        try await coordinator.createMockPane(udid: "udid-fails", sessionId: session, backend: backend)
    }
    #expect(backend.shutdownCalled)
    let panes = await coordinator.panesForSession(session)
    #expect(panes.isEmpty)
}

@Test
func aSessionClosedDuringBootstrapIsRefusedAtTheFence() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let incarnation: UInt64 = 7
    await coordinator.noteSessionActive(session, incarnation: incarnation)
    let backend = MockDeviceBackend()
    backend.parkBootstrap = true

    let create = Task {
        try await coordinator.createPane(
            target: .sim(udid: "udid-closed"),
            sessionId: session,
            ownerIncarnation: incarnation,
            requireConcreteIncarnation: true,
            acquire: {
                PaneCoordinator.AcquiredBackend(
                    backend: backend,
                    family: "phone",
                    deviceType: "iPhone"
                )
            }
        )
    }
    #expect(await waitUntil { backend.bootstrapParked })
    // A create in this state holds a backend and no pane record, so the daemon
    // must not consider itself idle.
    #expect(await coordinator.hasCreateInFlight)
    #expect(await coordinator.creatingCount == 1)

    // The session goes away while the display is still starting. The fence has
    // to refuse rather than publishing a pane for an owner that is gone, and
    // the claim is *retained* (abandoned, not removed) because the backend
    // under it is still starting.
    await coordinator.tearDownSession(session, incarnation: incarnation)
    let afterTeardown = await coordinator.creatingCount
    #expect(afterTeardown == 1)
    #expect(await coordinator.hasCreateInFlight)

    backend.releaseBootstrap()
    await #expect(throws: PaneError.self) { try await create.value }

    let panes = await coordinator.panesForSession(session)
    #expect(panes.isEmpty)
    #expect(await waitUntil { backend.shutdownCalled })
    // Released only once disposal has finished, which is what closes the
    // idle-lifetime gap.
    #expect(await waitUntil { await coordinator.creatingCount == 0 })
    #expect(await waitUntil { await coordinator.hasCreateInFlight == false })
}

@Test
func anAbandonedBootstrapHoldsItsSlotUntilTeardownFinishes() async throws {
    let coordinator = bootstrapCoordinator(sleep: { _ in })
    let session = UUID()
    let backend = MockDeviceBackend()
    backend.parkBootstrap = true
    backend.parkShutdown = true

    await #expect(throws: PaneError.displayStartTimedOut(udid: "udid-teardown")) {
        try await coordinator.createMockPane(
            udid: "udid-teardown",
            sessionId: session,
            backend: backend
        )
    }
    #expect(await coordinator.displayStartsInFlight() == 1)

    // The bridge answers, so disposal begins, but teardown itself is stuck on
    // the same lane. Freeing the slot here would report the attempt gone while
    // its display is still being torn down, letting the daemon idle-exit under
    // it and letting further attempts pile up behind it.
    backend.releaseBootstrap()
    #expect(await waitUntil { backend.shutdownParked })
    #expect(await coordinator.displayStartsInFlight() == 1)

    backend.releaseShutdown()
    #expect(await waitUntil { await coordinator.displayStartsInFlight() == 0 })
}

@Test
func aStalledTeardownDoesNotBlockTheCoordinator() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(
        udid: "udid-teardown-stall",
        sessionId: session,
        backend: backend
    )

    // Teardown is stuck on the display lane, which is what a wedged
    // CoreSimulator looks like from here.
    backend.parkShutdown = true
    let close = Task { _ = await coordinator.close(paneId: pane.paneId, as: .guiPeer, mode: .detach) }
    #expect(await waitUntil { backend.shutdownParked })

    // The coordinator has to keep answering. Running teardown inline would
    // hold the actor for as long as the bridge does.
    let listed = await coordinator.panesForSession(session)
    #expect(listed.isEmpty)

    backend.releaseShutdown()
    _ = await close.value
    #expect(backend.shutdownCalled)
}

@Test
func aSecondTerminalReportDuringTeardownCannotOverwriteTheFirst() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(
        udid: "udid-double-retire",
        sessionId: session,
        backend: backend
    )
    func currentState() async -> PaneLifecycle? {
        await coordinator.panesForSession(session).first { $0.paneId == pane.paneId }?.state
    }

    backend.parkShutdown = true
    let fail = Task { await coordinator.markPaneFailed(paneId: pane.paneId, reason: "pool") }
    #expect(await waitUntil { backend.shutdownParked })

    // Committed before the teardown wait, not after. Read while the first
    // retire is still suspended: a record left `.rendering` here is one whose
    // already-terminal guard cannot reject anything.
    let midFlight = await currentState()
    #expect(midFlight == .failed)

    // So this second report is refused rather than running a whole second
    // retire that publishes `.shutdown` under the first one.
    await coordinator.markPaneShutdown(paneId: pane.paneId)
    let afterSecond = await currentState()
    #expect(afterSecond == .failed)

    backend.releaseShutdown()
    await fail.value
    #expect(await currentState() == .failed)
}

@Test
func aTerminalPaneHoldsItsTargetUntilTheBackendIsDown() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let first = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(
        udid: "udid-teardown-hold",
        sessionId: session,
        backend: first
    )

    first.parkShutdown = true
    let fail = Task { await coordinator.markPaneFailed(paneId: pane.paneId, reason: "pool") }
    #expect(await waitUntil { first.shutdownParked })

    // Terminal, so `isLiveTarget` no longer covers it. Only the teardown
    // reservation stops a retry building a second backend for a device the
    // first one is still stopping.
    let second = MockDeviceBackend()
    let retry = Task {
        try await coordinator.createMockPane(
            udid: "udid-teardown-hold",
            sessionId: session,
            backend: second
        )
    }
    // A bounded negative: the retry must not reach its bootstrap for as long
    // as the first backend is stopping. One `Task.yield()` proves nothing here,
    // because the retry needs several hops just to get that far.
    let proceeded = await waitUntil({ second.bootstrapCalls > 0 }, limit: 500)
    #expect(!proceeded)
    // And the daemon must not consider itself idle mid-teardown.
    #expect(await coordinator.hasDeferredCleanup)

    first.releaseShutdown()
    await fail.value
    _ = try await retry.value
    #expect(second.bootstrapCalls == 1)
}

@Test
func terminalStateReachesSubscribersBeforeBackendShutdownFinishes() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(
        udid: "udid-publish-first",
        sessionId: session,
        backend: backend
    )

    backend.parkShutdown = true
    let fail = Task { await coordinator.markPaneFailed(paneId: pane.paneId, reason: "pool") }
    #expect(await waitUntil { backend.shutdownParked })

    // Publication must not wait on an unbounded teardown: a GUI subscriber that
    // never learns the pane failed keeps showing a live mirror.
    #expect(await waitUntil {
        await coordinator.panesForSession(session)
            .first { $0.paneId == pane.paneId }?.state == .failed
    })
    #expect(await waitUntil { await coordinator.terminalPublicationSettled(paneId: pane.paneId) })

    backend.releaseShutdown()
    await fail.value
}

@Test
func aSameTargetRetryAfterTimeoutIsRefusedUntilDisposalFinishes() async throws {
    let gate = DeadlineGate(fireCount: 1)
    let coordinator = bootstrapCoordinator(sleep: { _ in
        if gate.shouldFire() { return }
        try await Task.sleep(nanoseconds: 60_000_000_000)
    })
    let session = UUID()
    let first = MockDeviceBackend()
    first.parkBootstrap = true

    await #expect(throws: PaneError.displayStartTimedOut(udid: "udid-retry")) {
        try await coordinator.createMockPane(udid: "udid-retry", sessionId: session, backend: first)
    }
    // The claim is abandoned, not released: that backend is still starting.
    #expect(await coordinator.creatingCount == 1)

    // A retry must be refused rather than waiting on something unbounded or
    // starting a second backend for the same device.
    let second = MockDeviceBackend()
    await #expect(throws: PaneError.displayStartBusy(udid: "udid-retry")) {
        try await coordinator.createMockPane(udid: "udid-retry", sessionId: session, backend: second)
    }
    #expect(second.bootstrapCalls == 0)

    first.releaseBootstrap()
    #expect(await waitUntil { await coordinator.creatingCount == 0 })

    // Once disposal has released the claim, the same target attaches normally.
    let third = MockDeviceBackend()
    _ = try await coordinator.createMockPane(udid: "udid-retry", sessionId: session, backend: third)
    #expect(third.bootstrapCalls == 1)
}

@Test
func terminalPublicationDoesNotWaitOnAStalledOrientationUnregister() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(
        udid: "udid-orientation-stall",
        sessionId: session,
        backend: backend
    )

    // Orientation unregister runs during async shutdown, so a stalled
    // teardown stalls it too. Terminal state must still reach subscribers.
    backend.parkShutdown = true
    let fail = Task { await coordinator.markPaneFailed(paneId: pane.paneId, reason: "pool") }
    #expect(await waitUntil { backend.shutdownParked })
    #expect(await waitUntil {
        await coordinator.panesForSession(session)
            .first { $0.paneId == pane.paneId }?.state == .failed
    })
    #expect(await waitUntil { await coordinator.terminalPublicationSettled(paneId: pane.paneId) })

    backend.releaseShutdown()
    await fail.value
    #expect(backend.stopDisplayOrientationCalls >= 1)
}

@Test
func nilBootstrapDimensionsNeverTriggerASecondBackendRead() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    // Models the early-boot case: the renderable has not bound a surface, so
    // the bootstrap reads nothing.
    backend.pixelDimensionsResult = (nil, nil)

    let created = try await coordinator.createMockPane(
        udid: "udid-nil-dims",
        sessionId: session,
        backend: backend
    )
    #expect(created.pixelWidth == nil)
    let readsAfterCreate = backend.pixelDimensionsCalls

    // Re-attach must stay a memory read: nil is the documented answer before
    // the first frame, and the GUI sizes from the device family for it.
    let again = try await coordinator.createMockPane(
        udid: "udid-nil-dims",
        sessionId: session,
        backend: backend
    )
    #expect(again.pixelWidth == nil)
    #expect(backend.pixelDimensionsCalls == readsAfterCreate)
}

@Test
func abandoningAClaimWakesCallersAlreadyParkedOnIt() async throws {
    let gate = DeadlineGate(fireCount: 1)
    let coordinator = bootstrapCoordinator(sleep: { _ in
        if gate.shouldFire() { return }
        try await Task.sleep(nanoseconds: 60_000_000_000)
    })
    let session = UUID()
    let first = MockDeviceBackend()
    first.parkBootstrap = true

    let firstCreate = Task {
        try await coordinator.createMockPane(udid: "udid-wake", sessionId: session, backend: first)
    }
    #expect(await waitUntil { first.bootstrapParked })

    // Parked on an active claim, which is correct while a publication is
    // still coming.
    let second = MockDeviceBackend()
    let secondCreate = Task { () -> (any Error)? in
        do {
            _ = try await coordinator.createMockPane(
                udid: "udid-wake",
                sessionId: session,
                backend: second
            )
            return nil
        } catch {
            return error
        }
    }
    let parked = await waitUntil({ second.bootstrapCalls > 0 }, limit: 300)
    #expect(!parked)

    // The claim is abandoned by the timeout. A waiter left asleep here would
    // wait on a disposal that may never finish, so it has to be woken and
    // refused instead.
    await #expect(throws: PaneError.displayStartTimedOut(udid: "udid-wake")) {
        try await firstCreate.value
    }
    let refusal = await secondCreate.value
    #expect(refusal is PaneError)
    #expect(second.bootstrapCalls == 0)

    first.releaseBootstrap()
    #expect(await waitUntil { await coordinator.creatingCount == 0 })
}

@Test
func aStaleLeasedFrameCannotOverwriteCachedDimensions() async throws {
    let coordinator = bootstrapCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(
        udid: "udid-stale-dims",
        sessionId: session,
        backend: backend
    )
    let onFrame = try #require(backend.onSurface)

    onFrame(try bootstrapTestSurface(width: 40, height: 60, generation: 2))
    #expect(await waitUntil {
        await coordinator.panesForSession(session)
            .first { $0.paneId == pane.paneId }?.state == .rendering
    })

    // Rejected by the sequence fence, so it must not back-date the geometry.
    onFrame(try bootstrapTestSurface(width: 4, height: 4, generation: 1))
    for _ in 0..<200 { await Task.yield() }

    // Re-attach returns the cached geometry through `resultFor`.
    let reattached = try await coordinator.createMockPane(
        udid: "udid-stale-dims",
        sessionId: session,
        backend: backend
    )
    #expect(reattached.pixelWidth == 40)
    #expect(reattached.pixelHeight == 60)
}

@Test
func aStalledFailureTeardownStaysChargedAgainstTheCap() async throws {
    let coordinator = bootstrapCoordinator(maxInFlight: 1)
    let session = UUID()
    let failing = MockDeviceBackend()
    failing.bootstrapError = NSError(domain: "BootstrapTest", code: 1, userInfo: nil)
    // Teardown stalls, which is the case the accounting exists for: the error
    // returns promptly, but the bridge work underneath is still running.
    failing.parkShutdown = true

    await #expect(throws: PaneError.self) {
        try await coordinator.createMockPane(udid: "udid-fail-1", sessionId: session, backend: failing)
    }
    // The caller has its error, and the slot is still charged.
    #expect(await waitUntil { failing.shutdownParked })
    #expect(await coordinator.displayStartsInFlight() == 1)

    // A different target must be refused rather than adding a second stalled
    // teardown: the cap bounds total parked bridge work, not just live starts.
    let other = MockDeviceBackend()
    await #expect(throws: PaneError.displayStartBusy(udid: "udid-other")) {
        try await coordinator.createMockPane(udid: "udid-other", sessionId: session, backend: other)
    }
    #expect(other.bootstrapCalls == 0)

    failing.releaseShutdown()
    #expect(await waitUntil { await coordinator.displayStartsInFlight() == 0 })
}

@Test
func aRefusedCreateNeverAcquiresABackend() async throws {
    let coordinator = bootstrapCoordinator(maxInFlight: 1)
    let session = UUID()
    let holder = MockDeviceBackend()
    holder.parkBootstrap = true

    let held = Task {
        try await coordinator.createMockPane(udid: "udid-holder", sessionId: session, backend: holder)
    }
    #expect(await waitUntil { holder.bootstrapParked })

    // The refusal has to come *before* acquisition. If admission were checked
    // at the bootstrap call instead, this create would have built a backend
    // that then needed tearing down, and refusals would accumulate stalled
    // teardowns of their own.
    let acquires = AcquireCounter()
    await #expect(throws: PaneError.displayStartBusy(udid: "udid-refused")) {
        try await coordinator.createPane(
            target: .sim(udid: "udid-refused"),
            sessionId: session,
            acquire: {
                acquires.bump()
                return PaneCoordinator.AcquiredBackend(
                    backend: MockDeviceBackend(),
                    family: "phone",
                    deviceType: "iPhone"
                )
            }
        )
    }
    #expect(acquires.acquisitions == 0)

    holder.releaseBootstrap()
    _ = try await held.value
}

/// Counts acquisitions across the actor hop.
///
/// The property is `acquisitions`, not `count`: SwiftLint's `empty_count`
/// autocorrect rewrites `x.count == 0` into `x.isEmpty`, which this is not.
private final class AcquireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var acquisitions: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func bump() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}

@Test
func aRejectedHandoffReusesItsSlotRatherThanAddingOne() async throws {
    let coordinator = bootstrapCoordinator(maxInFlight: 1)
    let session = UUID()
    let incarnation: UInt64 = 11
    await coordinator.noteSessionActive(session, incarnation: incarnation)
    let backend = MockDeviceBackend()
    backend.parkBootstrap = true
    // Teardown stalls, so the rejected handoff's disposal is observable.
    backend.parkShutdown = true

    let create = Task {
        try await coordinator.createPane(
            target: .sim(udid: "udid-rejected"),
            sessionId: session,
            ownerIncarnation: incarnation,
            requireConcreteIncarnation: true,
            acquire: {
                PaneCoordinator.AcquiredBackend(
                    backend: backend,
                    family: "phone",
                    deviceType: "iPhone"
                )
            }
        )
    }
    #expect(await waitUntil { backend.bootstrapParked })
    // The fence will reject this handoff.
    await coordinator.tearDownSession(session, incarnation: incarnation)

    backend.releaseBootstrap()

    // The create cannot return until its disposal finishes, so observe the
    // slot while that teardown is still parked rather than awaiting first.
    #expect(await waitUntil { backend.shutdownParked })
    // Disposing the rejection must reuse the slot it was admitted on. A fresh
    // entry here would let repeated rejected handoffs pile up past the cap.
    #expect(await coordinator.displayStartsInFlight() == 1)

    backend.releaseShutdown()
    await #expect(throws: PaneError.self) { try await create.value }
    #expect(await waitUntil { await coordinator.displayStartsInFlight() == 0 })
}

/// Lets a test hold a create inside its `acquire` suspension.
private final class AcquireGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false

    /// Whether a create is parked here right now, so a test can wait for that
    /// state instead of guessing at it with yields.
    var isParked: Bool { lock.withLock { waiter != nil } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if opened { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            opened = true
            let parked = waiter
            waiter = nil
            return parked
        }
        continuation?.resume()
    }
}

@Test
func anAcquiredButUnusedBackendIsDisposedUnderItsOwnAdmission() async throws {
    let coordinator = bootstrapCoordinator(maxInFlight: 3)
    let session = UUID()
    let gate = AcquireGate()

    // This create's acquire suspends, which is the only window in which a
    // competing create can take the target out from under it.
    let unused = MockDeviceBackend()
    unused.parkShutdown = true
    let sideReleases = SideResourceCounter()
    let loser = Task {
        try await coordinator.createPane(
            target: .sim(udid: "udid-unused"),
            sessionId: session,
            acquire: {
                await gate.wait()
                return PaneCoordinator.AcquiredBackend(
                    backend: unused,
                    family: "phone",
                    deviceType: "iPhone",
                    releaseSideResources: { sideReleases.bump() }
                )
            }
        )
    }
    // Hold it inside `acquire` before the winner claims the target, so the
    // loser is provably the one that arrives to find it taken.
    #expect(await waitUntil { gate.isParked })

    let winner = MockDeviceBackend()
    _ = try await coordinator.createMockPane(
        udid: "udid-unused",
        sessionId: session,
        backend: winner
    )

    // Now the loser resumes, finds the target taken, and leaves the coordinator
    // to dispose what it built.
    gate.open()
    _ = try await loser.value

    // That teardown must be charged. Releasing the slot before cleanup finishes
    // is what lets unused backends accumulate stalled teardowns invisibly.
    #expect(await waitUntil { unused.shutdownParked })
    #expect(await coordinator.displayStartsInFlight() == 1)

    // The side-resource release happens only after the backend is down, and
    // exactly once.
    #expect(sideReleases.releases == 0)
    unused.releaseShutdown()
    #expect(await waitUntil { await coordinator.displayStartsInFlight() == 0 })
    #expect(await waitUntil { sideReleases.releases == 1 })
    #expect(unused.shutdownCalls == 1)
}

/// Counts side-resource releases across the actor hop.
private final class SideResourceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var releases: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func bump() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}
