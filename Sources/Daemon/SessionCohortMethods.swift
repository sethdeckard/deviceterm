// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionCohortMethods: the `session.setCohort` handler, and the session
// lifecycle seam that keeps cohorts converged.
//
// Every cohort mutation is one call into `PaneCoordinator`, which commits
// membership and pane bindings in a single actor turn and hands back a
// `CohortTransition` describing what it decided. This layer decodes and
// resolves incarnations. It holds no cohort state of its own and never reads a
// "last result" property: an intervening call could overwrite one before this
// handler got to it, so results travel inside the transition that produced
// them.

import DaemonProtocol
import Foundation

public enum SessionCohortMethods {
    /// `session.setCohort`. Validated-GUI only: membership decides who may
    /// drive another session's pane, so a UDS caller must never reach it.
    static func setCohort(
        paneCoordinator: PaneCoordinator,
        sessionManager: SessionManager
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            // A malformed payload is a definite pre-mutation rejection, so it
            // maps to `invalidParams` rather than the dispatcher's catch-all:
            // the GUI has to tell "refused, nothing committed" apart from an
            // indeterminate transport loss before it decides whether to retry
            // or abandon.
            let params: SessionSetCohortParams
            do {
                params = try JSONDecoder().decode(SessionSetCohortParams.self, from: paramsJSON)
            } catch {
                throw RPCMethodError.invalidParams("malformed session.setCohort params")
            }
            guard let cohortId = UUID(uuidString: params.cohortId) else {
                throw RPCMethodError.invalidParams("cohortId must be a UUID string")
            }
            guard !params.members.isEmpty else {
                throw RPCMethodError.invalidParams("members must be non-empty")
            }
            guard let representative = UUID(uuidString: params.representative) else {
                throw RPCMethodError.invalidParams("representative must be a UUID string")
            }
            // An absent `replaces` and a malformed one are different requests:
            // the first installs alongside whatever exists, the second names a
            // retirement this handler failed to read. Executing the second
            // with non-replacement semantics would leave the intended outgoing
            // cohort alive, or refuse on foreign membership when the caller
            // did everything right.
            var replaces: UUID?
            if let rawReplaces = params.replaces {
                guard let parsed = UUID(uuidString: rawReplaces) else {
                    throw RPCMethodError.invalidParams("replaces must be a UUID string")
                }
                replaces = parsed
            }
            // The ordering epoch is the caller's monotonic XPC connection id,
            // server-derived so it cannot be forged or rewound. A
            // `.validatedGUI` dispatch always carries a peer context; its
            // absence is a wiring bug rather than a caller condition.
            guard let epoch = DispatchPeerContext.current?.connectionId else {
                throw RPCMethodError.invalidParams("no connection context for setCohort")
            }
            let key = ProtectionOrderingKey(epoch: epoch, revision: params.revision)
            // Incarnations are resolved here, from the manager, rather than
            // taken from the wire: a caller-supplied incarnation would let a
            // stale GUI pin a member at one its session has already moved
            // past. The coordinator re-checks liveness against its own
            // active-incarnation map inside the commit, so a session that
            // closes between this lookup and the commit is refused rather
            // than installed dead.
            var members: [CohortMember] = []
            for raw in params.members {
                guard let sessionId = UUID(uuidString: raw) else {
                    throw RPCMethodError.invalidParams("member ids must be UUID strings")
                }
                guard let incarnation = await sessionManager.incarnation(of: sessionId) else {
                    throw RPCMethodError.invalidParams("member \(raw) is not a live session")
                }
                members.append(CohortMember(sessionId: sessionId, incarnation: incarnation))
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
    }

    /// Wire cohort convergence into session teardown. Called during
    /// composition, before the RPC servers bind.
    ///
    /// Runs for **every** teardown reason, not only an explicit
    /// `session.close`: a restore-batch reap removes sessions through the same
    /// path, and a member the cohort store still believed live would keep a
    /// dead session in every sibling's membership. It runs before
    /// `paneRevoker`, so the membership removal and the active-incarnation
    /// clear are visible before the subscription sweep suspends.
    public static func installCohortWiring(
        sessionManager: SessionManager,
        paneCoordinator: PaneCoordinator
    ) async {
        await sessionManager.setCohortRevoker { sessionId, incarnation in
            await paneCoordinator.tearDownSession(sessionId, incarnation: incarnation)
        }
    }
}
