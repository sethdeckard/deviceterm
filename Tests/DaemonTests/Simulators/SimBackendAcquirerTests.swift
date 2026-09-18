// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// The acquirer's whole job is to keep a CoreSimulator that stopped answering
// from taking the pane actor with it, so these drive a genuinely parked
// handle lookup rather than a fake that merely reports slowness: the closure
// blocks a Dispatch thread exactly the way the bridge does, and nothing in the
// acquirer is allowed to cancel it.

/// A handle lookup that blocks until the test lets it go, counting how many
/// callers are parked inside it.
///
/// `@unchecked Sendable`: `entered` is guarded by `lock`, and the semaphore is
/// itself thread-safe.
private final class ParkedBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = 0

    var enteredCount: Int { lock.withLock { entered } }

    func park() {
        lock.withLock { entered += 1 }
        gate.wait()
    }

    /// Let `count` parked callers finish. Every test releases what it parked:
    /// a still-blocked Dispatch thread would outlive the test that made it.
    func release(_ count: Int) {
        for _ in 0..<count { gate.signal() }
    }
}

private func acquired(_ backend: any DeviceBackend) -> PaneCoordinator.AcquiredBackend {
    PaneCoordinator.AcquiredBackend(backend: backend, family: "phone", deviceType: "iPhone")
}

/// Collects what the acquirer reports, in order. `@unchecked Sendable`:
/// `events` is guarded by `lock`.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SimBackendAcquirer.Event] = []

    var recorded: [SimBackendAcquirer.Event] { lock.withLock { events } }

    func record(_ event: SimBackendAcquirer.Event) {
        lock.withLock { events.append(event) }
    }
}

@Test
func eachBackendBuiltIsReportedWithAPerSimOrdinal() async throws {
    // The ordinal counts successive backend builds for the same UDID within
    // this acquirer, so a second one marks a re-attach or a lost create race
    // inside one daemon. A replacement helper starts counting again at one.
    // The acquisition number is process-wide and rides on the returned
    // backend, so the pane that publishes on it can log the same value.
    let recorder = EventRecorder()
    let acquirer = SimBackendAcquirer(
        acquireHandles: { _ in acquired(MockDeviceBackend()) },
        report: { recorder.record($0) }
    )

    let first = try await acquirer.acquire(udid: "udid-1")
    let second = try await acquirer.acquire(udid: "udid-1")
    let third = try await acquirer.acquire(udid: "udid-2")

    #expect(recorder.recorded == [
        .backendBuilt(udid: "udid-1", acquisition: 1, ordinal: 1),
        .backendBuilt(udid: "udid-1", acquisition: 2, ordinal: 2),
        .backendBuilt(udid: "udid-2", acquisition: 3, ordinal: 1)
    ])
    #expect([first.acquisition, second.acquisition, third.acquisition] == [1, 2, 3])
}

@Test
func aFailedAcquisitionReportsNothing() async throws {
    let recorder = EventRecorder()
    let acquirer = SimBackendAcquirer(
        acquireHandles: { udid in throw PaneError.deviceNotFound(udid: udid) },
        report: { recorder.record($0) }
    )

    _ = try? await acquirer.acquire(udid: "udid-1")

    #expect(recorder.recorded.isEmpty)
}

@Test
func acquireReturnsTheBackendTheBridgeBuilt() async throws {
    let backend = MockDeviceBackend()
    let acquirer = SimBackendAcquirer(acquireHandles: { _ in acquired(backend) })

    let result = try await acquirer.acquire(udid: "udid-1")

    #expect(result.backend === backend)
    #expect(result.family == "phone")
    #expect(await acquirer.inFlight == 0)
}

@Test
func acquireSurfacesTheBridgeFailureUnchanged() async throws {
    let acquirer = SimBackendAcquirer(
        acquireHandles: { udid in throw PaneError.deviceNotFound(udid: udid) }
    )

    await #expect(throws: PaneError.deviceNotFound(udid: "udid-1")) {
        try await acquirer.acquire(udid: "udid-1")
    }
    #expect(await acquirer.inFlight == 0)
}

@Test
func acquireStopsWaitingWhenTheBridgeOutlastsTheDeadline() async throws {
    let bridge = ParkedBridge()
    let acquirer = SimBackendAcquirer(
        sleep: { _ in },
        acquireHandles: { _ in
            bridge.park()
            return acquired(MockDeviceBackend())
        }
    )

    await #expect(throws: PaneError.backendAcquireTimedOut(udid: "udid-1")) {
        try await acquirer.acquire(udid: "udid-1")
    }

    bridge.release(1)
}

@Test
func anAbandonedAttemptKeepsItsSlotUntilTheBridgeAnswers() async throws {
    let bridge = ParkedBridge()
    let backend = MockDeviceBackend()
    let recorder = EventRecorder()
    let acquirer = SimBackendAcquirer(
        maxInFlight: 1,
        sleep: { _ in },
        acquireHandles: { _ in
            bridge.park()
            return acquired(backend)
        },
        report: { recorder.record($0) }
    )

    await #expect(throws: PaneError.backendAcquireTimedOut(udid: "udid-1")) {
        try await acquirer.acquire(udid: "udid-1")
    }
    // The caller gave up; the bridge call did not, so the slot is still held.
    #expect(await acquirer.inFlight == 1)

    bridge.release(1)

    #expect(try await poll(timeout: 2) { await acquirer.inFlight == 0 })
    // Nothing is left to hand it to, and no pane record will ever close it.
    #expect(try await poll(timeout: 2) { backend.shutdownCalled })
    // A backend was built and then torn down; both are on the record, so a
    // reader can tell a disposed client from one a pane is still driving. The
    // disposal is reported after the teardown ran, so wait for it.
    #expect(try await poll(timeout: 2) { recorder.recorded.count == 2 })
    #expect(recorder.recorded == [
        .backendBuilt(udid: "udid-1", acquisition: 1, ordinal: 1),
        .disposed(udid: "udid-1", acquisition: 1)
    ])
}

@Test
func aParkedDisposalDoesNotHoldTheAcquirer() async throws {
    // A late acquisition is torn down through the async shutdown. A display
    // unregister that stalls inside CoreSimulator then suspends a task rather
    // than blocking an executor thread with this actor held, so the next
    // attach still goes through while the teardown is parked.
    let bridge = ParkedBridge()
    let late = MockDeviceBackend()
    late.parkShutdown = true
    // A short real deadline rather than an instant one: the second acquire
    // has to win its race, so an unparked closure must finish inside it.
    let acquirer = SimBackendAcquirer(
        sleep: { _ in try await Task.sleep(for: .milliseconds(50)) },
        acquireHandles: { udid in
            if udid == "udid-late" {
                bridge.park()
                return acquired(late)
            }
            return acquired(MockDeviceBackend())
        }
    )

    await #expect(throws: PaneError.backendAcquireTimedOut(udid: "udid-late")) {
        try await acquirer.acquire(udid: "udid-late")
    }
    bridge.release(1)
    #expect(try await poll(timeout: 2) { await acquirer.inFlight == 0 })
    // The acquisition slot is free, the teardown is parked, and it has not
    // completed.
    #expect(try await poll(timeout: 2) { late.shutdownParked })
    #expect(!late.shutdownCalled)

    let next = try await acquirer.acquire(udid: "udid-next")
    #expect(next.family == "phone")

    late.releaseShutdown()
    #expect(try await poll(timeout: 2) { late.shutdownCalled })
}

@Test
func acquireRefusesOnceEverySlotIsHeld() async throws {
    let bridge = ParkedBridge()
    let acquirer = SimBackendAcquirer(
        maxInFlight: 2,
        sleep: { _ in },
        acquireHandles: { _ in
            bridge.park()
            return acquired(MockDeviceBackend())
        }
    )

    _ = try? await acquirer.acquire(udid: "udid-1")
    _ = try? await acquirer.acquire(udid: "udid-2")
    #expect(await acquirer.inFlight == 2)
    // Both attempts are genuinely parked in the bridge, not merely admitted:
    // the deadline can answer a caller before its Dispatch operation has even
    // started, so this waits for the park rather than sampling it.
    #expect(try await poll(timeout: 2) { bridge.enteredCount == 2 })

    // Refused outright rather than parking a third Dispatch thread in a
    // service that has already failed to answer twice.
    await #expect(throws: PaneError.backendAcquireBusy(udid: "udid-3")) {
        try await acquirer.acquire(udid: "udid-3")
    }

    bridge.release(2)
}

@Test
func aFreedSlotAdmitsTheNextAttempt() async throws {
    let bridge = ParkedBridge()
    // A real (short) deadline rather than an instant one: the last acquire
    // here is supposed to *win* its race, so the deadline has to be long
    // enough for an unparked closure to finish inside it.
    let acquirer = SimBackendAcquirer(
        maxInFlight: 1,
        sleep: { _ in try await Task.sleep(for: .milliseconds(50)) },
        acquireHandles: { udid in
            if udid == "udid-slow" { bridge.park() }
            return acquired(MockDeviceBackend())
        }
    )

    await #expect(throws: PaneError.backendAcquireTimedOut(udid: "udid-slow")) {
        try await acquirer.acquire(udid: "udid-slow")
    }
    await #expect(throws: PaneError.backendAcquireBusy(udid: "udid-fast")) {
        try await acquirer.acquire(udid: "udid-fast")
    }

    bridge.release(1)
    #expect(try await poll(timeout: 2) { await acquirer.inFlight == 0 })

    // The wedge cleared, so an ordinary attach works again with no
    // intervention: the refusal was temporary, not a latch.
    let result = try await acquirer.acquire(udid: "udid-fast")
    #expect(result.family == "phone")
}

@Test
func aParkedAcquireLeavesTheCoordinatorAnswering() async throws {
    // A blocked CoreSimulator lookup must not block unrelated pane requests,
    // the idle-exit predicate, or session teardown.
    let bridge = ParkedBridge()
    let acquirer = SimBackendAcquirer(
        deadlineNanoseconds: .max,
        acquireHandles: { _ in
            bridge.park()
            return acquired(MockDeviceBackend())
        }
    )
    let coordinator = PaneCoordinator(
        mintShortID: { ShortID.generate() },
        eventBroker: nil,
        subscriptionRegistry: nil,
        rotationConfirmationTimeoutNanoseconds: RotationConfirmationDeadline.observationNanoseconds,
        simBackendAcquirer: acquirer
    )
    let session = UUID()
    let existing = MockDeviceBackend()
    let live = try await coordinator.createMockPane(
        udid: UUID().uuidString.lowercased(),
        sessionId: session,
        backend: existing
    )

    let attach = Task { try await coordinator.createSim(sessionId: session, udid: UUID().uuidString) }
    #expect(try await poll(timeout: 2) { bridge.enteredCount == 1 })

    // The attach is parked in the bridge. The actor must still be answering.
    let panes = await coordinator.panesForSession(session)
    #expect(panes.count == 1)
    #expect(panes.first?.paneId == live.paneId)

    bridge.release(1)
    _ = try await attach.value
}

@Test
func aTargetClaimedDuringAcquireReleasesTheBackendItBuilt() async throws {
    // Acquiring suspends, so target ownership can change before it returns.
    // The create must re-run the loop and, when it has lost the target, close
    // what it built: nothing else holds a reference to those handles.
    let bridge = ParkedBridge()
    let orphaned = MockDeviceBackend()
    let acquirer = SimBackendAcquirer(
        deadlineNanoseconds: .max,
        acquireHandles: { _ in
            bridge.park()
            return acquired(orphaned)
        }
    )
    let coordinator = PaneCoordinator(
        mintShortID: { ShortID.generate() },
        eventBroker: nil,
        subscriptionRegistry: nil,
        rotationConfirmationTimeoutNanoseconds: RotationConfirmationDeadline.observationNanoseconds,
        simBackendAcquirer: acquirer
    )
    let udid = UUID().uuidString
    let attaching = UUID()
    let claimant = UUID()

    let attach = Task { try await coordinator.createSim(sessionId: attaching, udid: udid) }
    #expect(try await poll(timeout: 2) { bridge.enteredCount == 1 })

    // A different session takes the target while the first create is parked.
    _ = try await coordinator.createMockPane(
        udid: udid.lowercased(),
        sessionId: claimant,
        backend: MockDeviceBackend()
    )

    bridge.release(1)

    await #expect(throws: PaneError.paneAlreadyAttached(udid: udid.lowercased(), ownerSessionId: claimant)) {
        try await attach.value
    }
    #expect(orphaned.shutdownCalled)
    // The claimant keeps its pane; the loser cut no record of its own.
    let panes = await coordinator.panesForSession(claimant)
    #expect(panes.count == 1)
    #expect(await coordinator.panesForSession(attaching).isEmpty)
}
