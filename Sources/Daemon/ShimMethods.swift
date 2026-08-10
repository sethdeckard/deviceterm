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
//   4. Posts a `shim.event` request to the daemon socket, tagged
//      with the session's `(DEVICETERM_SESSION, DEVICETERM_SESSION_CAP)`
//      env vars so the daemon can attribute the sim to that tab.
//
// The daemon validates `(sessionId, cap)` against `SessionManager`
// before mutating ownership; cap mismatch is a hard reject per
// the trust boundary in AGENTS.md. After validation, `booted`
// events record ownership; `shutdown` events release it.
//
// Wire shape per docs/ARCHITECTURE.md:
//
//   shim.event({event: "booted"|"shutdown",
//               sessionId, cap, udid,
//               deviceName?, runtime?, invokedAs?, argv?})  → {ok}
//
// The shim treats the response as fire-and-forget: it sends the
// request and closes the socket without reading. The daemon's
// SO_NOSIGPIPE handling makes the resulting write-to-closed-peer
// a benign close, not a SIGPIPE.

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

        public init(
            event: String,
            sessionId: String,
            cap: String,
            udid: String? = nil,
            deviceName: String? = nil,
            runtime: String? = nil,
            invokedAs: String? = nil,
            argv: [String]? = nil,
            deviceIdentifier: String? = nil
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
    /// - `booted`/`shutdown` mutate `DeviceCoordinator` ownership for the
    ///   carried sim UDID (and, for shutdown, drive every attached sim pane
    ///   for that UDID into `.shutdown` so the GUI's pane.subscribe stream
    ///   surfaces it; otherwise IOSurface frames just stop and the pane
    ///   freezes on the last rendered frame with no signal).
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
                    try await deviceCoordinator.recordOwnership(
                        udid: udid,
                        sessionId: sessionId
                    )
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
