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
//
// `device.attach({udid, sessionId, cap}) → {paneId, scale?, family,
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
// the status-item "📱 N" count). When the caller omits both, the
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
        /// "📱 N" count include it.
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

        public init(udid: String, sessionId: String, cap: String) {
            self.udid = udid
            self.sessionId = sessionId
            self.cap = cap
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

    /// Shut a device down *and* drive any attached panes into
    /// `.shutdown` so the GUI shows the overlay instead of a frozen
    /// last frame. Every shutdown surface (the shim `shutdown`
    /// event, the `device.shutdown` RPC, and the status-item menu)
    /// must converge on this transition; without the
    /// `markPanesShutdown` half, a sim shut down from the menu
    /// leaves its pane frozen with no Reboot/Close affordance.
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
    /// from the caller" → `invalidParams`. `bootFailed` /
    /// `shutdownFailed` / `listFailed` are "we tried but
    /// CoreSimulator said no" → `serverError`.
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

        case let .listFailed(message):
            return RPCMethodError(
                code: RPCErrorCode.serverError,
                message: "device.list: \(message)"
            )
        }
    }
}
