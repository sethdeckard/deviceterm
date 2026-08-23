// SPDX-License-Identifier: GPL-3.0-or-later
//
// BootClaimCoordinatorTests: GUI-memory claims retry across connection
// generations and retain terminal-close policy.

@testable import App
import DaemonProtocol
import Foundation
import Testing

private let coordinatorUDID = "22222222-2222-2222-2222-222222222222"

private struct PromotedClaim: Equatable {
    let udid: String
    let sessionId: String?
    let generation: Int
}

private final class BootClaimCoordinatorClock: @unchecked Sendable {
    let now: UInt64

    init(now: UInt64) {
        self.now = now
    }
}

private func shimClaim() -> BootClaimEvidence {
    BootClaimEvidence(
        attemptId: UUID().uuidString,
        udid: coordinatorUDID,
        source: .shim,
        observedState: .booting
    )
}

@MainActor
@Test
func claimRetriesAfterSessionRestoreOnAReplacementConnection() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    var promoted: [PromotedClaim] = []
    let coordinator = BootClaimCoordinator(
        daemon: fake,
        didPromote: {
            promoted.append(PromotedClaim(udid: $0, sessionId: $1, generation: $2))
        }
    )
    coordinator.accept(sessionId: UUID().uuidString, claim: shimClaim())
    try? await Task.sleep(nanoseconds: 30_000_000)
    #expect(fake.reconcileBootClaimCalls.count == 1)

    coordinator.connectionReplaced()
    let pausedCount = fake.reconcileBootClaimCalls.count
    try? await Task.sleep(nanoseconds: 150_000_000)
    #expect(fake.reconcileBootClaimCalls.count == pausedCount)

    fake.reconcileBootClaimStatus = .promoted
    coordinator.resumeAfterSessionRestore()
    try? await Task.sleep(nanoseconds: 30_000_000)

    #expect(coordinator.pendingCount == 0)
    #expect(promoted.count == 1)
    #expect(promoted.first?.udid == coordinatorUDID)
}

@MainActor
@Test
func canceledGenerationCannotPromoteAfterReplacementRetryStarts() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .promoted
    fake.armReconcileBootClaimBarrier()
    var promoted: [PromotedClaim] = []
    let coordinator = BootClaimCoordinator(
        daemon: fake,
        didPromote: {
            promoted.append(PromotedClaim(udid: $0, sessionId: $1, generation: $2))
        }
    )

    coordinator.accept(sessionId: UUID().uuidString, claim: shimClaim())
    try? await Task.sleep(nanoseconds: 30_000_000)
    coordinator.connectionReplaced()
    coordinator.resumeAfterSessionRestore()
    try? await Task.sleep(nanoseconds: 30_000_000)
    #expect(fake.reconcileBootClaimCalls.count == 2)

    fake.releaseReconcileBootClaimBarrier()
    try? await Task.sleep(nanoseconds: 30_000_000)

    #expect(promoted.count == 1)
    #expect(coordinator.pendingCount == 0)
}

@MainActor
@Test
func rejectedGUICandidatePreservesAcceptedClaimAcrossReplacement() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    let acceptedSession = UUID().uuidString
    let accepted = shimClaim()
    var promoted: [PromotedClaim] = []
    let coordinator = BootClaimCoordinator(
        daemon: fake,
        didPromote: {
            promoted.append(PromotedClaim(udid: $0, sessionId: $1, generation: $2))
        }
    )
    coordinator.accept(sessionId: acceptedSession, claim: accepted)
    try? await Task.sleep(nanoseconds: 30_000_000)

    let rejected = coordinator.beginGUIBoot(
        udid: coordinatorUDID,
        sessionId: UUID().uuidString
    )
    coordinator.bootRequestFinished(attemptId: rejected.attemptId, outcome: .rejected)
    #expect(coordinator.pendingCount == 1)

    coordinator.connectionReplaced()
    fake.reconcileBootClaimStatus = .promoted
    coordinator.resumeAfterSessionRestore()
    try? await Task.sleep(nanoseconds: 30_000_000)

    #expect(
        fake.reconcileBootClaimCalls.last?.claim.attemptId
            == accepted.attemptId.lowercased()
    )
    #expect(promoted == [
        PromotedClaim(udid: coordinatorUDID, sessionId: acceptedSession, generation: 0)
    ])
    #expect(coordinator.pendingCount == 0)
}

@MainActor
@Test
func unresolvedNewerClaimCannotDiscardAnAcceptedClaim() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .promoted
    fake.armReconcileBootClaimBarrier()
    let acceptedSession = UUID().uuidString
    var promoted: [PromotedClaim] = []
    let coordinator = BootClaimCoordinator(
        daemon: fake,
        didPromote: {
            promoted.append(PromotedClaim(udid: $0, sessionId: $1, generation: $2))
        }
    )
    let accepted = coordinator.beginGUIBoot(
        udid: coordinatorUDID,
        sessionId: acceptedSession
    )
    let unresolved = coordinator.beginGUIBoot(
        udid: coordinatorUDID,
        sessionId: UUID().uuidString
    )

    coordinator.bootRequestFinished(attemptId: unresolved.attemptId, outcome: .uncertain)
    coordinator.bootRequestFinished(attemptId: accepted.attemptId, outcome: .accepted)
    try? await Task.sleep(nanoseconds: 30_000_000)

    #expect(fake.reconcileBootClaimCalls.map(\.claim.attemptId) == [unresolved.attemptId])
    #expect(coordinator.pendingCount == 2)

    fake.markBootClaimFailed(attemptId: unresolved.attemptId)
    fake.releaseReconcileBootClaimBarrier()
    try? await Task.sleep(nanoseconds: 30_000_000)

    #expect(fake.reconcileBootClaimCalls.map(\.claim.attemptId) == [
        unresolved.attemptId,
        accepted.attemptId
    ])
    #expect(promoted == [
        PromotedClaim(udid: coordinatorUDID, sessionId: acceptedSession, generation: 0)
    ])
    #expect(coordinator.pendingCount == 0)
}

@MainActor
@Test
func daemonPendingDoesNotEstablishAnUncertainGUICandidate() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    let accepted = shimClaim()
    let coordinator = BootClaimCoordinator(daemon: fake, didPromote: { _, _, _ in })
    coordinator.accept(sessionId: UUID().uuidString, claim: accepted)
    try? await Task.sleep(nanoseconds: 30_000_000)

    let uncertain = coordinator.beginGUIBoot(
        udid: coordinatorUDID,
        sessionId: UUID().uuidString
    )
    coordinator.bootRequestFinished(attemptId: uncertain.attemptId, outcome: .uncertain)
    try? await Task.sleep(nanoseconds: 30_000_000)

    #expect(fake.reconcileBootClaimCalls.last?.claim.attemptId == uncertain.attemptId)
    #expect(coordinator.pendingCount == 2)
}

@MainActor
@Test
func detachedTerminalConvertsPendingClaimToUnlinkedOwnership() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    let sessionId = UUID().uuidString
    let coordinator = BootClaimCoordinator(daemon: fake, didPromote: { _, _, _ in })
    coordinator.accept(sessionId: sessionId, claim: shimClaim())
    coordinator.sessionClosed(sessionId, mode: .detach)
    try? await Task.sleep(nanoseconds: 30_000_000)

    let sent = fake.reconcileBootClaimCalls.last
    #expect(sent?.sessionId == nil)
    #expect(sent?.claim.disposition == .detach)
}

@MainActor
@Test
func shutdownTerminalCarriesShutdownDisposition() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    let sessionId = UUID().uuidString
    let coordinator = BootClaimCoordinator(daemon: fake, didPromote: { _, _, _ in })
    coordinator.accept(sessionId: sessionId, claim: shimClaim())
    coordinator.sessionClosed(sessionId, mode: .shutdown)
    try? await Task.sleep(nanoseconds: 30_000_000)

    let sent = fake.reconcileBootClaimCalls.last
    #expect(sent?.sessionId == nil)
    #expect(sent?.claim.disposition == .shutdown)
}

@MainActor
@Test
func promotedShutdownClaimDoesNotEnterOwnedRoster() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    let sessionId = UUID().uuidString
    var promoted: [PromotedClaim] = []
    let coordinator = BootClaimCoordinator(
        daemon: fake,
        didPromote: {
            promoted.append(PromotedClaim(udid: $0, sessionId: $1, generation: $2))
        }
    )
    coordinator.accept(sessionId: sessionId, claim: shimClaim())
    coordinator.sessionClosed(sessionId, mode: .shutdown)
    fake.reconcileBootClaimStatus = .promoted

    try? await Task.sleep(nanoseconds: 150_000_000)

    #expect(coordinator.pendingCount == 0)
    #expect(promoted.isEmpty)
}

@MainActor
@Test
func relayDeliveryAfterSessionCloseKeepsTheClosePolicy() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    let sessionId = UUID().uuidString
    let coordinator = BootClaimCoordinator(daemon: fake, didPromote: { _, _, _ in })

    coordinator.sessionClosed(sessionId, mode: .detach)
    coordinator.accept(sessionId: sessionId, claim: shimClaim())
    try? await Task.sleep(nanoseconds: 30_000_000)

    let sent = fake.reconcileBootClaimCalls.last
    #expect(sent?.sessionId == nil)
    #expect(sent?.claim.disposition == .detach)
}

@MainActor
@Test
func promotedCloseRehomesAPendingClaimToTheSuccessor() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    let leaving = UUID().uuidString
    let successor = UUID().uuidString
    let coordinator = BootClaimCoordinator(daemon: fake, didPromote: { _, _, _ in })
    coordinator.accept(sessionId: leaving, claim: shimClaim())
    coordinator.sessionClosed(leaving, outcome: .promote(successor: successor))
    try? await Task.sleep(nanoseconds: 30_000_000)

    // The claim stays attached, re-homed on the successor, matching the
    // rewrite the daemon applies to its own copy of the claim.
    let sent = fake.reconcileBootClaimCalls.last
    #expect(sent?.sessionId == successor)
    #expect(sent?.claim.disposition == .attach)
}

@MainActor
@Test
func relayDeliveryAfterPromotedCloseFollowsTheSuccessor() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    let leaving = UUID().uuidString
    let successor = UUID().uuidString
    let coordinator = BootClaimCoordinator(daemon: fake, didPromote: { _, _, _ in })

    coordinator.sessionClosed(leaving, outcome: .promote(successor: successor))
    coordinator.accept(sessionId: leaving, claim: shimClaim())
    try? await Task.sleep(nanoseconds: 30_000_000)

    let sent = fake.reconcileBootClaimCalls.last
    #expect(sent?.sessionId == successor)
    #expect(sent?.claim.disposition == .attach)
}

@MainActor
@Test
func retriedInsertAfterPromotedCloseKeepsTheSuccessor() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    let leaving = UUID().uuidString
    let successor = UUID().uuidString
    let coordinator = BootClaimCoordinator(daemon: fake, didPromote: { _, _, _ in })
    let claim = shimClaim()

    coordinator.sessionClosed(leaving, outcome: .promote(successor: successor))
    coordinator.accept(sessionId: leaving, claim: claim)
    // A relay redelivery re-inserts the same attempt naming the closed
    // session; the successor must survive it.
    coordinator.accept(sessionId: leaving, claim: claim)
    try? await Task.sleep(nanoseconds: 30_000_000)

    let sent = fake.reconcileBootClaimCalls.last
    #expect(sent?.sessionId == successor)
    #expect(sent?.claim.disposition == .attach)
}

@MainActor
@Test
func promotionChainResolvesToTheFinalSuccessor() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    let first = UUID().uuidString
    let second = UUID().uuidString
    let third = UUID().uuidString
    let coordinator = BootClaimCoordinator(daemon: fake, didPromote: { _, _, _ in })

    // A handed to B, B later handed to C: a claim naming A must reach C.
    coordinator.sessionClosed(first, outcome: .promote(successor: second))
    coordinator.sessionClosed(second, outcome: .promote(successor: third))
    coordinator.accept(sessionId: first, claim: shimClaim())
    try? await Task.sleep(nanoseconds: 30_000_000)

    let sent = fake.reconcileBootClaimCalls.last
    #expect(sent?.sessionId == third)
    #expect(sent?.claim.disposition == .attach)
}

@MainActor
@Test
func terminalLinkStopsThePromotionChain() async {
    let fake = FakeDaemonClient()
    fake.reconcileBootClaimStatus = .pending
    let first = UUID().uuidString
    let second = UUID().uuidString
    let coordinator = BootClaimCoordinator(daemon: fake, didPromote: { _, _, _ in })

    // A handed to B, but B's whole tab then shut down: A's claim takes
    // B's terminal verdict rather than resurrecting the simulator.
    coordinator.sessionClosed(first, outcome: .promote(successor: second))
    coordinator.sessionClosed(second, outcome: .shutdown)
    coordinator.accept(sessionId: first, claim: shimClaim())
    try? await Task.sleep(nanoseconds: 30_000_000)

    let sent = fake.reconcileBootClaimCalls.last
    #expect(sent?.sessionId == nil)
    #expect(sent?.claim.disposition == .shutdown)
}

@MainActor
@Test
func relayDeadlineDoesNotRestartOnMainActorDelivery() async {
    let fake = FakeDaemonClient()
    let clock = BootClaimCoordinatorClock(now: 2_000_000)
    let coordinator = BootClaimCoordinator(
        daemon: fake,
        didPromote: { _, _, _ in },
        clock: { clock.now }
    )

    coordinator.accept(
        sessionId: UUID().uuidString,
        claim: shimClaim(),
        deadlineNanoseconds: 1_000_000
    )
    try? await Task.sleep(nanoseconds: 30_000_000)

    #expect(coordinator.pendingCount == 0)
    #expect(fake.reconcileBootClaimCalls.isEmpty)
}
