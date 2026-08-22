// SPDX-License-Identifier: GPL-3.0-or-later
//
// PhysicalDeviceMethods: RPC handlers for the physical-device surface:
// `physicalDevice.list` (the GUI picker), `physicalDevice.attach`
// (mount a device pane), and `devices.list` (the aggregate sim+device
// roster).

import DaemonProtocol
import Foundation

public enum PhysicalDeviceMethods {
    /// Params for `physicalDevice.attach`. `deviceId` is the device to mount.
    /// `sessionId` names the tab session to attribute the pane to. It is
    /// honored **only** for the trusted GUI/XPC peer (which owns every tab and
    /// has one shared control connection, so connection-auth alone can't pick the
    /// target tab) and only when it names a real session. The CLI/shim (UDS)
    /// never sends it and a UDS-supplied value is ignored: those callers use
    /// the connection-authenticated session. No `cap`: `sessionId` is
    /// attribution, not a credential.
    public struct AttachParams: Codable, Sendable {
        public let deviceId: String
        public let sessionId: String?
        /// See `DeviceMethods.AttachParams.revision`.
        public let revision: UInt64?

        public init(deviceId: String, sessionId: String? = nil, revision: UInt64? = nil) {
            self.deviceId = deviceId
            self.sessionId = sessionId
            self.revision = revision
        }
    }

    /// `physicalDevice.list`: connected physical devices for the GUI
    /// picker. Daemon-wide: device *availability* leaks nothing tab-private.
    /// Empty when no device is plugged in / trusted.
    ///
    /// Deliberately cheap: a plain `devicectl list devices` enumeration,
    /// no per-device tunnel probe. Mirror capability is judged at
    /// **attach**: every listed device is selectable, and mounting an
    /// iOS-too-old device surfaces a clear "needs a newer iOS" error.
    /// A future picker that
    /// pre-greys unavailable rows would probe each device *asynchronously*
    /// after the list renders, not synchronously inside this RPC, which
    /// must stay fast even with a slow/filtered device connected.
    public static func list(
        coordinator: PhysicalDeviceCoordinator
    ) -> MethodRegistry.Handler {
        { _ in
            // Log enumeration boundaries so discovery activity can be
            // distinguished from attach activity.
            DiagnosticLog.attach.info("physicalDevice.list: enumerating")
            let devices = await coordinator.enumerate()
            DiagnosticLog.attach.info(
                "physicalDevice.list: \(devices.count, privacy: .public) device(s)"
            )
            let entries = devices.map {
                PhysicalDeviceListEntry(
                    deviceId: $0.deviceId,
                    name: $0.name,
                    model: $0.model,
                    osVersion: $0.osVersion
                )
            }
            return try JSONEncoder().encode(entries)
        }
    }

    /// `physicalDevice.attach`: mount a physical device as a pane.
    /// Resolves the deviceId to a live backend (tunnel + ports +
    /// frame/HID), resolves the attribution session (GUI-named or
    /// connection-auth, see `resolveAttributionSession`), and creates the
    /// pane through the shared `createPane` core. With no device connected
    /// this returns a clean error, never a crash.
    public static func attach(
        physicalDeviceCoordinator: PhysicalDeviceCoordinator,
        paneCoordinator: PaneCoordinator,
        sessionManager: SessionManager
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(AttachParams.self, from: paramsJSON)
            guard let sessionId = await resolveAttributionSession(
                params: params,
                sessionManager: sessionManager
            ) else {
                throw RPCMethodError.invalidParams(
                    "physicalDevice.attach requires an authenticated session"
                )
            }
            // One ephemeral id per attach, threaded through every phase line,
            // so backend resolution and pane creation can be correlated without
            // logging the stable device UDID. A fresh UUID identifies the
            // attempt, not the hardware.
            let attachId = UUID().uuidString
            // Resolving a backend brings up the tunnel and bootstraps services:
            // the slowest and least reliable work in an attach, and it has to
            // happen out here, because doing it inside `createPane` would block
            // the coordinator's actor for its whole duration.
            //
            // That ordering means resolution runs before anything can tell
            // whether a backend is needed at all. A re-attach that `createPane`
            // would answer from the existing record needs none, and failing it
            // on a hiccup in machinery it never used would turn a healthy
            // mirror into a failed pane. The GUI re-attaches every device pane
            // on reconnect, so that combination is not hypothetical.
            //
            // So a failure here is carried rather than thrown. `createPane`
            // invokes `acquire` only on a genuine fresh create, after its
            // dedup and adopt branches, which makes it the one place that
            // knows whether the backend was required; the failure surfaces
            // there or not at all. Deciding it here instead would mean a
            // check-then-create race this doesn't have.
            let backend: RealDeviceBackend?
            let resolutionFailure: PhysicalDeviceError?
            do {
                DiagnosticLog.attach.info(
                    "attach \(attachId, privacy: .public): resolveBackend entering"
                )
                backend = try await physicalDeviceCoordinator.resolveBackend(deviceId: params.deviceId)
                resolutionFailure = nil
                DiagnosticLog.attach.info(
                    "attach \(attachId, privacy: .public): resolveBackend ok"
                )
            } catch let error as PhysicalDeviceError {
                DiagnosticLog.attach.error(
                    """
                    attach \(attachId, privacy: .public): resolveBackend failed, \
                    deferred to acquire: \(error.diagnosticKind, privacy: .public)
                    """
                )
                backend = nil
                resolutionFailure = error
            }
            // `createPane` invokes `acquire` only on a genuine fresh create;
            // its idempotent-re-attach and orphan-adopt branches return an
            // existing pane *without* it. Track whether our freshly-built
            // backend was actually consumed, so when it wasn't we release both
            // it and the keepalive retain `resolveBackend` took. Otherwise a
            // repeat attach of an already-mirrored device leaks the tunnel.
            var backendConsumed = false
            let result: PaneCreateResult
            let ownerIncarnation = await PaneAccessPrincipal.ownerIncarnation(for: sessionId) {
                await sessionManager.incarnation(of: sessionId)
            }
            DiagnosticLog.attach.info(
                "attach \(attachId, privacy: .public): createPane entering"
            )
            do {
                result = try await paneCoordinator.createPane(
                    target: .device(deviceId: params.deviceId),
                    sessionId: sessionId,
                    revision: params.revision,
                    ownerIncarnation: ownerIncarnation,
                    requireConcreteIncarnation: true,
                    // Match the sim attach paths: if the device is already
                    // mirrored by a session whose GUI has since died, adopt the
                    // orphaned pane instead of rejecting the cross-session
                    // attach, so a relaunched GUI can reclaim a device dropped
                    // by a crashed one without waiting for the daemon to idle-
                    // exit.
                    isOwnerSessionAlive: { [sessionManager] priorOwner in
                        await sessionManager.isAlive(priorOwner)
                    },
                    acquire: {
                        // Reached only on a fresh create, so this is where a
                        // deferred resolution failure becomes the answer: the
                        // record that would have made it irrelevant isn't
                        // there.
                        guard let backend else {
                            throw resolutionFailure ?? .notConnected(deviceId: params.deviceId)
                        }
                        backendConsumed = true
                        return PaneCoordinator.AcquiredBackend(
                            backend: backend,
                            family: DeviceFamily.unknown.rawValue,
                            deviceType: nil
                        )
                    }
                )
            } catch let error as PhysicalDeviceError {
                DiagnosticLog.attach.error(
                    """
                    attach \(attachId, privacy: .public): createPane needed a \
                    backend: \(error.diagnosticKind, privacy: .public)
                    """
                )
                // Nothing was resolved, so there is nothing to release.
                throw mapPhysicalDeviceError(error)
            } catch let error as PaneError {
                DiagnosticLog.attach.error(
                    """
                    attach \(attachId, privacy: .public): createPane failed: \
                    \(error.diagnosticKind, privacy: .public)
                    """
                )
                // No pane will own the backend; release it + the keepalive
                // retain or we'd hold the tunnel up for a mirror that never
                // mounted. Both are conditional on having resolved one:
                // `resolveBackend` balances its own retain on failure, so a
                // deferred failure leaves this attach holding none, and
                // releasing anyway would decrement a retain belonging to
                // whichever live pane is already mirroring the device. That is
                // reachable: the create can refuse because another live
                // session holds it, which is exactly when someone else's
                // tunnel is at stake.
                if let backend {
                    backend.shutdownBackend()
                    await physicalDeviceCoordinator.releaseKeepalive(deviceId: params.deviceId)
                }
                throw PaneMethods.mapPaneError(error)
            }
            DiagnosticLog.attach.info(
                """
                attach \(attachId, privacy: .public): createPane ok \
                fresh=\(backendConsumed, privacy: .public)
                """
            )
            if !backendConsumed, let backend {
                // Dedup / orphan-adopt returned an existing pane; our backend
                // and its keepalive retain are unused. Release both so a
                // repeated attach doesn't accumulate retains and leave the
                // device tunnel held after the only pane closes. Nil means
                // resolution failed and the dedup made that not matter, so
                // there is no retain to release.
                backend.shutdownBackend()
                await physicalDeviceCoordinator.releaseKeepalive(deviceId: params.deviceId)
            }
            return try JSONEncoder().encode(
                PaneMethods.CreateResponse(
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
            )
        }
    }

    /// The session to attribute the pane to. The **trusted GUI peer** may name
    /// the target tab's session explicitly (it owns every tab, over one shared
    /// connection, so connection-auth alone picks the wrong tab), honored only
    /// when that session actually exists. Every other caller (an untrusted XPC
    /// peer, the CLI/shim over UDS, or any caller omitting `sessionId`) falls
    /// back to the connection-authenticated session, so the CLI/shim path is
    /// unchanged and no untrusted peer can name an arbitrary session.
    ///
    /// `isTrustedGUIPeer` is injectable for tests; in production it reads the
    /// resolved GUI verdict stamped by `XPCConnection` via the check below.
    static func resolveAttributionSession(
        params: AttachParams,
        sessionManager: SessionManager,
        isTrustedGUIPeer: (DispatchPeerContext) -> Bool = Self.isTrustedGUIPeer
    ) async -> UUID? {
        if let context = DispatchPeerContext.current,
            isTrustedGUIPeer(context),
            let explicit = params.sessionId.flatMap(UUID.init(uuidString:)),
            await sessionManager.contains(explicit) {
            return explicit
        }
        return SessionDispatchContext.originatingSessionId.flatMap(UUID.init(uuidString:))
    }

    /// Whether the caller is the signature-validated host GUI, the only peer
    /// allowed to name another session. Transport alone is insufficient (any
    /// process can open the XPC service): the peer must have passed the
    /// self-mirror signature check the automation-mint gate uses. Reads the
    /// resolved GUI verdict stamped by `XPCConnection`
    /// (`DispatchPeerContext.validatedGUIPeer`); never a fresh signature walk.
    /// UDS peers carry no audit token and are rejected regardless of the
    /// verdict (the `transport == .xpc` conjunct).
    static func isTrustedGUIPeer(_ context: DispatchPeerContext) -> Bool {
        context.transport == .xpc && context.validatedGUIPeer
    }

    static func mapPhysicalDeviceError(_ error: PhysicalDeviceError) -> RPCMethodError {
        switch error {
        case let .notConnected(deviceId):
            return RPCMethodError.invalidParams(
                "no connected device matches \(deviceId) (plug in, unlock, and trust it)"
            )

        case let .tunnelBringUpFailed(deviceId):
            return RPCMethodError(
                code: RPCErrorCode.serverError,
                message: "couldn't bring up the tunnel to device \(deviceId) (is it unlocked and trusted?)"
            )

        case let .serviceCatalogUnavailable(deviceId):
            return RPCMethodError(
                code: RPCErrorCode.serverError,
                message: "device \(deviceId) is reachable but its service catalog couldn't be read (is it unlocked?)"
            )

        case .tooOldToMirror:
            // Catalog read fine but no displayservice. The device's iOS is
            // too old to mirror. Surface the picker gate's wording so the
            // attach error reads the same as a future pre-greyed row.
            return RPCMethodError.invalidParams(DeviceAvailability.unsupportedReason)

        case let .missingService(deviceId, service):
            return RPCMethodError(
                code: RPCErrorCode.serverError,
                message: "device \(deviceId) doesn't vend the required service \(service)"
            )
        }
    }

    /// `devices.list`: the aggregate live roster, booted (owned) sims +
    /// connected physical devices, each annotated with the owning
    /// session of a live pane that mirrors it. The annotation obeys the
    /// `tabs.list` private-tab opacity rule: a device attached only in
    /// a private session the caller can't see reads as unattached.
    public static func devicesList(
        deviceCoordinator: DeviceCoordinator,
        physicalDeviceCoordinator: PhysicalDeviceCoordinator,
        paneCoordinator: PaneCoordinator,
        sessionManager: SessionManager
    ) -> MethodRegistry.Handler {
        { _ in
            let callerId = SessionDispatchContext.originatingSessionId
                .flatMap(UUID.init(uuidString:))
            let visible = Set(await sessionManager.sessions(visibleTo: callerId).map(\.id))
            let ownedSims: [OwnedSim]
            do {
                ownedSims = try await deviceCoordinator.listOwnedBooted()
            } catch let error as DeviceError {
                throw DeviceMethods.mapDeviceEnumerationError(error, method: .devicesList)
            }
            let sims = ownedSims.map {
                DeviceRoster.SimEntry(
                    udid: $0.udid,
                    name: $0.name,
                    state: "Booted"
                )
            }
            let physical = await physicalDeviceCoordinator.enumerate()
            let ownerships = await paneCoordinator.liveOwnerships()
            let roster = DeviceRoster.build(
                sims: sims,
                physical: physical,
                ownerships: ownerships,
                visibleSessionIds: visible
            )
            return try JSONEncoder().encode(roster)
        }
    }
}
