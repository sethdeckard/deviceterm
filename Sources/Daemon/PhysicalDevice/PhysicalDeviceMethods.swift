// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// RPC handlers for the physical-device surface:
/// `physicalDevice.list` (the GUI picker), `physicalDevice.attach`
/// (mount a device pane), and `devices.list` (the aggregate sim+device
/// roster).
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
    /// picker. Daemon-wide: device *availability* reveals no protected-tab
    /// state.
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
            // the slowest and least reliable work in an attach. It runs inside
            // the `acquire` closure below, which `createPane` calls off its own
            // actor and only on a genuine fresh create, after its dedup and
            // adopt branches.
            //
            // Both halves of that matter. Off-actor is why the slowest work in
            // an attach cannot park the coordinator. Fresh-create-only is why a
            // re-attach that `createPane` answers from the existing record
            // never resolves at all: failing one on a hiccup in machinery it
            // never used would turn a healthy mirror into a failed pane, and
            // the GUI re-attaches every device pane on reconnect, so that
            // combination is not hypothetical. Resolving out here and deciding
            // whether it was needed afterwards would also mean a
            // check-then-create race this doesn't have.
            //
            // Nothing holds the resolved backend out here. Whatever `acquire`
            // hands over, `createPane` owns, including disposing it and running
            // the acquisition's `releaseSideResources` when it goes unused.

            // Diagnostic only: whether this attach turned out to be a fresh
            // create (it resolved a backend and the pane took it) or was
            // answered from an existing record. It gates no cleanup.
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
                        // Reached only on a fresh create, and only after the
                        // display-start admission was taken, so a refusal never
                        // retains a tunnel. A resolution failure becomes the
                        // answer here: the record that would have made it
                        // irrelevant isn't there.
                        DiagnosticLog.attach.info(
                            "attach \(attachId, privacy: .public): resolveBackend entering"
                        )
                        let resolved = try await physicalDeviceCoordinator.resolveBackend(
                            deviceId: params.deviceId
                        )
                        DiagnosticLog.attach.info(
                            "attach \(attachId, privacy: .public): resolveBackend ok"
                        )
                        backendConsumed = true
                        return PaneCoordinator.AcquiredBackend(
                            backend: resolved,
                            family: DeviceFamily.unknown.rawValue,
                            deviceType: nil,
                            releaseSideResources: { [physicalDeviceCoordinator] in
                                // Balances the retain `resolveBackend` took.
                                // Run after the backend is down, so it cannot
                                // pull the tunnel out from under a teardown or
                                // a start still in flight.
                                await physicalDeviceCoordinator.releaseKeepalive(
                                    deviceId: params.deviceId
                                )
                            }
                        )
                    },
                    onUnused: {
                        // Acquiring suspends, so a concurrent attach can claim
                        // the target after this one built its backend. The
                        // create still disposes it; this only corrects the
                        // diagnostic below, which would otherwise report a
                        // fresh attach for one that ended up deduped.
                        backendConsumed = false
                    },
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
                // Nothing to release here, whichever error came back. Either
                // `acquire` never ran, so this attach holds no retain
                // (`resolveBackend` balances its own on failure), or it did and
                // the create owns what it built: disposal tears the backend
                // down and `releaseSideResources` balances the keepalive after
                // that teardown finishes. Releasing here as well would
                // double-free the retain, and the retain it decremented could
                // belong to whichever live pane is already mirroring the
                // device. That is reachable: the create can refuse *because*
                // another live session holds it, which is exactly when someone
                // else's tunnel is at stake.
                throw PaneMethods.mapPaneError(error)
            }
            DiagnosticLog.attach.info(
                """
                attach \(attachId, privacy: .public): createPane ok \
                fresh=\(backendConsumed, privacy: .public)
                """
            )
            // Nothing to release here. When a dedup or orphan-adopt returns an
            // existing pane, the create disposes the backend it acquired under
            // its own display-start admission and runs the keepalive release
            // through `releaseSideResources`. Releasing again would decrement a
            // retain that now belongs to whichever pane is mirroring the
            // device, and could race that teardown.
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
            // too old to mirror. Reuse the picker gate's wording
            // (`DeviceAvailability.unsupportedReason`) so an attach refusal
            // and the picker give the user the same reason.
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
    /// `tabs.list` protected-tab opacity rule: a device attached only in
    /// a protected session the caller can't see reads as unattached.
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
            // The caller's own incarnation, so a restored session cannot read a
            // previous incarnation's device as attached to it. Only the caller
            // is pinned: other members are matched by id, since the caller has
            // no way to know their incarnations and protection already governs
            // whether it may see them at all.
            //
            // The pin is the DISPATCH-CAPTURED incarnation, not a fresh
            // manager read: the awaits above mean a request admitted under
            // incarnation G can resume after its session was reaped and
            // restored, and a manager read would pin it to G+1's roster
            // authority instead of refusing the stale view.
            var callerIncarnations: [UUID: UInt64] = [:]
            if let callerId,
                let incarnation = DispatchPeerContext.current?.sessionIncarnation {
                callerIncarnations[callerId] = incarnation
            }
            let roster = DeviceRoster.build(
                sims: sims,
                physical: physical,
                ownerships: ownerships,
                visibleSessionIds: visible,
                callerIncarnations: callerIncarnations
            )
            return try JSONEncoder().encode(roster)
        }
    }
}
