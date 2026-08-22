// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Handlers for `automation.grant` / `automation.revoke`.
///
/// Both are `.validatedGUI`-scoped, so the dispatcher admits them only over
/// XPC from a signature-validated GUI peer. UDS can never reach them. The
/// issuing connection and the ordering epoch are read from the bound
/// `DispatchPeerContext` (never the payload), so a request can't claim to
/// act for another connection or forge its order.
///
/// Payload handling is all-or-none: a malformed session id fails
/// `[UUID]` decoding and the request is rejected `invalidParams` before any
/// mutation; a grant additionally requires that **every** target is a live
/// session: enforced atomically inside the store against its live-session
/// set. A revoke does not require live targets: a session already gone is
/// treated as already-revoked and stores nothing (so a late or spurious
/// revoke can't accrete tombstones), while live targets are tombstoned.
enum AutomationMethods {
    static func grant(store: AutomationGrantStore) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try decodeParams(paramsJSON, verb: "automation.grant")
            guard let context = DispatchPeerContext.current else {
                throw RPCMethodError.unauthorized("automation.grant requires a dispatch context")
            }
            let key = GrantOrderingKey(epoch: context.connectionId, revision: params.revision)
            switch await store.grant(
                sessionIds: params.sessionIds,
                key: key,
                issuedBy: context.connectionId
            ) {
            case .sessionNotLive:
                throw RPCMethodError.invalidParams(
                    "automation.grant: a target is not a live session"
                )

            case .applied:
                return try JSONEncoder().encode(AutomationGrantResult(applied: true))

            case .notApplied:
                return try JSONEncoder().encode(AutomationGrantResult(applied: false))
            }
        }
    }

    static func revoke(store: AutomationGrantStore) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try decodeParams(paramsJSON, verb: "automation.revoke")
            guard let context = DispatchPeerContext.current else {
                throw RPCMethodError.unauthorized("automation.revoke requires a dispatch context")
            }
            let key = GrantOrderingKey(epoch: context.connectionId, revision: params.revision)
            let applied = await store.revoke(sessionIds: params.sessionIds, key: key)
            return try JSONEncoder().encode(AutomationGrantResult(applied: applied))
        }
    }

    /// Decode the typed `[UUID]` payload, mapping any malformed id (a decode
    /// failure) to `invalidParams` so the whole batch is rejected atomically.
    private static func decodeParams(_ json: Data, verb: String) throws -> AutomationGrantParams {
        do {
            return try JSONDecoder().decode(AutomationGrantParams.self, from: json)
        } catch {
            throw RPCMethodError.invalidParams("\(verb): malformed params (\(error))")
        }
    }
}
