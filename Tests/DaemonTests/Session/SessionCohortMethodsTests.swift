// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// The `session.setCohort` handler's wire
// validation, driven through the real `defaultRegistry(...)`.
// The handler's contract is that a malformed payload is a *definite*
// pre-mutation rejection (`invalidParams`), distinguishable from an
// indeterminate transport loss. The case worth pinning is `replaces`: an
// absent value and an unparseable one are different requests, and collapsing
// them (the optional-flatMap shape) would execute a replacement request with
// non-replacement semantics. That leaves the outgoing cohort alive, or
// refuses on foreign membership when the caller did everything right.

private func setCohortHandler(
    manager: SessionManager = SessionManager()
) throws -> MethodRegistry.Handler {
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: manager,
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator()
    )
    guard let handler = registry.handler(for: RPCMethod.sessionSetCohort.rawValue) else {
        throw SetCohortTestError.notRegistered
    }
    return handler
}

private enum SetCohortTestError: Error { case notRegistered }

/// Invoke the handler under a bound validated-GUI dispatch context, mirroring
/// the transport dispatcher.
private func invokeSetCohort(
    _ handler: MethodRegistry.Handler,
    params: [String: Any]
) async throws -> Data {
    let context = DispatchPeerContext(
        transport: .xpc,
        connectionId: 1,
        authenticatedSession: nil,
        validatedGUIPeer: true
    )
    let payload = try JSONSerialization.data(withJSONObject: params)
    return try await DispatchPeerContext.$current.withValue(context) {
        try await handler(payload)
    }
}

@Test
func setCohortIsValidatedGUIScoped() {
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: SessionManager(),
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator()
    )
    #expect(registry.scope(of: RPCMethod.sessionSetCohort.rawValue) == .validatedGUI)
}

@Test
func aMalformedReplacesIsRefusedAsInvalidParams() async throws {
    let handler = try setCohortHandler()
    let memberId = UUID().uuidString
    do {
        _ = try await invokeSetCohort(handler, params: [
            "operation": "reconcile",
            "cohortId": UUID().uuidString,
            "revision": 1,
            "members": [memberId],
            "representative": memberId,
            "replaces": "not-a-uuid"
        ])
        Issue.record("expected a malformed replaces to be refused")
    } catch let error as RPCMethodError {
        #expect(error.code == RPCMethodError.invalidParamsCode)
        #expect(error.message.contains("replaces"))
    } catch {
        Issue.record("expected RPCMethodError, got \(error)")
    }
}

@Test
func anAbsentReplacesPassesReplacesValidation() async throws {
    // The same request without `replaces` gets past that check and fails
    // later, on member liveness, proving the refusal above is about the
    // malformed field and not the payload's general shape.
    let handler = try setCohortHandler()
    let memberId = UUID().uuidString
    do {
        _ = try await invokeSetCohort(handler, params: [
            "operation": "reconcile",
            "cohortId": UUID().uuidString,
            "revision": 1,
            "members": [memberId],
            "representative": memberId
        ])
        Issue.record("expected an unknown member to be refused")
    } catch let error as RPCMethodError {
        #expect(error.code == RPCMethodError.invalidParamsCode)
        #expect(error.message.contains("not a live session"))
    } catch {
        Issue.record("expected RPCMethodError, got \(error)")
    }
}

@Test
func beginCloseRefusesMissingFields() async throws {
    let handler = try setCohortHandler()
    let cohortId = UUID().uuidString
    let id = UUID().uuidString
    // Missing transitionId (a retry could not be correlated to its first
    // attempt), missing leaving, and missing mode (a silent default would
    // contradict the user's shutdown choice exactly when it matters, on the
    // last member out).
    let incomplete: [[String: Any]] = [
        [
            "operation": "beginClose", "cohortId": cohortId, "revision": 1,
            "leaving": [id], "mode": "detach"
        ],
        [
            "operation": "beginClose", "cohortId": cohortId, "revision": 1,
            "transitionId": id, "mode": "detach"
        ],
        [
            "operation": "beginClose", "cohortId": cohortId, "revision": 1,
            "transitionId": id, "leaving": [id]
        ]
    ]
    for params in incomplete {
        do {
            _ = try await invokeSetCohort(handler, params: params)
            Issue.record("expected the incomplete beginClose to be refused: \(params.keys)")
        } catch let error as RPCMethodError {
            #expect(error.code == RPCMethodError.invalidParamsCode)
        } catch {
            Issue.record("expected RPCMethodError, got \(error)")
        }
    }
}

@Test("a beginClose retry through the registry replays the journalled verdict")
func beginCloseRetryReplaysThroughTheRegistry() async throws {
    // An unknown cohort takes the journalled-terminal arm, which is enough to
    // exercise idempotency end to end without standing up sessions: the first
    // call decides, the retry replays, and both replies carry the identical
    // verdict.
    let handler = try setCohortHandler()
    let transitionId = UUID().uuidString
    let params: [String: Any] = [
        "operation": "beginClose",
        "cohortId": UUID().uuidString,
        "revision": 1,
        "transitionId": transitionId,
        "leaving": [UUID().uuidString],
        "mode": "shutdown"
    ]
    let first = try JSONDecoder().decode(
        SessionSetCohortResult.self,
        from: try await invokeSetCohort(handler, params: params)
    )
    var retryParams = params
    retryParams["revision"] = 2
    let retry = try JSONDecoder().decode(
        SessionSetCohortResult.self,
        from: try await invokeSetCohort(handler, params: retryParams)
    )
    #expect(first.applied)
    #expect(first.outcome == .shutdown)
    #expect(retry.applied)
    #expect(retry.outcome == first.outcome)
}

@Test
func duplicateMemberIdsAreRefused() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let handler = try setCohortHandler(manager: manager)
    let memberId = created.state.id.uuidString
    do {
        _ = try await invokeSetCohort(handler, params: [
            "operation": "reconcile",
            "cohortId": UUID().uuidString,
            "revision": 1,
            "members": [memberId, memberId],
            "representative": memberId
        ])
        Issue.record("expected duplicate member ids to be refused")
    } catch let error as RPCMethodError {
        #expect(error.code == RPCMethodError.invalidParamsCode)
        #expect(error.message.contains("unique"))
    } catch {
        Issue.record("expected RPCMethodError, got \(error)")
    }
}

@Test
func installCohortWiringInstallsEverySeam() async {
    let manager = SessionManager()
    let paneCoordinator = PaneCoordinator()
    _ = await SessionCohortMethods.installCohortWiring(
        sessionManager: manager,
        paneCoordinator: paneCoordinator,
        deviceCoordinator: DeviceCoordinator()
    )
    #expect(await paneCoordinator.hasDeviceEffectSink)
    #expect(await manager.hasCohortRevoker)
    #expect(await manager.hasRegistrationBarrier)
}

@Test
func theRegistrationBarrierRunsBeforeProducerActivation() async throws {
    // Producer activation immediately precedes admission (phase .ready), so
    // barrier-before-activation is what guarantees pending device effects
    // apply before this incarnation can register a claim or take ownership.
    let manager = SessionManager()
    let order = OrderBox()
    await manager.setRegistrationBarrier { order.note("barrier") }
    await manager.setPaneActivator { _, _ in order.note("activate") }
    _ = try await manager.createSession(label: nil)
    #expect(order.events == ["barrier", "activate"])
}

@Test
func aGUICloseOfAnotherSessionUsesTheTargetsIncarnation() async throws {
    // The GUI's long-lived connection is authenticated as one session while
    // legitimately closing another. Preferring its dispatch-captured
    // incarnation would stamp the wrong session's incarnation on the close
    // verdict; the target's own must be resolved instead.
    let manager = SessionManager()
    let authenticated = try await manager.createSession(label: nil)
    let target = try await manager.createSession(label: nil)
    let targetIncarnation = try #require(await manager.incarnation(of: target.state.id))
    let paneCoordinator = PaneCoordinator()
    let effects = CloseEffectBox()
    await paneCoordinator.setDeviceEffectSink { effects.append($0) }
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: manager,
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: paneCoordinator
    )
    let handler = try #require(registry.handler(for: RPCMethod.sessionClose.rawValue))
    let params = try JSONEncoder().encode(
        SessionMethods.CloseParams(
            sessionId: target.state.id.uuidString,
            cap: target.capability.token,
            mode: "detach"
        )
    )
    // A deliberately wrong captured incarnation, so using it is detectable
    // whatever the target's real one happens to be.
    let context = DispatchPeerContext(
        transport: .xpc,
        connectionId: 1,
        authenticatedSession: authenticated.state,
        validatedGUIPeer: true,
        sessionIncarnation: 777
    )
    _ = try await DispatchPeerContext.$current.withValue(context) {
        try await handler(params)
    }
    #expect(effects.effects.count == 1)
    guard case let .close(close) = effects.effects.first else {
        Issue.record("expected a close effect, got \(effects.effects)")
        return
    }
    #expect(close.sessionId == target.state.id)
    #expect(close.incarnation == targetIncarnation)
}

/// Ordered event markers, appended from @Sendable seams.
private final class OrderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func note(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

/// Close effects captured off the coordinator's synchronous sink.
private final class CloseEffectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CohortDeviceEffect] = []

    var effects: [CohortDeviceEffect] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ effect: CohortDeviceEffect) {
        lock.lock()
        storage.append(effect)
        lock.unlock()
    }
}
