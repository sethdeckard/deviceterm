// SPDX-License-Identifier: GPL-3.0-or-later
//
// BootClaimReconciliationTests: attribution is causal, idempotent, and gated
// on CoreSimulator reaching Booted.

@testable import Daemon
import DaemonProtocol
import Dispatch
import Foundation
import Testing

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
