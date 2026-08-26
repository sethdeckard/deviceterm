// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Dispatch
import Foundation
import Testing

// Attribution is causal, idempotent, and gated
// on CoreSimulator reaching Booted.

private let claimedUDID = "11111111-1111-1111-1111-111111111111"

private func claim(
    attemptId: String = UUID().uuidString,
    udid: String = claimedUDID,
    disposition: BootClaimDisposition = .attach,
    remainingLeaseMilliseconds: UInt64 = BootClaimEvidence.maximumLeaseMilliseconds
) -> BootClaimEvidence {
    BootClaimEvidence(
        attemptId: attemptId,
        udid: udid,
        source: .shim,
        observedState: .booting,
        disposition: disposition,
        remainingLeaseMilliseconds: remainingLeaseMilliseconds
    )
}

private final class BootClaimClock: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deviceterm.tests.boot-claim-clock")
    private var nanoseconds: UInt64 = 0

    var now: UInt64 { queue.sync { nanoseconds } }

    func advance(by delta: UInt64) {
        queue.sync { nanoseconds += delta }
    }
}

@Test
func bootingClaimStaysPendingAndUnowned() async throws {
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [] })
    let result = try await coordinator.reconcileBootClaim(claim(), sessionId: UUID())

    #expect(result.status == .pending)
    #expect(await coordinator.ownedCount == 0)
}

@Test
func bootedClaimPromotesOwnership() async throws {
    let sessionId = UUID()
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    let result = try await coordinator.reconcileBootClaim(claim(), sessionId: sessionId)

    #expect(result.status == .promoted)
    #expect(result.sessionId == sessionId.uuidString)
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == sessionId)
}

@Test
func repeatedClaimPublishesOneBootEvent() async throws {
    let broker = EventBroker()
    let coordinator = DeviceCoordinator(
        eventBroker: broker,
        readBootedUDIDs: { [claimedUDID] }
    )
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)
    let collector = Task {
        var events: [DaemonEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
    let attemptId = UUID().uuidString
    let evidence = claim(attemptId: attemptId)

    _ = try await coordinator.reconcileBootClaim(evidence, sessionId: UUID())
    _ = try await coordinator.reconcileBootClaim(evidence, sessionId: UUID())
    await broker.unsubscribe(subscriptionId)

    let events = await collector.value.filter { $0.type == DaemonEventType.deviceBooted }
    #expect(events.count == 1)
}

@Test
func newerAttemptSupersedesOlderAttemptForTheSameDevice() async throws {
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [] })
    let first = claim()
    let second = claim()
    _ = try await coordinator.reconcileBootClaim(first, sessionId: UUID())
    _ = try await coordinator.reconcileBootClaim(second, sessionId: UUID())

    let replay = try await coordinator.reconcileBootClaim(first, sessionId: UUID())
    #expect(replay.status == .superseded)
}

@Test
func failedBootCandidateLeavesTheAcceptedClaimActive() async throws {
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [] })
    let firstSession = UUID()
    let secondSession = UUID()
    let first = claim()
    let duplicate = claim()
    _ = try await coordinator.reconcileBootClaim(
        first,
        sessionId: firstSession,
        inspectCurrentState: false
    )
    _ = try await coordinator.reconcileBootClaim(
        duplicate,
        sessionId: secondSession,
        inspectCurrentState: false,
        activateImmediately: false
    )

    await coordinator.failPreparedBootClaim(attemptId: duplicate.attemptId)
    await coordinator.noteObservedBoot(udid: claimedUDID)

    let firstResult = try await coordinator.reconcileBootClaim(
        first,
        sessionId: firstSession,
        inspectCurrentState: false
    )
    let duplicateResult = try await coordinator.reconcileBootClaim(
        duplicate,
        sessionId: secondSession,
        inspectCurrentState: false
    )
    #expect(firstResult.status == .promoted)
    #expect(firstResult.sessionId == firstSession.uuidString)
    #expect(duplicateResult.status == .failed)
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == firstSession)
}

@Test
func observedShutdownCancelsPendingClaim() async throws {
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [] })
    let evidence = claim()
    _ = try await coordinator.reconcileBootClaim(evidence, sessionId: UUID())

    await coordinator.noteExternalShutdown(udid: claimedUDID)
    let replay = try await coordinator.reconcileBootClaim(evidence, sessionId: UUID())

    #expect(replay.status == .canceled)
    #expect(await coordinator.ownedCount == 0)
}

@Test
func expiredClaimDoesNotConsumeObservedBootEvent() async throws {
    let broker = EventBroker()
    let clock = BootClaimClock()
    let coordinator = DeviceCoordinator(
        eventBroker: broker,
        deviceSnapshotClock: { clock.now },
        readDevices: { [] }
    )
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)
    _ = try await coordinator.reconcileBootClaim(
        claim(remainingLeaseMilliseconds: 1),
        sessionId: UUID(),
        inspectCurrentState: false
    )
    clock.advance(by: 2_000_000)

    await coordinator.noteObservedBoot(udid: claimedUDID)

    var iterator = stream.makeAsyncIterator()
    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.deviceBooted)
    #expect(event.udid == claimedUDID)
    #expect(await coordinator.ownedCount == 0)
    await broker.unsubscribe(subscriptionId)
}

@Test
func detachDispositionPromotesWithoutSessionAttribution() async throws {
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    let result = try await coordinator.reconcileBootClaim(
        claim(disposition: .detach),
        sessionId: nil
    )

    #expect(result.status == .promoted)
    #expect(result.sessionId == nil)
    #expect(await coordinator.ownedCount == 1)
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == nil)
}

@Test
func detachDispositionDiscardsSuppliedSessionAttribution() async throws {
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    let result = try await coordinator.reconcileBootClaim(
        claim(disposition: .detach),
        sessionId: UUID()
    )

    #expect(result.status == .promoted)
    #expect(result.sessionId == nil)
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == nil)
}

@Test
func sessionCloseDemotesAClaimThatJustPromoted() async throws {
    let sessionId = UUID()
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    _ = try await coordinator.reconcileBootClaim(claim(), sessionId: sessionId)

    await coordinator.noteSessionClosing(sessionId, mode: .detach)

    #expect(await coordinator.ownedCount == 1)
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == nil)
}

@Test
func sessionCloseTombstoneConvertsAClaimThatRegistersLate() async throws {
    let sessionId = UUID()
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    await coordinator.noteSessionClosing(sessionId, mode: .detach)

    let result = try await coordinator.reconcileBootClaim(
        claim(),
        sessionId: sessionId
    )

    #expect(result.status == .promoted)
    #expect(result.sessionId == nil)
    #expect(await coordinator.ownedCount == 1)
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == nil)
}

// MARK: - Cohort close and transfer effects

// Closing one terminal of a shared tab must not strand or stop its
// simulator by taking detach/shutdown over the cohort's committed
// promotion.

private func closeEffect(
    _ sessionId: UUID,
    outcome: CohortCloseOutcome,
    incarnation: UInt64? = 1
) -> CohortDeviceEffect {
    .close(CohortCloseEffect(sessionId: sessionId, incarnation: incarnation, outcome: outcome))
}

/// A mutable booted-set the test flips between reconciles.
private final class BootedUDIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<String> = []

    var value: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}

@Test
func closeEffectPromotesAnAlreadyPromotedClaim() async throws {
    let sessionId = UUID()
    let successor = UUID()
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    _ = try await coordinator.reconcileBootClaim(claim(), sessionId: sessionId)

    await coordinator.applyCohortEffect(
        closeEffect(sessionId, outcome: .promote(successor: successor.uuidString))
    )

    #expect(await coordinator.ownedCount == 1)
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == successor)
}

@Test
func closeEffectPromotesAClaimStillPending() async throws {
    let sessionId = UUID()
    let successor = UUID()
    // Nothing Booted yet, so the first reconcile leaves the claim pending;
    // boot the sim afterwards so the claim promotes after the close.
    let booted = BootedUDIDBox()
    let coordinator = DeviceCoordinator(readBootedUDIDs: { booted.value })
    _ = try await coordinator.reconcileBootClaim(claim(), sessionId: sessionId)

    await coordinator.applyCohortEffect(
        closeEffect(sessionId, outcome: .promote(successor: successor.uuidString))
    )
    booted.value = [claimedUDID]

    let result = try await coordinator.reconcileBootClaim(claim(), sessionId: sessionId)
    #expect(result.status == .promoted)
    #expect(result.sessionId == successor.uuidString)
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == successor)
}

@Test
func closeEffectPromotesAClaimThatRegistersLate() async throws {
    let sessionId = UUID()
    let successor = UUID()
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    await coordinator.applyCohortEffect(
        closeEffect(sessionId, outcome: .promote(successor: successor.uuidString))
    )

    let result = try await coordinator.reconcileBootClaim(claim(), sessionId: sessionId)

    #expect(result.sessionId == successor.uuidString)
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == successor)
}

@Test
func closeEffectMovesOwnershipWithoutAConvergingClaim() async throws {
    // A simulator owned via device.attach, with no claim in flight, changes
    // hands too; ownership and claims move together, or the tab keeps its
    // device but loses the attribution its close prompts read.
    let sessionId = UUID()
    let successor = UUID()
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    try await coordinator.recordOwnership(udid: claimedUDID, sessionId: sessionId)

    await coordinator.applyCohortEffect(
        closeEffect(sessionId, outcome: .promote(successor: successor.uuidString))
    )

    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == successor)
}

@Test
func aLateClaimFollowsAPromotionChain() async throws {
    let alice = UUID()
    let bob = UUID()
    let carol = UUID()
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    await coordinator.applyCohortEffect(
        closeEffect(alice, outcome: .promote(successor: bob.uuidString))
    )
    await coordinator.applyCohortEffect(
        closeEffect(bob, outcome: .promote(successor: carol.uuidString))
    )

    // The claim was issued by alice, who has since handed off twice.
    let result = try await coordinator.reconcileBootClaim(claim(), sessionId: alice)

    #expect(result.sessionId == carol.uuidString)
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == carol)
}

@Test
func aChainStopsAtATerminalDisposition() async throws {
    let alice = UUID()
    let bob = UUID()
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    await coordinator.applyCohortEffect(
        closeEffect(alice, outcome: .promote(successor: bob.uuidString))
    )
    // Bob gave the device up, so alice's late claim must not resurrect it.
    await coordinator.applyCohortEffect(closeEffect(bob, outcome: .detach))

    let result = try await coordinator.reconcileBootClaim(claim(), sessionId: alice)

    #expect(result.sessionId == nil)
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == nil)
}

@Test
func aRestoredSessionBypassesItsOldTombstone() async throws {
    // Closed at incarnation 1, restored at incarnation 2 inside the lease.
    // The restored session's fresh claims are its own; only a claim from the
    // closing incarnation itself still takes the verdict.
    let sessionId = UUID()
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    await coordinator.applyCohortEffect(
        closeEffect(sessionId, outcome: .detach, incarnation: 1)
    )

    let restored = try await coordinator.reconcileBootClaim(
        claim(),
        sessionId: sessionId,
        currentIncarnation: 2
    )
    #expect(restored.status == .promoted)
    #expect(restored.sessionId == sessionId.uuidString)

    let midClose = try await coordinator.reconcileBootClaim(
        claim(),
        sessionId: sessionId,
        currentIncarnation: 1
    )
    #expect(midClose.sessionId == nil)
}

@Test
func aTransferEffectMovesOnlyTheNamedDevicesAndTheirClaims() async throws {
    let otherUDID = "22222222-2222-2222-2222-222222222222"
    let alice = CohortMember(sessionId: UUID(), incarnation: 1)
    let bob = CohortMember(sessionId: UUID(), incarnation: 2)
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID, otherUDID] })
    _ = try await coordinator.reconcileBootClaim(claim(), sessionId: alice.sessionId)
    _ = try await coordinator.reconcileBootClaim(
        claim(udid: otherUDID),
        sessionId: alice.sessionId
    )

    await coordinator.applyCohortEffect(
        .transfer(
            CohortTransferEffect(
                previousOwner: alice,
                successor: bob,
                targets: [.sim(udid: claimedUDID)]
            )
        )
    )

    // The named device and its claim moved; the unrelated one stayed
    // alice's, and no tombstone was recorded. She is still alive, so a
    // fresh claim of hers still attaches to her.
    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == bob.sessionId)
    #expect(await coordinator.ownerSession(forUDID: otherUDID) == alice.sessionId)
    let fresh = try await coordinator.reconcileBootClaim(
        claim(udid: otherUDID),
        sessionId: alice.sessionId
    )
    #expect(fresh.sessionId == alice.sessionId.uuidString)
}

@Test
func thePumpAppliesEffectsInEmissionOrder() async throws {
    // A -> B then B -> C: applied in order, ownership converges on C. A
    // high-water mark would drop the first leg when the second arrived
    // first; the pump makes the ordering structural instead.
    let alice = UUID()
    let bob = UUID()
    let carol = UUID()
    let coordinator = DeviceCoordinator(readBootedUDIDs: { [claimedUDID] })
    _ = try await coordinator.reconcileBootClaim(claim(), sessionId: alice)
    let pump = CohortEffectPump(deviceCoordinator: coordinator)

    pump.emit(closeEffect(alice, outcome: .promote(successor: bob.uuidString)))
    pump.emit(closeEffect(bob, outcome: .promote(successor: carol.uuidString), incarnation: 2))
    await pump.quiesce()

    #expect(await coordinator.ownerSession(forUDID: claimedUDID) == carol)
}
