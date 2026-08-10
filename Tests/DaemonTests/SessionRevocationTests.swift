// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// Session revocation: closing a session tears down its live subscriptions
// before the close returns, and nothing it owned keeps streaming afterward.
// These pin the three producers the contract covers: the daemon.events lane
// (EventBroker.finishSession + retirement), the pane JSON + surface lanes
// (PaneCoordinator.revokeSubscriptions), and the SessionManager wiring that
// drives both on the close and ghost-reconciliation paths. A `.guiPeer`
// subscription is spared throughout (the GUI spans sessions).

private extension PaneCoordinator {
    func makeSimPane(udid: String, session: UUID) async throws -> PaneCreateResult {
        try await createPane(
            target: .sim(udid: udid),
            sessionId: session,
            acquire: { AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone") }
        )
    }
}

/// Records the session ids a `paneRevoker` was invoked for. `@unchecked
/// Sendable`: ids under `lock`.
private final class RevokerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []
    var recorded: [UUID] { lock.lock(); defer { lock.unlock() }; return ids }
    func record(_ id: UUID) { lock.lock(); ids.append(id); lock.unlock() }
}

/// Counts side-band surface sends. `@unchecked Sendable`: `n` under `lock`.
private final class Sends: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

// MARK: - EventBroker: finishSession + retirement

@Test("finishSession makes .sessionClosed the last yield on the closing session's stream")
func daemonEventsLinearizesAfterClose() async {
    let broker = EventBroker()
    let sessionA = UUID()
    let (_, stream) = await broker.subscribe(as: .session(sessionA))
    var iterator = stream.makeAsyncIterator()

    // A pre-close event is delivered normally.
    let live = DaemonEvent.sessionCreated(sessionId: sessionA.uuidString, shortId: "A", name: nil)
    await broker.publish(live, to: .session(sessionA))
    #expect(await iterator.next() == live)

    // finishSession yields the final close, then removes + finishes the
    // subscriber in the same turn.
    let closed = DaemonEvent.sessionClosed(sessionId: sessionA.uuidString)
    await broker.finishSession(sessionA, withFinalEvent: closed)
    #expect(await iterator.next() == closed)

    // A publication linearized AFTER the finalize reaches no removed
    // subscriber; the stream is finished (next == nil), not merely empty.
    await broker.publish(
        DaemonEvent.sessionCreated(sessionId: sessionA.uuidString, shortId: "A2", name: nil),
        to: .session(sessionA)
    )
    #expect(await iterator.next() == nil)
}

@Test("finishSession spares the GUI peer and every other session")
func finishSessionSparesGuiPeerAndOtherSessions() async {
    let broker = EventBroker()
    let sessionA = UUID()
    let sessionB = UUID()
    let (_, streamA) = await broker.subscribe(as: .session(sessionA))
    let (_, streamB) = await broker.subscribe(as: .session(sessionB))
    let (_, streamGUI) = await broker.subscribe(as: .guiPeer)

    let closed = DaemonEvent.sessionClosed(sessionId: sessionA.uuidString)
    await broker.finishSession(sessionA, withFinalEvent: closed)

    // A is retired and removed; B and the GUI peer remain.
    #expect(await broker.isRetired(sessionA))
    #expect(await broker.subscriberCount == 2)

    // The GUI peer received A's close (it spans sessions).
    var itGUI = streamGUI.makeAsyncIterator()
    #expect(await itGUI.next() == closed)

    // B's stream still delivers.
    let bEvent = DaemonEvent.sessionCreated(sessionId: sessionB.uuidString, shortId: "B", name: nil)
    await broker.publish(bEvent, to: .session(sessionB))
    var itB = streamB.makeAsyncIterator()
    #expect(await itB.next() == bEvent)

    // A's stream is finished.
    var itA = streamA.makeAsyncIterator()
    #expect(await itA.next() == closed)
    #expect(await itA.next() == nil)
}

@Test("a retired session refuses an incarnation-pinned subscribe until reactivated")
func retiredSessionRefusesSubscribeUntilReactivated() async {
    let broker = EventBroker()
    let sessionA = UUID()
    // Live at incarnation 1, then finished (retired).
    await broker.reactivateSession(sessionA, incarnation: 1)
    await broker.finishSession(sessionA, withFinalEvent: .sessionClosed(sessionId: sessionA.uuidString))

    // A `.session(A, 1)` subscribe onto the retired id (the parked-past-close
    // window) gets a terminal stream and adds no live subscriber.
    let (_, refused) = await broker.subscribe(as: .session(sessionA, incarnation: 1))
    var itRefused = refused.makeAsyncIterator()
    #expect(await itRefused.next() == nil)
    #expect(await broker.subscriberCount == 0)

    // Reactivation (the restored incarnation reaching ready) reopens it.
    await broker.reactivateSession(sessionA, incarnation: 2)
    let (_, live) = await broker.subscribe(as: .session(sessionA, incarnation: 2))
    #expect(await broker.subscriberCount == 1)
    let event = DaemonEvent.sessionCreated(sessionId: sessionA.uuidString, shortId: "A", name: nil)
    await broker.publish(event, to: .session(sessionA))
    var itLive = live.makeAsyncIterator()
    #expect(await itLive.next() == event)
}

// MARK: - PaneCoordinator: revokeSubscriptions(forSession:)

@Test("closing a session revokes its pane JSON subscription and fences re-subscribe")
func revokeSubscriptionsTearsDownSessionSubscriberAndFencesResubscribe() async throws {
    let coordinator = PaneCoordinator()
    let sessionA = UUID()
    let pane = try await coordinator.makeSimPane(udid: "rev-json", session: sessionA)
    let (_, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .session(sessionA))

    await coordinator.revokeSubscriptions(forSession: sessionA)

    // The subscription ended and left no live subscriber.
    var iterator = stream.makeAsyncIterator()
    var sawState = false
    while let event = await iterator.next() { _ = event; sawState = true }
    _ = sawState
    #expect(await coordinator.subscriberCount(paneId: pane.paneId) == 0)

    // The orphan is now owner-revoked: a parked/late `.session(A)` subscribe
    // or input is refused (indistinguishable notFound), minting nothing.
    await #expect(throws: PaneError.notFound(paneId: pane.paneId)) {
        _ = try await coordinator.subscribe(paneId: pane.paneId, as: .session(sessionA))
    }
    await #expect(throws: PaneError.notFound(paneId: pane.paneId)) {
        try await coordinator.tap(paneId: pane.paneId, as: .session(sessionA), x: 0.5, y: 0.5)
    }
}

@Test("closing a session spares a GUI-peer subscription on its pane")
func revokeSubscriptionsSparesGuiPeer() async throws {
    let coordinator = PaneCoordinator()
    let sessionA = UUID()
    let pane = try await coordinator.makeSimPane(udid: "rev-gui", session: sessionA)
    let (_, guiStream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    let (_, sessionStream) = try await coordinator.subscribe(paneId: pane.paneId, as: .session(sessionA))

    await coordinator.revokeSubscriptions(forSession: sessionA)

    // The GUI-peer subscription survives; only the session subscriber is gone.
    #expect(await coordinator.subscriberCount(paneId: pane.paneId) == 1)
    // The GUI peer still renders and drives the orphan pending re-adoption.
    try await coordinator.tap(paneId: pane.paneId, as: .guiPeer, x: 0.5, y: 0.5)

    var itSession = sessionStream.makeAsyncIterator()
    while await itSession.next() != nil {}  // session stream finished
    withExtendedLifetime(guiStream) {}
}

@Test("closing a session severs its pane surface lane — no further send")
func revokeSubscriptionsSurfaceLaneNoFurtherSend() async throws {
    let registry = PaneSubscriptionRegistry()
    let coordinator = PaneCoordinator(subscriptionRegistry: registry)
    let sessionA = UUID()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createPane(
        target: .sim(udid: "rev-surface"),
        sessionId: sessionA,
        acquire: { PaneCoordinator.AcquiredBackend(backend: backend, family: "phone", deviceType: "iPhone") }
    )
    let sends = Sends()
    let context = SubscriptionContext(
        subscriptionToken: UUID(),
        connectionId: 9,
        lifecycle: SubscriptionLifecycle(),
        surfaceDelivery: { _ in sends.bump() }
    )
    let (_, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .session(sessionA), context: context)

    await coordinator.revokeSubscriptions(forSession: sessionA)

    // No registry entry remains, and a driven surface reaches the recorder
    // zero times.
    #expect(await registry.hasEntry(paneId: pane.paneId, connectionId: 9) == false)
    let raw = try #require(SurfaceCopy.makeSurface(width: 4, height: 4))
    let published = PublishedSurface(owned: LeasedSurface(surface: RetainedSurface(raw)), lease: nil)
    await registry.deliverSurface(paneId: pane.paneId, published: published, sequence: 1)
    #expect(sends.value == 0)
    withExtendedLifetime(stream) {}
}

@Test("closing one session leaves another session's pane subscription untouched")
func revokeSubscriptionsLeavesOtherSessionsPaneUntouched() async throws {
    let coordinator = PaneCoordinator()
    let sessionA = UUID()
    let sessionB = UUID()
    let paneA = try await coordinator.makeSimPane(udid: "rev-a", session: sessionA)
    let paneB = try await coordinator.makeSimPane(udid: "rev-b", session: sessionB)
    let (_, streamA) = try await coordinator.subscribe(paneId: paneA.paneId, as: .session(sessionA))
    let (_, streamB) = try await coordinator.subscribe(paneId: paneB.paneId, as: .session(sessionB))

    await coordinator.revokeSubscriptions(forSession: sessionA)

    // A's subscription is gone; B's is intact and B can still drive its pane.
    #expect(await coordinator.subscriberCount(paneId: paneA.paneId) == 0)
    #expect(await coordinator.subscriberCount(paneId: paneB.paneId) == 1)
    try await coordinator.tap(paneId: paneB.paneId, as: .session(sessionB), x: 0.5, y: 0.5)

    var itA = streamA.makeAsyncIterator()
    while await itA.next() != nil {}
    withExtendedLifetime(streamB) {}
}

// MARK: - Commit-time owner-readiness gate

@Test("a production pane create requires a concrete owner incarnation")
func createRequiresConcreteOwnerIncarnation() async throws {
    let coordinator = PaneCoordinator()
    let sessionA = UUID()
    // A production create (`requireConcreteIncarnation`) whose handler resolves
    // a nil incarnation because the target session is not ready is refused
    // before the backend is even acquired.
    await #expect(throws: PaneError.ownerNotReady(sessionId: sessionA)) {
        _ = try await coordinator.createPane(
            target: .sim(udid: "not-ready"),
            sessionId: sessionA,
            ownerIncarnation: nil,
            requireConcreteIncarnation: true,
            acquire: {
                PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
            }
        )
    }
    #expect(await coordinator.paneCount == 0)
    // A concrete incarnation MATCHING the session's active incarnation is
    // admitted (a production create requires the session to be active).
    await coordinator.noteSessionActive(sessionA, incarnation: 1)
    let pane = try await coordinator.createPane(
        target: .sim(udid: "not-ready"),
        sessionId: sessionA,
        ownerIncarnation: 1,
        requireConcreteIncarnation: true,
        acquire: {
            PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
        }
    )
    try await coordinator.tap(paneId: pane.paneId, as: .session(sessionA, incarnation: 1), x: 0.5, y: 0.5)
}

@Test("a re-attach re-stamps the accepted incarnation, fencing a stale request")
func reattachRestampsIncarnation() async throws {
    let coordinator = PaneCoordinator()
    let sessionA = UUID()
    let pane = try await coordinator.createPane(
        target: .sim(udid: "reattach"),
        sessionId: sessionA,
        ownerIncarnation: 1,
        acquire: {
            PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
        }
    )
    // The same UUID re-attaching at a NEW incarnation (a restored session)
    // re-stamps the pane; a request pinned to the OLD incarnation is now fenced.
    _ = try await coordinator.createPane(
        target: .sim(udid: "reattach"),
        sessionId: sessionA,
        ownerIncarnation: 2,
        acquire: {
            PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
        }
    )
    await #expect(throws: PaneError.notFound(paneId: pane.paneId)) {
        try await coordinator.tap(paneId: pane.paneId, as: .session(sessionA, incarnation: 1), x: 0.5, y: 0.5)
    }
    // The current incarnation reaches it.
    try await coordinator.tap(paneId: pane.paneId, as: .session(sessionA, incarnation: 2), x: 0.5, y: 0.5)
}

@Test("the producer-local active-incarnation check refuses a stale create and re-attach")
func activeIncarnationRefusesStaleOwnership() async throws {
    let coordinator = PaneCoordinator()
    let sessionA = UUID()
    // The session is active at incarnation 1; create a pane under it.
    await coordinator.noteSessionActive(sessionA, incarnation: 1)
    let pane = try await coordinator.createPane(
        target: .sim(udid: "active"),
        sessionId: sessionA,
        ownerIncarnation: 1,
        requireConcreteIncarnation: true,
        acquire: {
            PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
        }
    )

    // The session is reincarnated (closed + restored) at incarnation 2.
    await coordinator.noteSessionActive(sessionA, incarnation: 2)

    // A create authorized under the OLD incarnation 1 (a parked request) is
    // refused by the synchronous active-incarnation check.
    await #expect(throws: PaneError.ownerNotReady(sessionId: sessionA)) {
        _ = try await coordinator.createPane(
            target: .sim(udid: "active-2"),
            sessionId: sessionA,
            ownerIncarnation: 1,
            requireConcreteIncarnation: true,
            acquire: {
                PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
            }
        )
    }
    // A stale RE-ATTACH under incarnation 1 is refused too; it neither clears
    // the owner-revoked fence nor re-stamps the incarnation.
    await #expect(throws: PaneError.ownerNotReady(sessionId: sessionA)) {
        _ = try await coordinator.createPane(
            target: .sim(udid: "active"),
            sessionId: sessionA,
            ownerIncarnation: 1,
            requireConcreteIncarnation: true,
            acquire: {
                PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
            }
        )
    }
    // A re-attach at the CURRENT incarnation 2 succeeds and re-stamps the pane.
    _ = try await coordinator.createPane(
        target: .sim(udid: "active"),
        sessionId: sessionA,
        ownerIncarnation: 2,
        requireConcreteIncarnation: true,
        acquire: {
            PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
        }
    )
    try await coordinator.tap(paneId: pane.paneId, as: .session(sessionA, incarnation: 2), x: 0.5, y: 0.5)
}

@Test("production ownership after the active incarnation is REMOVED is refused")
func ownershipAfterActiveRemovalRefused() async throws {
    let coordinator = PaneCoordinator()
    let sessionA = UUID()
    await coordinator.noteSessionActive(sessionA, incarnation: 1)
    let pane = try await coordinator.createPane(
        target: .sim(udid: "rm"),
        sessionId: sessionA,
        ownerIncarnation: 1,
        requireConcreteIncarnation: true,
        acquire: {
            PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
        }
    )
    // A parked subscription (would resume after the close).
    let (_, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .session(sessionA, incarnation: 1))

    // The session's close sweep clears the active incarnation (and revokes subs).
    await coordinator.revokeSubscriptions(forSession: sessionA)

    // A production FRESH CREATE under the now-removed incarnation is refused:
    // absence rejects (the fail-open hole is closed).
    await #expect(throws: PaneError.ownerNotReady(sessionId: sessionA)) {
        _ = try await coordinator.createPane(
            target: .sim(udid: "rm-2"),
            sessionId: sessionA,
            ownerIncarnation: 1,
            requireConcreteIncarnation: true,
            acquire: {
                PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
            }
        )
    }
    // A RE-ATTACH under the removed incarnation is refused too; it can't clear
    // the owner-revoked fence.
    await #expect(throws: PaneError.ownerNotReady(sessionId: sessionA)) {
        _ = try await coordinator.createPane(
            target: .sim(udid: "rm"),
            sessionId: sessionA,
            ownerIncarnation: 1,
            requireConcreteIncarnation: true,
            acquire: {
                PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
            }
        )
    }
    // The parked subscription was revoked by the sweep.
    var iterator = stream.makeAsyncIterator()
    while await iterator.next() != nil {}
    withExtendedLifetime(stream) {}
}

@Test("adoption to a session whose active incarnation is absent is refused")
func adoptionWithoutActiveIncarnationRefused() async throws {
    let coordinator = PaneCoordinator()
    let deadOwner = UUID()
    let adopter = UUID()
    // Seed a pane owned by `deadOwner` (active at incarnation 1).
    await coordinator.noteSessionActive(deadOwner, incarnation: 1)
    let pane = try await coordinator.createPane(
        target: .sim(udid: "adopt"),
        sessionId: deadOwner,
        ownerIncarnation: 1,
        requireConcreteIncarnation: true,
        acquire: {
            PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
        }
    )
    // The adopter has NO active incarnation tracked (never activated / removed).
    // A production adoption (prior owner dead → transfer) is refused because the
    // adopter's active incarnation is absent.
    await #expect(throws: PaneError.ownerNotReady(sessionId: adopter)) {
        _ = try await coordinator.createPane(
            target: .sim(udid: "adopt"),
            sessionId: adopter,
            ownerIncarnation: 2,
            requireConcreteIncarnation: true,
            isOwnerSessionAlive: { _ in false },
            acquire: {
                PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
            }
        )
    }
    // The pane still belongs to the original owner (adoption refused).
    try await coordinator.tap(paneId: pane.paneId, as: .session(deadOwner, incarnation: 1), x: 0.5, y: 0.5)
}

@Test("installing the pane activator replays already-ready sessions")
func paneActivatorReplaysExistingReadySessions() async throws {
    let coordinator = PaneCoordinator()
    let manager = SessionManager()
    // Mint a session BEFORE wiring the activator (a harness `existingSession`
    // path mints sessions before starting the server).
    let created = try await manager.createSession(label: nil)
    let sessionId = created.state.id
    guard case let .ready(incOpt) = await manager.admission(for: sessionId), let incarnation = incOpt else {
        Issue.record("expected the pre-existing session ready"); return
    }

    // Wire the activator. It must REPLAY the already-ready session into the
    // coordinator's active-incarnation map.
    await manager.setPaneActivator { sid, inc in
        await coordinator.noteSessionActive(sid, incarnation: inc)
    }

    // A production create for the pre-existing session now succeeds (its active
    // incarnation was replayed) rather than wrongly getting `ownerNotReady`.
    let pane = try await coordinator.createPane(
        target: .sim(udid: "replay"),
        sessionId: sessionId,
        ownerIncarnation: incarnation,
        requireConcreteIncarnation: true,
        acquire: {
            PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
        }
    )
    try await coordinator.tap(paneId: pane.paneId, as: .session(sessionId, incarnation: incarnation), x: 0.5, y: 0.5)
}

// MARK: - SessionManager: wiring on the close + ghost paths

@Test("the pane revoker seam flips once installed")
func paneRevokerWiringFlips() async {
    let manager = SessionManager()
    #expect(await manager.hasPaneRevoker == false)
    await manager.setPaneRevoker { _ in }
    #expect(await manager.hasPaneRevoker)
}

@Test("closeSession revokes the session's pane subscriptions and retires its events")
func closeSessionRevokesAndRetires() async throws {
    let broker = EventBroker()
    let manager = SessionManager(eventBroker: broker)
    let recorder = RevokerRecorder()
    await manager.setPaneRevoker { recorder.record($0) }

    let created = try await manager.createSession(label: nil)
    let sessionId = created.state.id
    let (_, events) = await broker.subscribe(as: .session(sessionId))

    try await manager.closeSession(sessionId: sessionId, capability: created.capability)

    // The pane revoker ran for the closed session, and its event stream is
    // retired + finished with a final .sessionClosed.
    #expect(recorder.recorded == [sessionId])
    #expect(await broker.isRetired(sessionId))
    // The event stream is finished (retired + removed): it delivers its
    // buffered events, ending on the final .sessionClosed, then terminates.
    var iterator = events.makeAsyncIterator()
    var last: DaemonEvent?
    while let event = await iterator.next() { last = event }
    #expect(last?.type == DaemonEventType.sessionClosed)
    #expect(await iterator.next() == nil)
}

// MARK: - Incarnation lifecycle + reincarnation ABA

@Test("admission is ready after create, absent after close, and increments per session")
func admissionPhaseAndIncarnation() async throws {
    let manager = SessionManager()
    let sessionA = try await manager.createSession(label: nil)
    // Ready with a concrete incarnation after create.
    guard case let .ready(incA) = await manager.admission(for: sessionA.state.id), let firstIncarnation = incA else {
        Issue.record("expected .ready with an incarnation for a fresh session")
        return
    }
    // A second session gets a strictly-greater incarnation.
    let sessionB = try await manager.createSession(label: nil)
    guard case let .ready(incB) = await manager.admission(for: sessionB.state.id), let secondIncarnation = incB else {
        Issue.record("expected .ready with an incarnation for the second session")
        return
    }
    #expect(secondIncarnation > firstIncarnation)
    // Closing settles the phase to absent (terminal).
    try await manager.closeSession(sessionId: sessionA.state.id, capability: sessionA.capability)
    #expect(await manager.admission(for: sessionA.state.id) == .absent)
    #expect(await manager.admission(for: UUID()) == .absent)
}

@Test("EventBroker refuses a stale incarnation after reincarnation (daemon.events ABA)")
func daemonEventsReincarnationABA() async {
    let broker = EventBroker()
    let sessionA = UUID()
    // Incarnation 1 is ready: a G=1 subscribe is admitted, a G=2 one refused.
    await broker.reactivateSession(sessionA, incarnation: 1)
    let (_, live1) = await broker.subscribe(as: .session(sessionA, incarnation: 1))
    #expect(await broker.subscriberCount == 1)
    let (_, mismatched) = await broker.subscribe(as: .session(sessionA, incarnation: 2))
    var itMismatched = mismatched.makeAsyncIterator()
    #expect(await itMismatched.next() == nil)  // refused → terminal
    #expect(await broker.subscriberCount == 1)

    // Close, then restore the same UUID at incarnation 2.
    await broker.finishSession(sessionA, withFinalEvent: .sessionClosed(sessionId: sessionA.uuidString))
    #expect(await broker.subscriberCount == 0)  // live1 removed by the close
    await broker.reactivateSession(sessionA, incarnation: 2)

    // A parked G=1 request is now refused (G != G+1); a fresh G=2 is admitted.
    let (_, stale) = await broker.subscribe(as: .session(sessionA, incarnation: 1))
    var itStale = stale.makeAsyncIterator()
    #expect(await itStale.next() == nil)
    let (_, fresh) = await broker.subscribe(as: .session(sessionA, incarnation: 2))
    #expect(await broker.subscriberCount == 1)
    withExtendedLifetime((live1, fresh)) {}
}

@Test("a pane refuses a stale incarnation of its owner (pane ABA)")
func paneReincarnationABA() async throws {
    let coordinator = PaneCoordinator()
    let sessionA = UUID()
    let pane = try await coordinator.createPane(
        target: .sim(udid: "aba"),
        sessionId: sessionA,
        ownerIncarnation: 1,
        acquire: {
            PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
        }
    )
    // The owner at its accepted incarnation reaches the pane...
    try await coordinator.tap(paneId: pane.paneId, as: .session(sessionA, incarnation: 1), x: 0.5, y: 0.5)
    // ...a request carrying a DIFFERENT incarnation of the same UUID does not.
    await #expect(throws: PaneError.notFound(paneId: pane.paneId)) {
        try await coordinator.tap(paneId: pane.paneId, as: .session(sessionA, incarnation: 2), x: 0.5, y: 0.5)
    }
    // An un-pinned request (nil incarnation, e.g. an internal path) still reaches it.
    try await coordinator.tap(paneId: pane.paneId, as: .session(sessionA), x: 0.5, y: 0.5)
}

@Test("a restored same-UUID session becomes admissible only at its new incarnation")
func restoreReincarnationThroughAdmission() async throws {
    let broker = EventBroker()
    let manager = SessionManager(eventBroker: broker, startsPendingRestoration: true)
    await manager.setPaneRevoker { _ in }

    // Create A (epoch 0, live authority), capture its identity for a restore.
    let created = try await manager.createSession(label: nil)
    let sessionA = created.state.id
    guard case let .ready(firstInc) = await manager.admission(for: sessionA) else {
        Issue.record("expected A ready after create"); return
    }
    // A dominating restore that OMITS A ghosts it (absent + retired).
    _ = try await manager.restoreBatch([], owner: nil, epoch: 1, revision: 0)
    #expect(await manager.admission(for: sessionA) == .absent)
    #expect(await broker.isRetired(sessionA))

    // A newer restore LISTING A reinserts the same UUID at a new incarnation.
    let entry = RestoreSessionEntry(
        id: sessionA,
        capability: created.capability,
        shortId: created.state.shortId,
        role: created.state.role,
        name: nil,
        isPrivate: false
    )
    _ = try await manager.restoreBatch([entry], owner: nil, epoch: 2, revision: 0)
    guard case let .ready(secondInc) = await manager.admission(for: sessionA),
        let newInc = secondInc, let oldInc = firstInc else {
        Issue.record("expected A ready at a new incarnation after restore"); return
    }
    #expect(newInc > oldInc)
    #expect(await broker.isRetired(sessionA) == false)
    // The broker now accepts the new incarnation and refuses the stale one.
    let (_, stale) = await broker.subscribe(as: .session(sessionA, incarnation: oldInc))
    var itStale = stale.makeAsyncIterator()
    #expect(await itStale.next() == nil)
    let (_, fresh) = await broker.subscribe(as: .session(sessionA, incarnation: newInc))
    #expect(await broker.subscriberCount == 1)
    withExtendedLifetime(fresh) {}
}

@Test("a close publishes exactly one .sessionClosed and one revocation")
func closeIsExactlyOnce() async throws {
    let broker = EventBroker()
    let manager = SessionManager(eventBroker: broker)
    let recorder = RevokerRecorder()
    await manager.setPaneRevoker { recorder.record($0) }
    let created = try await manager.createSession(label: nil)
    let sessionA = created.state.id
    let (_, events) = await broker.subscribe(as: .session(sessionA))

    try await manager.closeSession(sessionId: sessionA, capability: created.capability)

    // Exactly one revocation for A, and exactly one .sessionClosed on the stream.
    #expect(recorder.recorded == [sessionA])
    var iterator = events.makeAsyncIterator()
    var closedCount = 0
    while let event = await iterator.next() {
        if event.type == DaemonEventType.sessionClosed { closedCount += 1 }
    }
    #expect(closedCount == 1)
}

@Test("ghost reconciliation revokes an abandoned session's subscriptions")
func ghostReconciliationRevokes() async throws {
    let broker = EventBroker()
    let manager = SessionManager(eventBroker: broker, startsPendingRestoration: true)
    let recorder = RevokerRecorder()
    await manager.setPaneRevoker { recorder.record($0) }

    // A live session created at the live-authority tier (epoch 0)...
    let created = try await manager.createSession(label: nil)
    let sessionId = created.state.id
    // ...that a strictly-newer authoritative restore (epoch 1) OMITS is an
    // abandoned ghost and is torn down.
    _ = try await manager.restoreBatch([], owner: nil, epoch: 1, revision: 0)

    #expect(recorder.recorded == [sessionId])
    #expect(await broker.isRetired(sessionId))
    #expect(await manager.contains(sessionId) == false)
}
