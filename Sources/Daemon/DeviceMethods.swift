// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceMethods: RPC handlers for the `device.*` method family.
//
// Wire shapes (canonical schema in `docs/ARCHITECTURE.md`):
//
//   device.list({scope: "owned"|"all"})
//        → [{udid, name, state, ownedBySession?, family, deviceType?}]
//   device.boot({udid, sessionId?, cap?})  → {ok: true}
//   device.shutdown({udid})                → {ok: true}
//   device.restoreOwnership({devices: [{udid, sessionId?}]})
//        → {restoredCount, udids}
//
// `device.attach({udid, sessionId, cap, revision?}) → {paneId, scale?, family,
// …}` transfers ownership of an already-Booted udid to
// (sessionId, cap) and creates a sim pane for it in one shot. The
// orphan re-attach path uses it so adoption into a fresh session
// updates the daemon's ownership map; without it `device.list`
// keeps reporting the orphan's dead session as owner and a later
// `detach` close strands the daemon's record.
//
// `device.boot` has optional session attribution: when the caller
// passes `sessionId` + `cap`, the daemon validates the pair through
// `SessionManager` and records the booted sim as owned by that
// session (so it's visible in `device.list({scope:"owned"})` and in
// the status-item badge count). When the caller omits both, the
// boot runs unattributed. Either way the method is `.session`-scoped:
// the connection must already be authenticated, so omitting the pair
// skips ownership bookkeeping without opening an unauthenticated
// boot path. Providing exactly one of the two fields is rejected as
// `invalidParams`. `device.shutdown` doesn't carry credentials at
// all: UDS access is user-scoped, the user can already run
// `xcrun simctl shutdown` directly, and disowning on shutdown is
// just bookkeeping.

import CoreSimulatorBridge
import DaemonProtocol
import Foundation

public enum DeviceMethods {
    // MARK: - Wire shapes

    public struct ListParams: Codable, Sendable {
        public let scope: String

        public init(scope: String) {
            self.scope = scope
        }
    }

    public struct ListEntry: Codable, Sendable, Equatable {
        public let udid: String
        public let name: String
        /// CoreSimulator state name: "Shutdown", "Booting", "Booted",
        /// "ShuttingDown", "Creating", or "Unknown". Strings on the
        /// wire keep client-side decoding readable; the underlying
        /// `CSBSimState` raw value is a daemon-internal detail.
        public let state: String
        /// UUID string of the session that owns this sim, or omitted
        /// when no session owns it. Encoder omits the field when the
        /// value is nil so the wire shape matches the schema.
        public let ownedBySession: String?
        /// Coarse device family (`watch`/`phone`/`pad`/`tv`/`unknown`),
        /// classified from the device type. See `DeviceFamily`.
        public let family: String
        /// Human-readable device type from `SimDeviceType.name`, e.g.
        /// "Apple Watch Ultra 3 (49mm)" or "iPhone 17 Pro". Nil
        /// only if the bridge couldn't read the property; the GUI
        /// falls back to name-only in that case.
        public let deviceType: String?
    }

    public struct BootParams: Codable, Sendable {
        public let udid: String
        /// Optional session attribution. When the caller knows which
        /// tab the boot is happening for (e.g. the GUI's pane-
        /// shutdown Reboot button), passing `sessionId` + `cap` lets
        /// the daemon record the booted sim as owned by that session,
        /// so `device.list({scope: "owned"})` and the status-item
        /// badge count include it.
        ///
        /// Omitting both skips the ownership bookkeeping; the sim
        /// stays unattributed until `device.attach` claims it or a
        /// later in-tab boot transitions it back to Booted (the shim
        /// posts only real transitions, so rerunning `simctl boot`
        /// against an already-Booted sim attributes nothing). The
        /// method itself is `.session`-scoped, so even a
        /// credential-less boot arrives on an authenticated
        /// connection.
        public let sessionId: String?
        public let cap: String?

        public init(udid: String, sessionId: String? = nil, cap: String? = nil) {
            self.udid = udid
            self.sessionId = sessionId
            self.cap = cap
        }
    }

    public struct ShutdownParams: Codable, Sendable {
        public let udid: String

        public init(udid: String) {
            self.udid = udid
        }
    }

    public struct AttachParams: Codable, Sendable {
        public let udid: String
        public let sessionId: String
        public let cap: String
        /// Caller-monotonic ordering for this caller's own attaches; see
        /// `PaneCoordinator.Record.admissionRevision`. Optional: a caller
        /// that sends none (the CLI) has no series to order.
        public let revision: UInt64?

        public init(udid: String, sessionId: String, cap: String, revision: UInt64? = nil) {
            self.udid = udid
            self.sessionId = sessionId
            self.cap = cap
            self.revision = revision
        }
    }

    // MARK: - Handlers

    public static func list(using coordinator: DeviceCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(ListParams.self, from: paramsJSON)
            switch DeviceListScope(rawValue: params.scope) {
            case .owned:
                let infos: [CSBDeviceInfo]
                do {
                    infos = try await coordinator.listOwned()
                } catch let error as DeviceError {
                    throw mapDeviceError(error)
                }
                return try await encodeEntries(infos, coordinator: coordinator)

            case .all:
                let infos: [CSBDeviceInfo]
                do {
                    infos = try await coordinator.listAll()
                } catch let error as DeviceError {
                    throw mapDeviceError(error)
                }
                return try await encodeEntries(infos, coordinator: coordinator)

            case nil:
                throw RPCMethodError.invalidParams(
                    "scope must be one of: "
                    + DeviceListScope.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
        }
    }

    public static func boot(
        coordinator: DeviceCoordinator,
        sessionManager: SessionManager
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(BootParams.self, from: paramsJSON)
            let owningSession: UUID?
            if let sessionIdString = params.sessionId {
                guard let capString = params.cap else {
                    throw RPCMethodError.invalidParams(
                        "cap is required when sessionId is provided"
                    )
                }
                let (sessionId, capability) = try SessionMethods.parseCredentials(
                    sessionIdString: sessionIdString,
                    capString: capString
                )
                do {
                    _ = try await sessionManager.validate(
                        sessionId: sessionId,
                        capability: capability
                    )
                } catch let error as SessionError {
                    throw SessionMethods.mapSessionError(error)
                }
                // A valid payload cap must attribute the boot to the
                // connection's own session, not a victim's stolen one.
                try SessionMethods.requirePayloadMatchesConnection(sessionId)
                owningSession = sessionId
            } else {
                if params.cap != nil {
                    throw RPCMethodError.invalidParams(
                        "sessionId is required when cap is provided"
                    )
                }
                owningSession = nil
            }
            do {
                try await coordinator.boot(udid: params.udid, owningSession: owningSession)
            } catch let error as DeviceError {
                throw mapDeviceError(error)
            }
            return try JSONEncoder().encode(RPCAck(success: true))
        }
    }

    /// `device.attach`: transfer ownership of an already-Booted
    /// udid to (sessionId, cap) and create a sim pane for it. The
    /// orphan re-attach path uses this so the daemon's ownership
    /// map updates atomically with pane creation. `recordOwnership`
    /// overwrites any prior owner; that's the intent here (the
    /// previous session is the dead one we're re-homing from).
    public static func attach(
        coordinator: DeviceCoordinator,
        paneCoordinator: PaneCoordinator,
        sessionManager: SessionManager
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(AttachParams.self, from: paramsJSON)
            let (sessionId, capability) = try SessionMethods.parseCredentials(
                sessionIdString: params.sessionId,
                capString: params.cap
            )
            do {
                _ = try await sessionManager.validate(
                    sessionId: sessionId,
                    capability: capability
                )
            } catch let error as SessionError {
                throw SessionMethods.mapSessionError(error)
            }
            // A stolen payload cap must not attach a device pane to a victim's
            // session; the target must be the connection's own.
            try SessionMethods.requirePayloadMatchesConnection(sessionId)
            // Create the pane first; only record ownership on
            // success. The previous order (record then create) would
            // leave the daemon's ownership map mutated when pane
            // creation failed (e.g. HID/display acquisition for a
            // valid Booted sim): the orphan dir would already be
            // cleaned up on the GUI side, so a later detach/quit
            // could strand a daemon ownership record with no
            // recoverable session dir.
            let result: PaneCreateResult
            // The pane owner is the TARGET session; pin it (and the rollback
            // below) to that session's real incarnation, so neither this create
            // nor its rollback acts on a pane that a newer incarnation of the
            // same UUID has since taken over.
            let ownerIncarnation = await PaneAccessPrincipal.ownerIncarnation(for: sessionId) {
                await sessionManager.incarnation(of: sessionId)
            }
            do {
                result = try await paneCoordinator.createSim(
                    sessionId: sessionId,
                    udid: params.udid,
                    revision: params.revision,
                    ownerIncarnation: ownerIncarnation,
                    requireConcreteIncarnation: true,
                    isOwnerSessionAlive: { [sessionManager] priorOwner in
                        await sessionManager.isAlive(priorOwner)
                    }
                )
            } catch let error as PaneError {
                throw PaneMethods.mapPaneError(error)
            }
            do {
                try await coordinator.recordOwnership(
                    udid: params.udid,
                    sessionId: sessionId
                )
            } catch let error as DeviceError {
                // Roll back the pane so we don't leave a half-baked record (a
                // pane created with stale ownership). Scope the rollback to the
                // creating session's exact incarnation, so a pane a newer
                // incarnation has adopted is left untouched.
                _ = await paneCoordinator.close(
                    paneId: result.paneId,
                    as: .session(sessionId, incarnation: ownerIncarnation),
                    mode: .detach
                )
                throw mapDeviceError(error)
            }
            let response = PaneMethods.CreateResponse(
                paneId: result.paneId.uuidString,
                attachment: result.attachment,
                scale: result.scale,
                family: result.family,
                shortId: result.shortId,
                name: result.name,
                deviceType: result.deviceType,
                pixelWidth: result.pixelWidth,
                pixelHeight: result.pixelHeight,
                capabilities: result.capabilities,
                target: result.target
            )
            return try JSONEncoder().encode(response)
        }
    }

    /// `device.restoreOwnership`: restore deviceterm's owned-sim claims to a
    /// daemon that restarted, preserving live session attribution where there
    /// is any. `.validatedGUI`-scoped, so the scope check has already
    /// refused every caller but a signature-validated GUI peer, and no
    /// capability rides on the wire.
    ///
    /// Every entry is parsed before anything is touched, so a malformed or
    /// duplicated udid rejects the whole batch with nothing mutated. After
    /// that the resemblance to `session.restoreBatch` ends: claims are handled
    /// independently rather than committed all-or-none, so one entry the
    /// daemon can't take doesn't cost the caller the rest.
    ///
    /// A null `sessionId` claims ownership with no attribution and takes no
    /// session check: it is the sim a tab closed with Detach left running,
    /// ours with nothing left to attribute it to, listed under "Unlinked" in
    /// the status item and still offered at quit.
    ///
    /// For a sim the daemon holds no conflicting claim on, a NAMED session it
    /// cannot confirm live is dropped while the ownership is admitted, landing
    /// in that same unattributed state. `isAlive` rather than `contains`,
    /// because the question is whether the attribution can be confirmed.
    /// Refusing instead would leave a running sim nothing claims, which is
    /// exactly what this method exists to prevent.
    public static func restoreOwnership(
        coordinator: DeviceCoordinator,
        sessionManager: SessionManager
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let params: DeviceRestoreOwnershipParams
            do {
                params = try JSONDecoder().decode(
                    DeviceRestoreOwnershipParams.self,
                    from: paramsJSON
                )
            } catch {
                throw RPCMethodError.invalidParams(
                    "malformed device.restoreOwnership params"
                )
            }
            var claims: [String: UUID?] = [:]
            for wire in params.devices {
                guard let udid = UUID(uuidString: wire.udid) else {
                    throw RPCMethodError.invalidParams("udid must be a UUID string")
                }
                var sessionId: UUID?
                if let named = wire.sessionId {
                    guard let parsed = UUID(uuidString: named) else {
                        throw RPCMethodError.invalidParams("sessionId must be a UUID string")
                    }
                    sessionId = parsed
                }
                let normalized = udid.uuidString.lowercased()
                // Membership, not the value: an unattributed claim stores nil,
                // which a plain `== nil` subscript test would read as absent
                // and let a duplicate through.
                guard claims.index(forKey: normalized) == nil else {
                    throw RPCMethodError.invalidParams(
                        "duplicate udid in device.restoreOwnership batch"
                    )
                }
                claims[normalized] = sessionId
            }
            var admitted: [String: UUID?] = [:]
            for (udid, sessionId) in claims {
                guard let sessionId else {
                    admitted[udid] = UUID?.none
                    continue
                }
                // A named session that isn't live is demoted, not refused. The
                // caller is asserting deviceterm owns the sim; whether the
                // attribution still resolves is a separate question, and the
                // answer to it can change under a caller that read it a moment
                // ago. Refusing would leave a running sim nothing claims.
                admitted[udid] = await sessionManager.isAlive(sessionId) ? sessionId : nil
            }
            let result: OwnershipRestoreResult
            do {
                result = try await coordinator.restoreOwnership(admitted)
            } catch let error as DeviceError {
                throw mapDeviceEnumerationError(error, method: .deviceRestoreOwnership)
            }
            // The check above is a preflight. Crossing to the coordinator is a
            // suspension, and a session that closes inside it would leave a sim
            // attributed to one that is gone. Re-check what this call wrote and
            // demote those entries the same way.
            //
            // Re-checking liveness is the whole fence, with no incarnation to
            // compare: a close tombstones the id, so a session id is dead for
            // good and cannot return under a new incarnation. A session alive
            // on this side of the commit was therefore alive on the other side
            // of it too.
            //
            // An entry written unattributed names no session and so has
            // nothing to outlive it.
            var demote: [String: UUID] = [:]
            for (udid, sessionId) in result.written {
                guard let sessionId else { continue }
                if await !sessionManager.isAlive(sessionId) { demote[udid] = sessionId }
            }
            if !demote.isEmpty {
                await coordinator.demoteOwnership(demote)
            }
            // Demoted sims stay restored: ownership is what the caller asserted
            // and what it gets back, attributed or not.
            return try JSONEncoder().encode(
                DeviceRestoreOwnershipResult(
                    restoredCount: result.attributed.count,
                    udids: result.attributed.sorted()
                )
            )
        }
    }

    /// Shut a device down *and* drive any attached panes into
    /// `.shutdown` so the GUI shows the overlay instead of a frozen
    /// last frame. Every shutdown must reach `markPanesShutdown`;
    /// without that half, a sim shut down from the menu leaves its pane
    /// frozen with no Reboot/Close affordance.
    ///
    /// Four surfaces, split by who caused the shutdown. The two that
    /// *issue* one come through here, pairing the device call with the
    /// pane transition: the `device.shutdown` RPC and the status-item
    /// menu. The two that merely *observe* one already done call
    /// `markPanesShutdown` directly, having no device call to pair with:
    /// the shim's `shutdown` event (`ShimMethods`) and the CoreSimulator
    /// notifier (`DeviceCoordinator.noteExternalShutdown`). The notifier is
    /// the only surface that sees a sim killed by something outside
    /// deviceterm entirely.
    public static func shutdownConverged(
        udid: String,
        coordinator: DeviceCoordinator,
        paneCoordinator: PaneCoordinator
    ) async throws {
        do {
            try await coordinator.shutdown(udid: udid)
        } catch {
            // shutdown can throw when the sim is already stopped: a
            // stale menu item, or a race with external simctl /
            // Simulator.app. If the device really is no longer booted,
            // still drive its panes into .shutdown (else they stay
            // frozen with no Reboot/Close overlay); only skip when the
            // sim is genuinely still up, so a real failure doesn't show
            // a false "shut down". Rethrow either way to preserve the
            // RPC error.
            if await !coordinator.isBooted(udid: udid) {
                await paneCoordinator.markPanesShutdown(forUDID: udid)
            }
            throw error
        }
        await paneCoordinator.markPanesShutdown(forUDID: udid)
    }

    public static func shutdown(
        using coordinator: DeviceCoordinator,
        paneCoordinator: PaneCoordinator
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(ShutdownParams.self, from: paramsJSON)
            do {
                try await shutdownConverged(
                    udid: params.udid,
                    coordinator: coordinator,
                    paneCoordinator: paneCoordinator
                )
            } catch let error as DeviceError {
                throw mapDeviceError(error)
            }
            return try JSONEncoder().encode(RPCAck(success: true))
        }
    }

    // MARK: - Helpers

    /// Encode the array of devices into the bare-array result shape
    /// per `docs/ARCHITECTURE.md` ("`device.list` result is `[...]`, not
    /// `{"devices": [...]}`"). Same convention as `tabs.list`.
    private static func encodeEntries(
        _ infos: [CSBDeviceInfo],
        coordinator: DeviceCoordinator
    ) async throws -> Data {
        var entries: [ListEntry] = []
        entries.reserveCapacity(infos.count)
        for info in infos {
            let owner = await coordinator.ownerSession(forUDID: info.udid)
            entries.append(
                ListEntry(
                udid: info.udid,
                name: info.name,
                state: stateName(info.state),
                ownedBySession: owner?.uuidString,
                family: DeviceFamilyClassifier.classify(info.deviceTypeIdentifier).rawValue,
                deviceType: info.deviceTypeName.isEmpty ? nil : info.deviceTypeName
            )
                )
        }
        return try JSONEncoder().encode(entries)
    }

    /// String form of `CSBSimState`. Unknown raw values map to
    /// "Unknown". The bridge already normalizes drift before we get
    /// here, so this is mostly a stable wire vocabulary for clients.
    static func stateName(_ state: CSBSimState) -> String {
        switch state {
        case .creating:
            return "Creating"

        case .shutdown:
            return "Shutdown"

        case .booting:
            return "Booting"

        case .booted:
            return "Booted"

        case .shuttingDown:
            return "ShuttingDown"

        case .unknown:
            return "Unknown"

        @unknown default:
            return "Unknown"
        }
    }

    /// Translate `DeviceError` to an RPC-shaped error for the
    /// dispatcher. `notFound` and `malformedUDID` are "bad input
    /// from the caller" → `invalidParams`. Boot, shutdown, and enumeration
    /// failures or timeouts map to `serverError`.
    static func mapDeviceError(_ error: DeviceError) -> RPCMethodError {
        switch error {
        case let .notFound(udid):
            return RPCMethodError.invalidParams("unknown UDID: \(udid)")

        case .malformedUDID:
            return RPCMethodError.invalidParams("udid must be a non-empty string")

        case let .bootFailed(_, message):
            return RPCMethodError(
                code: RPCErrorCode.serverError,
                message: "device.boot: \(message)"
            )

        case let .shutdownFailed(_, message):
            return RPCMethodError(
                code: RPCErrorCode.serverError,
                message: "device.shutdown: \(message)"
            )

        case .listFailed, .listTimedOut:
            return mapDeviceEnumerationError(error, method: .deviceList)
        }
    }

    static func mapDeviceEnumerationError(
        _ error: DeviceError,
        method: RPCMethod
    ) -> RPCMethodError {
        let detail: String
        switch error {
        case let .listFailed(message):
            detail = message

        case .listTimedOut:
            detail = """
            CoreSimulator device enumeration did not finish within 3 seconds; \
            retry, or restart DeviceTerm if it persists
            """

        case .notFound, .malformedUDID, .bootFailed, .shutdownFailed:
            return mapDeviceError(error)
        }
        return RPCMethodError(
            code: RPCErrorCode.serverError,
            message: "\(method.rawValue): \(detail)"
        )
    }
}
