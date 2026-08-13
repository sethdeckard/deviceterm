// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

// `device.restoreOwnership`: how a helper that restarted gets deviceterm's
// owned-sim claims back, preserving live session attribution where there is
// any.
//
// Ownership lives in daemon memory alone, so a replacement helper comes back
// believing it owns nothing. A sim carried by a pane is restored by
// re-attaching the pane; a sim the user detached has nothing to carry it, and
// this is the only path that brings it back.
//
// Two guards refuse claims: ownership the daemon already holds is preserved
// rather than overwritten, and a sim CoreSimulator does not report as Booted
// right now is not claimed. Everything else is accepted, with an attribution
// the daemon can't confirm live removed. The coordinator asks for the booted
// set through an injected reader, so what the daemon DOES with the answer is
// pinned here on any host; that the reader really reads CoreSimulator is the
// live track's job.

private let simA = "AAAAAAAA-1111-1111-1111-111111111111"
private let simB = "BBBBBBBB-2222-2222-2222-222222222222"

/// A coordinator whose CoreSimulator boot-state read answers with exactly
/// `booted` (lowercased), or with nil for a bridge that can't enumerate.
private func coordinator(
    booted: [String]?,
    eventBroker: EventBroker? = nil
) -> DeviceCoordinator {
    let answer = booted.map { Set($0.map { $0.lowercased() }) }
    return DeviceCoordinator(
        eventBroker: eventBroker,
        readBootedUDIDs: { answer }
    )
}

// MARK: - Coordinator rules

@Test
func restoreOwnershipClaimsABootedSimWithNoOwner() async {
    let coordinator = coordinator(booted: [simA])
    let session = UUID()

    let restored = await coordinator.restoreOwnership([simA.lowercased(): session])

    #expect(restored.attributed == [simA.lowercased()])
    #expect(await coordinator.ownerSession(forUDID: simA) == session)
}

@Test
func restoreOwnershipLeavesASimThatIsNoLongerBootedUnclaimed() async {
    // The case the whole thing has to fail closed on: a sim that shut down
    // while the helper was gone. Claiming it would put a device deviceterm no
    // longer owns back into the running-sim count and the shut-down prompts.
    let coordinator = coordinator(booted: [simB])
    let session = UUID()

    let restored = await coordinator.restoreOwnership([simA.lowercased(): session])

    #expect(restored.attributed.isEmpty)
    #expect(await coordinator.ownerSession(forUDID: simA) == nil)
    #expect(await coordinator.ownedCount == 0)
}

@Test
func restoreOwnershipDoesNotOverwriteALiveAttribution() async throws {
    // The live map is newer than any mirror a caller can hold, so a claim that
    // disagrees with it loses. Otherwise a stale mirror could re-home a sim a
    // different tab has since booted.
    let coordinator = coordinator(booted: [simA])
    let live = UUID()
    let stale = UUID()
    try await coordinator.recordOwnership(udid: simA, sessionId: live)

    let restored = await coordinator.restoreOwnership([simA.lowercased(): stale])

    #expect(restored.attributed.isEmpty)
    #expect(await coordinator.ownerSession(forUDID: simA) == live)
}

@Test
func restoreOwnershipIsIdempotentForTheOwnerItAlreadyHas() async throws {
    // A retry, or a re-assertion racing the pane re-attach that recorded the
    // same thing, reports the sim as restored rather than as refused: the
    // caller asked for a state the daemon is already in.
    let coordinator = coordinator(booted: [simA])
    let session = UUID()
    try await coordinator.recordOwnership(udid: simA, sessionId: session)

    let restored = await coordinator.restoreOwnership([simA.lowercased(): session])

    #expect(restored.attributed == [simA.lowercased()])
    #expect(await coordinator.ownedCount == 1)
}

@Test
func restoreOwnershipMatchesUDIDsCaseInsensitively() async {
    let coordinator = coordinator(booted: [simA.lowercased()])
    let session = UUID()

    let restored = await coordinator.restoreOwnership([simA.uppercased(): session])

    #expect(restored.attributed == [simA.lowercased()])
    #expect(await coordinator.ownerSession(forUDID: simA) == session)
}

@Test
func restoreOwnershipDoesNotReportASimItOwnsThatIsNoLongerBooted() async throws {
    // An attribution the daemon already holds can be stale: nothing disowns a
    // sim that shut down until the notifier says so. Reporting it unchecked
    // would answer "restored" for a sim that is gone, which is the one thing
    // the result is supposed to rule out.
    let coordinator = coordinator(booted: [])
    let session = UUID()
    try await coordinator.recordOwnership(udid: simA, sessionId: session)

    let restored = await coordinator.restoreOwnership([simA.lowercased(): session])

    #expect(restored.attributed.isEmpty)
    #expect(restored.written.isEmpty)
    // The stale attribution itself is left alone; only the report is gated.
    // Disowning here would be a shutdown this call did not observe.
    #expect(await coordinator.ownerSession(forUDID: simA) == session)
}

@Test
func restoreOwnershipReportsNothingWhenTheBridgeCannotEnumerateEitherWay() async throws {
    // Including for a sim it already attributes: a CoreSimulator that can't
    // answer can't confirm any of them are up.
    let coordinator = coordinator(booted: nil)
    let session = UUID()
    try await coordinator.recordOwnership(udid: simA, sessionId: session)

    let restored = await coordinator.restoreOwnership([simA.lowercased(): session])

    #expect(restored.attributed.isEmpty)
}

@Test
func restoreOwnershipClaimsNothingWhenTheBridgeCannotEnumerate() async {
    // Same posture as `ownedBootedCount` and `isBooted`: a CoreSimulator that
    // can't answer means we can't confirm the sim is up, and an unconfirmed
    // sim is not claimed.
    let coordinator = coordinator(booted: nil)

    let restored = await coordinator.restoreOwnership([simA.lowercased(): UUID()])

    #expect(restored.attributed.isEmpty)
    #expect(await coordinator.ownedCount == 0)
}

@Test
func restoreOwnershipPublishesNoBootEvent() async throws {
    // Bookkeeping catching up with reality, not a transition. A subscriber
    // told otherwise would see a boot that never happened, and anything
    // reacting to boots would act on a sim that has been running all along.
    let broker = EventBroker()
    let coordinator = coordinator(booted: [simA], eventBroker: broker)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)
    defer { Task { await broker.unsubscribe(subscriptionId) } }

    _ = await coordinator.restoreOwnership([simA.lowercased(): UUID()])
    // A real publish would already be queued by now; follow with one that
    // definitely publishes, so the assertion is "the next event is the boot,
    // not a restore" rather than "nothing arrived within a sleep".
    await coordinator.noteExternalBoot(udid: simB)

    var iterator = stream.makeAsyncIterator()
    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.deviceBooted)
    #expect(event.udid == simB.lowercased())
}

@Test
func demoteOwnershipMovesOnlyTheOwnerItNames() async throws {
    // Compare-and-set, so demoting a claim can't take out an attribution
    // something else made for the same sim in between.
    let coordinator = coordinator(booted: [simA, simB])
    let mine = UUID()
    let other = UUID()
    try await coordinator.recordOwnership(udid: simA, sessionId: mine)
    try await coordinator.recordOwnership(udid: simB, sessionId: other)

    await coordinator.demoteOwnership([
        simA.lowercased(): mine,
        simB.lowercased(): mine
    ])

    #expect(await coordinator.ownerSession(forUDID: simA) == nil)
    #expect(await coordinator.ownerSession(forUDID: simB) == other)
    // Demoted, not removed: the sim is still deviceterm's, just Unlinked.
    #expect(await coordinator.ownedCount == 2)
}

// MARK: - Handler validation

/// Answers "alive" a fixed number of times and "dead" after, so a handler that
/// checks liveness on both sides of a commit sees the session die inside it.
///
/// A serial queue rather than an actor because `SessionManager`'s liveness
/// predicate is synchronous, and rather than a bare lock because that is the
/// serialization this codebase asks for when a synchronous seam rules an actor
/// out.
private final class LivenessScript: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deviceterm.tests.liveness-script")
    private var remainingAlive: Int

    init(aliveFor: Int) { remainingAlive = aliveFor }

    func next() -> Bool {
        queue.sync {
            guard remainingAlive > 0 else { return false }
            remainingAlive -= 1
            return true
        }
    }
}

private func restoreOwnershipHandler(
    coordinator: DeviceCoordinator,
    sessionManager: SessionManager
) -> MethodRegistry.Handler {
    DeviceMethods.restoreOwnership(
        coordinator: coordinator,
        sessionManager: sessionManager
    )
}

private func restoreParams(_ devices: [(String, String?)]) throws -> Data {
    try JSONEncoder().encode(
        DeviceRestoreOwnershipParams(
            devices: devices.map { RestoredSimOwnership(udid: $0.0, sessionId: $0.1) }
        )
    )
}

@Test
func restoreOwnershipDemotesAClaimNamingASessionItDoesNotHold() async throws {
    // Ownership is what the caller asserted, and it holds whether or not the
    // attribution still resolves. Refusing would leave a running sim nothing
    // claims, which is worse than the Unlinked state the daemon already models.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, name: nil)
    let coordinator = coordinator(booted: [simA, simB])
    let handler = restoreOwnershipHandler(coordinator: coordinator, sessionManager: manager)

    let data = try await handler(
        try restoreParams([
            (simA, created.state.id.uuidString),
            (simB, UUID().uuidString)
        ])
    )

    let result = try JSONDecoder().decode(DeviceRestoreOwnershipResult.self, from: data)
    #expect(result.restoredCount == 2)
    #expect(await coordinator.ownerSession(forUDID: simA) == created.state.id)
    // Owned, attributed to nobody: the id the caller named is not one this
    // daemon holds, so it is dropped rather than recorded.
    #expect(await coordinator.ownerSession(forUDID: simB) == nil)
    #expect(await coordinator.ownedCount == 2)
}

@Test
func restoreOwnershipDemotesAClaimWhoseSessionDiedDuringTheCommit() async throws {
    // The liveness gate is a preflight. Crossing to the coordinator is a
    // suspension, and a session closing inside it would leave a sim attributed
    // to one that is gone.
    //
    // The owner reads alive for the gate and dead for the re-check, which is
    // that interleaving exactly. The sim stays deviceterm's either way; only
    // the attribution goes.
    let liveness = LivenessScript(aliveFor: 1)
    let manager = SessionManager(isProcessAlive: { _ in liveness.next() })
    let created = try await manager.createSession(
        label: nil,
        owner: OwnerProcessIdentity(pid: 4_242, pidVersion: 1, euid: geteuid())
    )
    let coordinator = coordinator(booted: [simA])
    let handler = restoreOwnershipHandler(coordinator: coordinator, sessionManager: manager)

    let data = try await handler(try restoreParams([(simA, created.state.id.uuidString)]))

    let result = try JSONDecoder().decode(DeviceRestoreOwnershipResult.self, from: data)
    #expect(result.udids == [simA.lowercased()])
    #expect(await coordinator.ownerSession(forUDID: simA) == nil)
    #expect(await coordinator.ownedCount == 1)
}

@Test
func restoreOwnershipLeavesAnAttributionItDidNotWrite() async throws {
    // Only what this call added is in question. A sim the daemon already
    // attributed to the session is absent from `written`, so the post-commit
    // liveness pass never revisits it and the attribution stands.
    let liveness = LivenessScript(aliveFor: 1)
    let manager = SessionManager(isProcessAlive: { _ in liveness.next() })
    let created = try await manager.createSession(
        label: nil,
        owner: OwnerProcessIdentity(pid: 4_242, pidVersion: 1, euid: geteuid())
    )
    let coordinator = coordinator(booted: [simA])
    try await coordinator.recordOwnership(udid: simA, sessionId: created.state.id)
    let handler = restoreOwnershipHandler(coordinator: coordinator, sessionManager: manager)

    _ = try await handler(try restoreParams([(simA, created.state.id.uuidString)]))

    #expect(await coordinator.ownerSession(forUDID: simA) == created.state.id)
}

@Test(
    "a malformed udid rejects the batch with nothing mutated",
    arguments: ["not-a-uuid", "", "   "]
)
func restoreOwnershipRejectsAMalformedUDID(udid: String) async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, name: nil)
    let coordinator = coordinator(booted: [simA])
    let handler = restoreOwnershipHandler(coordinator: coordinator, sessionManager: manager)

    await #expect(throws: RPCMethodError.self) {
        _ = try await handler(
            try restoreParams([
                (simA, created.state.id.uuidString),
                (udid, created.state.id.uuidString)
            ])
        )
    }
    // The valid entry alongside it is refused too: parsing completes before
    // anything is touched, so a caller can't half-apply a bad batch.
    #expect(await coordinator.ownedCount == 0)
}

@Test
func restoreOwnershipClaimsAnUnattributedSimWithNoSessionCheck() async throws {
    // The Unlinked sim: a tab closed with Detach ended its session while the
    // Simulator kept running and stayed deviceterm's. There is no live session
    // to check, and refusing it would drop exactly the sims this method is for.
    let manager = SessionManager()
    let coordinator = coordinator(booted: [simA])
    let handler = restoreOwnershipHandler(coordinator: coordinator, sessionManager: manager)

    let data = try await handler(try restoreParams([(simA, nil)]))

    let result = try JSONDecoder().decode(DeviceRestoreOwnershipResult.self, from: data)
    #expect(result.udids == [simA.lowercased()])
    #expect(await coordinator.ownedCount == 1)
    // Owned, and attributed to nobody: the status item groups it under
    // "Unlinked" rather than under a session that no longer resolves.
    #expect(await coordinator.ownerSession(forUDID: simA) == nil)
}

@Test
func anUnattributedClaimDoesNotDisplaceALiveAttribution() async throws {
    // Never-overwrite runs both ways. A mirror that hasn't caught up with a
    // sim's new owner must not blank the attribution the daemon already holds.
    let coordinator = coordinator(booted: [simA])
    let live = UUID()
    try await coordinator.recordOwnership(udid: simA, sessionId: live)
    let handler = restoreOwnershipHandler(
        coordinator: coordinator,
        sessionManager: SessionManager()
    )

    _ = try await handler(try restoreParams([(simA, nil)]))

    #expect(await coordinator.ownerSession(forUDID: simA) == live)
}

@Test
func anUnattributedSimIsStillReportedOnARetry() async throws {
    // Idempotence has to cover nil against nil, or a retry would report the
    // Unlinked sim as refused and a caller could conclude it had been lost.
    let coordinator = coordinator(booted: [simA])
    let handler = restoreOwnershipHandler(
        coordinator: coordinator,
        sessionManager: SessionManager()
    )
    _ = try await handler(try restoreParams([(simA, nil)]))

    let data = try await handler(try restoreParams([(simA, nil)]))

    let result = try JSONDecoder().decode(DeviceRestoreOwnershipResult.self, from: data)
    #expect(result.udids == [simA.lowercased()])
    #expect(await coordinator.ownedCount == 1)
}

@Test
func restoreOwnershipRejectsAMalformedSessionId() async throws {
    let manager = SessionManager()
    let coordinator = coordinator(booted: [simA])
    let handler = restoreOwnershipHandler(coordinator: coordinator, sessionManager: manager)

    await #expect(throws: RPCMethodError.self) {
        _ = try await handler(try restoreParams([(simA, "not-a-uuid")]))
    }
    #expect(await coordinator.ownedCount == 0)
}

@Test
func restoreOwnershipRejectsADuplicateUDID() async throws {
    // Two owners for one sim is not a batch the daemon can honor either way
    // round, and silently picking one would be worse than refusing.
    let manager = SessionManager()
    let first = try await manager.createSession(label: nil, name: nil)
    let second = try await manager.createSession(label: nil, name: nil)
    let coordinator = coordinator(booted: [simA])
    let handler = restoreOwnershipHandler(coordinator: coordinator, sessionManager: manager)

    await #expect(throws: RPCMethodError.self) {
        _ = try await handler(
            try restoreParams([
                (simA.lowercased(), first.state.id.uuidString),
                (simA.uppercased(), second.state.id.uuidString)
            ])
        )
    }
    #expect(await coordinator.ownedCount == 0)
}

@Test
func restoreOwnershipRejectsMalformedParams() async throws {
    let manager = SessionManager()
    let coordinator = coordinator(booted: [])
    let handler = restoreOwnershipHandler(coordinator: coordinator, sessionManager: manager)

    await #expect(throws: RPCMethodError.self) {
        _ = try await handler(Data("{\"devices\":\"nope\"}".utf8))
    }
}

@Test
func restoreOwnershipAcceptsAnEmptyBatch() async throws {
    let manager = SessionManager()
    let coordinator = coordinator(booted: [simA])
    let handler = restoreOwnershipHandler(coordinator: coordinator, sessionManager: manager)

    let data = try await handler(try restoreParams([]))

    let result = try JSONDecoder().decode(DeviceRestoreOwnershipResult.self, from: data)
    #expect(result.restoredCount == 0)
    #expect(result.udids.isEmpty)
}

// MARK: - Scope

@Test
func restoreOwnershipRefusedOverUDS() async throws {
    // `.validatedGUI`: attributing ownership on another session's behalf is
    // exactly what a UDS caller must not reach, and an authenticated
    // connection doesn't change that. The dispatcher's scope gate refuses it
    // before the handler runs.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, name: nil)
    let deviceCoordinator = coordinator(booted: [simA])
    let path = tempSocketPath(prefix: "deviceterm-restore-own")
    let harness = try await startAuthenticatedHarness(
        path: path,
        sessionManager: manager,
        deviceCoordinator: deviceCoordinator,
        existingSession: created
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    try client.send(
        RPCEnvelope(
            id: 1,
            type: .request,
            method: RPCMethod.deviceRestoreOwnership.rawValue,
            body: .params(try restoreParams([(simA, created.state.id.uuidString)]))
        )
    )
    let response = try client.receive()

    guard case let .error(error) = response.body else {
        Issue.record("expected .error for UDS device.restoreOwnership; got \(response.body)")
        return
    }
    #expect(error.code == RPCMethodError.roleViolationCode)
    #expect(await deviceCoordinator.ownedCount == 0)
}
