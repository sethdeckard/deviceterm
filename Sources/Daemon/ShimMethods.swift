// SPDX-License-Identifier: GPL-3.0-or-later
//
// ShimMethods: RPC handler for shim-originated provenance events.
//
// `deviceterm-shim` runs in each tab's shell as a stand-in for `xcrun`
// and `simctl`. When the user types `xcrun simctl boot <udid>` (or
// equivalent), the shim:
//
//   1. Resolves the real binary and `exec`s it with inherited stdio.
//   2. Snapshots `simctl list devices` before and after.
//   3. Diffs the snapshots to identify the device whose state
//      actually flipped (uniquely resolving even bare names that
//      collide across runtimes).
//   4. Queues a boot claim through the terminal-local GUI relay. If that relay
//      cannot accept it, posts the same attempt through authenticated
//      `shim.event` as a fallback.
//
// The daemon validates `(sessionId, cap)` against `SessionManager`
// before accepting a fallback; cap mismatch is a hard reject per the trust
// boundary in AGENTS.md. A boot claim becomes ownership only after
// CoreSimulator reports Booted. Shutdown events release ownership.
//
// Wire shape per docs/ARCHITECTURE.md:
//
//   shim.event({event: "booted"|"shutdown",
//               sessionId, cap, udid,
//               deviceName?, runtime?, invokedAs?, argv?, claim?})  → {ok}

import DaemonProtocol
import Foundation

public enum ShimMethods {
    public struct EventParams: Codable, Sendable {
        public let event: String
        public let sessionId: String
        public let cap: String
        /// CoreSimulator UDID for `booted`/`shutdown` events. Absent for
        /// `deviceAttach`: a physical device has no sim UDID; it carries
        /// `deviceIdentifier` instead.
        public let udid: String?
        /// Diagnostic only: the daemon logs but doesn't mutate state
        /// based on these. Optional so the shim can drop them on a
        /// degraded `simctl list` (we'd rather get the event with
        /// less context than no event).
        public let deviceName: String?
        public let runtime: String?
        public let invokedAs: String?
        public let argv: [String]?
        /// The `devicectl --device <id>` spec (name | UDID | ECID) for a
        /// `deviceAttach` event. The daemon resolves it to a connected
        /// device. Absent for sim transitions.
        public let deviceIdentifier: String?
        /// Stable causal attempt carried when a simulator boot could not be
        /// queued through the terminal-local GUI relay.
        public let claim: BootClaimEvidence?

        public init(
            event: String,
            sessionId: String,
            cap: String,
            udid: String? = nil,
            deviceName: String? = nil,
            runtime: String? = nil,
            invokedAs: String? = nil,
            argv: [String]? = nil,
            deviceIdentifier: String? = nil,
            claim: BootClaimEvidence? = nil
        ) {
            self.event = event
            self.sessionId = sessionId
            self.cap = cap
            self.udid = udid
            self.deviceName = deviceName
            self.runtime = runtime
            self.invokedAs = invokedAs
            self.argv = argv
            self.deviceIdentifier = deviceIdentifier
            self.claim = claim
        }
    }

    public struct EventResponse: Codable, Sendable, Equatable {
        private enum CodingKeys: String, CodingKey {
            case success = "ok"
        }
        public let success: Bool
    }

    /// `shim.event`: provenance handler. Validates session creds,
    /// then routes the observed intent:
    /// - `booted` registers a causal claim whose ownership waits for an
    ///   observed CoreSimulator Booted state. `shutdown` releases ownership
    ///   and drives every attached sim pane for that UDID into `.shutdown` so
    ///   the GUI's pane.subscribe stream surfaces it; otherwise IOSurface
    ///   frames just stop and the pane freezes on the last rendered frame with
    ///   no signal.
    /// - `deviceAttach` is a physical-device contextual auto-attach: resolve
    ///   the `devicectl --device <id>` spec to a connected device and publish
    ///   the same `pane.attach` back-channel command the GUI picker and
    ///   `deviceterm device attach` use, attributed to the calling session. The
    ///   GUI's attach path moves an already-mirrored device to the calling
    ///   tab (one-mirror-latest-wins). Best-effort: an unresolvable spec or an
    ///   absent GUI leaves the user's devicectl command unaffected and the
    ///   event still acks.
    ///
    /// `resolveDeviceId` is injectable for hermetic tests; in production it
    /// resolves against the connected-device enumeration.
    public static func event(
        sessionManager: SessionManager,
        deviceCoordinator: DeviceCoordinator,
        paneCoordinator: PaneCoordinator,
        physicalDeviceCoordinator: PhysicalDeviceCoordinator,
        appCommandCoordinator: AppCommandCoordinator,
        resolveDeviceId: (@Sendable (String) async -> String?)? = nil
    ) -> MethodRegistry.Handler {
        let resolve: @Sendable (String) async -> String? =
            resolveDeviceId ?? { spec in
                await physicalDeviceCoordinator.resolveDeviceId(forSpec: spec)
            }
        return { paramsJSON in
            let params = try JSONDecoder().decode(EventParams.self, from: paramsJSON)
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
            // The shim reports on behalf of its own tab: a valid payload cap
            // must name the connection's authenticated session, so a stolen cap
            // can't forge boot/attach attribution for a victim's session.
            try SessionMethods.requirePayloadMatchesConnection(sessionId)

            switch ShimEventType(rawValue: params.event) {
            case .booted:
                let udid = try requireUDID(params, event: .booted)
                do {
                    if let claim = params.claim {
                        guard claim.source == .shim, claim.disposition == .attach,
                            claim.observedState == .booting || claim.observedState == .booted,
                            claim.udid.caseInsensitiveCompare(udid) == .orderedSame else {
                            throw RPCMethodError.invalidParams(
                                "boot claim does not match shim event"
                            )
                        }
                        // The claim session's incarnation, so a restored
                        // session's fresh boot is not dispositioned by its
                        // closed predecessor's tombstone. `ownerIncarnation`
                        // takes the dispatch capture only when the caller IS
                        // the claim session (the shim's ordinary shape) and
                        // resolves otherwise.
                        _ = try await deviceCoordinator.reconcileBootClaim(
                            claim,
                            sessionId: sessionId,
                            currentIncarnation: PaneAccessPrincipal.ownerIncarnation(
                                for: sessionId
                            ) {
                                await sessionManager.incarnation(of: sessionId)
                            }
                        )
                    } else {
                        // MIGRATION: Claimless events remain valid for test
                        // fixtures and mixed-version bundle replacement.
                        try await deviceCoordinator.recordOwnership(
                            udid: udid,
                            sessionId: sessionId
                        )
                    }
                } catch let error as DeviceError {
                    throw DeviceMethods.mapDeviceError(error)
                }

            case .shutdown:
                let udid = try requireUDID(params, event: .shutdown)
                await deviceCoordinator.releaseOwnership(udid: udid)
                await paneCoordinator.markPanesShutdown(forUDID: udid)

            case .deviceAttach:
                try await handleDeviceAttach(
                    params: params,
                    sessionId: sessionId,
                    resolve: resolve,
                    appCommandCoordinator: appCommandCoordinator
                )

            case nil:
                throw RPCMethodError.invalidParams(
                    "event must be one of: "
                    + ShimEventType.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            return try JSONEncoder().encode(EventResponse(success: true))
        }
    }

    /// The `udid` field is required for sim transitions but absent for
    /// `deviceAttach`. Pull it out with a clear error rather than letting a
    /// nil reach `recordOwnership`.
    private static func requireUDID(
        _ params: EventParams,
        event: ShimEventType
    ) throws -> String {
        guard let udid = params.udid else {
            throw RPCMethodError.invalidParams("\(event.rawValue) event requires a udid")
        }
        return udid
    }

    /// Resolve the `devicectl --device` spec to a connected device and, if
    /// resolvable, publish the `pane.attach` back-channel command so the GUI
    /// mounts the device pane under the calling session. Unresolvable spec →
    /// no-op (the host has no/ambiguous matching device). The publish outcome
    /// is intentionally ignored: a missing GUI must not fail the shim event.
    private static func handleDeviceAttach(
        params: EventParams,
        sessionId: UUID,
        resolve: @Sendable (String) async -> String?,
        appCommandCoordinator: AppCommandCoordinator
    ) async throws {
        guard let spec = params.deviceIdentifier, !spec.isEmpty else {
            throw RPCMethodError.invalidParams(
                "deviceAttach event requires a deviceIdentifier"
            )
        }
        guard let deviceId = await resolve(spec) else { return }
        // Contextual auto-attach relinks latest-wins: a deploy/run from
        // this tab moves the mirror here if it's open in another tab.
        let attachParams = try JSONEncoder().encode(
            AppCommandParams.PaneAttach(
                target: .device(deviceId: deviceId),
                relinkExisting: true
            )
        )
        _ = await appCommandCoordinator.publishAndAwait(
            kind: .paneAttach,
            originatingSessionId: sessionId.uuidString,
            params: attachParams
        )
    }
}
