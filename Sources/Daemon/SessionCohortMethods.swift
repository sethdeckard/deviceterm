// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionCohortMethods: the `session.setCohort` handler, the effect pump, and
// the session lifecycle seam that keeps cohorts converged.
//
// Every cohort mutation is one call into `PaneCoordinator`, which commits
// membership, pane bindings, re-homing, and verdicts in a single actor turn.
// The device consequences ride the pump, never a return value: `PaneCoordinator`
// enqueues them synchronously inside the commit turn, and the pump's single
// consumer applies them to `DeviceCoordinator` strictly in that order, so
// out-of-order application is structurally impossible: no sequence numbers
// to compare and no dedup to get wrong.

import DaemonProtocol
import Foundation

/// Applies cohort device effects to `DeviceCoordinator` in emission order.
///
/// Emission is a synchronous enqueue inside `PaneCoordinator`'s commit turn,
/// so the stream order is the actor's commit order; the one consumer task
/// preserves it. Exactly-once is structural too: journal hits and recorded
/// verdicts never re-emit, and each enqueued effect is consumed once.
public struct CohortEffectPump: Sendable {
    enum Element: Sendable {
        case effect(CohortDeviceEffect)
        /// A drain marker: resumed by the consumer after everything enqueued
        /// before it has been applied. Tests use it to assert
        /// `DeviceCoordinator` state deterministically.
        case quiesce(CheckedContinuation<Void, Never>)
    }

    private let continuation: AsyncStream<Element>.Continuation
    private let consumer: Task<Void, Never>

    init(deviceCoordinator: DeviceCoordinator) {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        self.continuation = continuation
        consumer = Task {
            for await element in stream {
                switch element {
                case let .effect(effect):
                    await deviceCoordinator.applyCohortEffect(effect)

                case let .quiesce(waiter):
                    waiter.resume()
                }
            }
        }
    }

    func emit(_ effect: CohortDeviceEffect) {
        continuation.yield(.effect(effect))
    }

    /// Wait until every effect enqueued before this call has been applied.
    func quiesce() async {
        await withCheckedContinuation { waiter in
            continuation.yield(.quiesce(waiter))
        }
    }
}

public enum SessionCohortMethods {
    /// `session.setCohort`. Validated-GUI only: membership decides who may
    /// drive another session's pane, and a close verdict decides who inherits
    /// its simulator, so a UDS caller must never reach either operation.
    static func setCohort(
        paneCoordinator: PaneCoordinator,
        sessionManager: SessionManager
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            // A malformed payload is a definite pre-mutation rejection, so it
            // maps to `invalidParams` rather than the dispatcher's catch-all:
            // the GUI's close path has to tell "refused, nothing committed"
            // apart from an indeterminate transport loss before it decides
            // whether to retry or abandon.
            let params: SessionSetCohortParams
            do {
                params = try JSONDecoder().decode(SessionSetCohortParams.self, from: paramsJSON)
            } catch {
                throw RPCMethodError.invalidParams("malformed session.setCohort params")
            }
            guard let cohortId = UUID(uuidString: params.cohortId) else {
                throw RPCMethodError.invalidParams("cohortId must be a UUID string")
            }
            // The ordering epoch is the caller's monotonic XPC connection id,
            // server-derived so it cannot be forged or rewound. A
            // `.validatedGUI` dispatch always carries a peer context; its
            // absence is a wiring bug rather than a caller condition.
            guard let epoch = DispatchPeerContext.current?.connectionId else {
                throw RPCMethodError.invalidParams("no connection context for setCohort")
            }
            let key = ProtectionOrderingKey(epoch: epoch, revision: params.revision)
            switch params.operation {
            case .reconcile:
                return try await reconcile(
                    params: params,
                    cohortId: cohortId,
                    key: key,
                    paneCoordinator: paneCoordinator,
                    sessionManager: sessionManager
                )

            case .beginClose:
                return try await beginClose(
                    params: params,
                    cohortId: cohortId,
                    key: key,
                    paneCoordinator: paneCoordinator
                )
            }
        }
    }

    /// Wire cohort convergence into session teardown and the effect pump into
    /// the coordinator pair. Called during composition, before the RPC
    /// servers bind; `main.swift` asserts both installations.
    ///
    /// The teardown seam runs for **every** teardown reason, not only an
    /// explicit `session.close`: a restore-batch reap removes sessions
    /// through the same path, and a reaped member of a live tab must hand its
    /// panes and devices to the survivors before the subscription sweep can
    /// orphan them.
    @discardableResult
    public static func installCohortWiring(
        sessionManager: SessionManager,
        paneCoordinator: PaneCoordinator,
        deviceCoordinator: DeviceCoordinator
    ) async -> CohortEffectPump {
        let pump = CohortEffectPump(deviceCoordinator: deviceCoordinator)
        await paneCoordinator.setDeviceEffectSink { pump.emit($0) }
        await sessionManager.setCohortRevoker { sessionId, incarnation in
            await paneCoordinator.tearDownSession(sessionId, incarnation: incarnation)
        }
        // Drain the pump before a registering incarnation becomes admissible,
        // so a prior incarnation's close consequences are applied before the
        // new one can create claims or ownership a late effect would sweep.
        // The device layer's UUID-keyed state stays sound because eras can no
        // longer overlap inside it.
        await sessionManager.setRegistrationBarrier { await pump.quiesce() }
        return pump
    }

    /// Decide a closing session's verdict from the `session.close` handler's
    /// pre-removal seam.
    ///
    /// The incarnation follows `PaneAccessPrincipal.ownerIncarnation`'s rule:
    /// the dispatch capture only when the caller IS the closing session, a
    /// manager resolve otherwise. The validated GUI's long-lived connection
    /// is authenticated as one session while legitimately closing another,
    /// and preferring its capture would record the wrong session's
    /// incarnation on the verdict. If resolution still comes up empty the
    /// session is being reaped concurrently, and the teardown seam owns the
    /// close: emitting a terminal disposition here, outside the ordered
    /// effect channel, could overtake a promotion the reap already enqueued
    /// and shut down a simulator the survivors keep.
    static func noteSessionClosing(
        sessionId: UUID,
        mode: PaneCloseMode,
        paneCoordinator: PaneCoordinator,
        sessionManager: SessionManager
    ) async {
        let incarnation = await PaneAccessPrincipal.ownerIncarnation(for: sessionId) {
            await sessionManager.incarnation(of: sessionId)
        }
        guard let incarnation else { return }
        await paneCoordinator.recordCloseVerdict(
            sessionId: sessionId,
            incarnation: incarnation,
            mode: mode
        )
    }

    // MARK: - Operations

    private static func reconcile(
        params: SessionSetCohortParams,
        cohortId: UUID,
        key: ProtectionOrderingKey,
        paneCoordinator: PaneCoordinator,
        sessionManager: SessionManager
    ) async throws -> Data {
        guard let rawMembers = params.members, !rawMembers.isEmpty else {
            throw RPCMethodError.invalidParams("reconcile requires a non-empty members list")
        }
        guard let rawRepresentative = params.representative,
            let representative = UUID(uuidString: rawRepresentative) else {
            throw RPCMethodError.invalidParams("reconcile requires a representative UUID")
        }
        // An absent `replaces` and a malformed one are different requests:
        // the first installs alongside whatever exists, the second names a
        // retirement this handler failed to read. Executing the second with
        // non-replacement semantics would leave the intended outgoing cohort
        // alive, or refuse on foreign membership when the caller did
        // everything right.
        var replaces: UUID?
        if let rawReplaces = params.replaces {
            guard let parsed = UUID(uuidString: rawReplaces) else {
                throw RPCMethodError.invalidParams("replaces must be a UUID string")
            }
            replaces = parsed
        }
        // Incarnations are resolved here, from the manager, rather than taken
        // from the wire: a caller-supplied incarnation would let a stale GUI
        // pin a member at one its session has already moved past. The
        // coordinator re-checks liveness against its own active-incarnation
        // map inside the commit, so a session that closes between this lookup
        // and the commit is refused rather than installed dead.
        var members: [CohortMember] = []
        for raw in rawMembers {
            guard let sessionId = UUID(uuidString: raw) else {
                throw RPCMethodError.invalidParams("member ids must be UUID strings")
            }
            guard let incarnation = await sessionManager.incarnation(of: sessionId) else {
                throw RPCMethodError.invalidParams("member \(raw) is not a live session")
            }
            members.append(CohortMember(sessionId: sessionId, incarnation: incarnation))
        }
        // A duplicate would sit twice in the ordered membership, and a later
        // close of that member would emit its consequences twice. The reducer
        // re-checks, but this is a definite wire defect and reports as one.
        guard Set(members.map(\.sessionId)).count == members.count else {
            throw RPCMethodError.invalidParams("member ids must be unique")
        }
        let transition = await paneCoordinator.reconcileCohort(
            cohortId: cohortId,
            members: members,
            representative: representative,
            replaces: replaces,
            requested: params.bindings ?? [],
            key: key
        )
        return try JSONEncoder().encode(
            SessionSetCohortResult(
                applied: transition.applied,
                revision: params.revision,
                bindings: transition.applied ? transition.bindings : nil
            )
        )
    }

    private static func beginClose(
        params: SessionSetCohortParams,
        cohortId: UUID,
        key: ProtectionOrderingKey,
        paneCoordinator: PaneCoordinator
    ) async throws -> Data {
        guard let rawTransition = params.transitionId,
            let transitionId = UUID(uuidString: rawTransition) else {
            throw RPCMethodError.invalidParams("beginClose requires a transitionId UUID")
        }
        guard let rawLeaving = params.leaving, !rawLeaving.isEmpty else {
            throw RPCMethodError.invalidParams("beginClose requires a non-empty leaving list")
        }
        // Required rather than defaulted: the mode only matters when nothing
        // remains, which is exactly when a silent default would contradict
        // the user's shutdown choice.
        guard let mode = params.mode else {
            throw RPCMethodError.invalidParams("beginClose requires a mode")
        }
        var leaving: [UUID] = []
        for raw in rawLeaving {
            guard let id = UUID(uuidString: raw) else {
                throw RPCMethodError.invalidParams("leaving ids must be UUID strings")
            }
            leaving.append(id)
        }
        let commit = await paneCoordinator.beginCohortClose(
            cohortId: cohortId,
            transitionId: transitionId,
            leaving: leaving,
            mode: mode,
            key: key
        )
        return try JSONEncoder().encode(
            SessionSetCohortResult(
                applied: commit.applied,
                revision: params.revision,
                outcome: commit.outcome
            )
        )
    }
}
