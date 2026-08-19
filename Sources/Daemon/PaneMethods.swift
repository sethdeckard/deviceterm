// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneMethods. RPC handlers for the `pane.*` method family.
//
// Wire shapes (canonical schema in `docs/ARCHITECTURE.md`):
//
//   pane.create({sessionId, cap, kind: "sim", udid, revision?})
//                                              → {paneId, attachment,
//                                                 scale?, family?, ...}
//   pane.closeById({paneId, mode?, expectedAttachment?})
//                                              → {ok: true}
//     mode: "detach" (default) | "shutdown"
//   pane.subscribe({paneId})                   → initial ack + stream of
//                                                 state.changed / surface.changed
//
// `pane.create` validates session creds; subsequent pane-targeted ops
// are authorized against the caller's identity (`requirePrincipal` →
// `PaneCoordinator.authorize`): a session reaches only its own panes,
// the validated GUI peer spans sessions, and a foreign paneId is
// indistinguishable from an unknown one.
//
// Initial-frame delivery: `pane.create` doesn't carry an
// `ioSurfaceId`. The GUI immediately calls `pane.subscribe`, and
// the daemon's subscribe handler synthesizes a `surface.changed`
// evt + side-band surface payload pair for the pane's current
// frame (if any) before yielding live events. Same shape for
// every subsequent surface update; one code path, one ownership
// model.
//
// `pane.close` is the only place pane lifecycle and device lifecycle
// touch: in `shutdown` mode, `PaneCoordinator.close` reports the UDID
// back via its return value and the handler then calls
// `DeviceCoordinator.shutdown`, keeping the two coordinators
// decoupled while letting one RPC do both jobs.

import CoreGraphics
import DaemonProtocol
import Foundation

public enum PaneMethods {
    // MARK: - Wire shapes

    public struct CreateParams: Codable, Sendable {
        public let sessionId: String
        public let cap: String
        /// Currently always `"sim"`. The field is retained as a wire-
        /// stable discriminator so future pane kinds can be added
        /// without changing the request shape.
        public let kind: String
        /// Required when `kind == "sim"`.
        public let udid: String?
        /// See `DeviceMethods.AttachParams.revision`.
        public let revision: UInt64?

        public init(sessionId: String, cap: String, kind: String, udid: String?, revision: UInt64? = nil) {
            self.sessionId = sessionId
            self.cap = cap
            self.kind = kind
            self.udid = udid
            self.revision = revision
        }
    }

    /// Carries the three-layer identifier model: current daemons
    /// always emit `shortId`; `name` is nil at create while the shipped
    /// `pane rename` command remains unimplemented. The wire-side shape lives
    /// in `DaemonProtocol.PaneCreateResponse` and decodes both as
    /// Optionals so an older client tolerates the skew.
    public struct CreateResponse: Codable, Sendable, Equatable {
        public let paneId: String
        /// Identifies this admission of the pane; see
        /// `DaemonProtocol.PaneCreateResponse.attachment`.
        public let attachment: UInt64?
        /// Sim only.
        public let scale: Double?
        /// Coarse device family (`watch`/`phone`/`pad`/`tv`/`unknown`)
        /// so the GUI can size the pane. See `DeviceFamily`.
        public let family: String
        public let shortId: String
        public let name: String?
        /// Human-readable device type from `SimDeviceType.name`. See
        /// `DaemonProtocol.PaneCreateResponse.deviceType`.
        public let deviceType: String?
        /// Native pixel dimensions of the device's display. Nil when
        /// the renderable hasn't bound a surface yet. The GUI uses
        /// these for the four size presets (Physical / Point Accurate
        /// / Pixel Accurate / Fit Screen).
        public let pixelWidth: Int?
        public let pixelHeight: Int?
        /// Per-pane device-control capabilities. See
        /// `DaemonProtocol.PaneCapabilities`.
        public let capabilities: PaneCapabilities
        /// Backend-neutral identity + kind discriminator (`.sim` vs
        /// `.device`).
        public let target: PaneTarget
    }

    public struct CloseParams: Codable, Sendable {
        public let paneId: String
        /// `"detach"` (default): drop the pane, leave the underlying
        /// sim running. `"shutdown"`: also shut down the sim.
        public let mode: String?
        /// The `attachment` from the attach response the caller is closing
        /// against. Optional: when present the close is refused unless the
        /// record is still that admission, so a close racing a re-attach
        /// can't retire the pane the re-attach just handed to someone else.
        /// Absent means close unconditionally.
        public let expectedAttachment: UInt64?

        public init(paneId: String, mode: String?, expectedAttachment: UInt64? = nil) {
            self.paneId = paneId
            self.mode = mode
            self.expectedAttachment = expectedAttachment
        }
    }

    public struct SubscribeParams: Codable, Sendable {
        public let paneId: String
    }

    public struct SurfaceChangedEvent: Codable, Sendable, Equatable {
        public let paneId: String
        /// Per-pane monotonic counter. Pairs the JSON evt with the
        /// side-band surface payload that ships on the same XPC
        /// connection; the GUI keys its `(paneId, sequence) →
        /// IOSurfaceRef?` correlation table on this. Restarts at 1
        /// on daemon relaunch.
        public let sequence: UInt64
    }

    public struct StateChangedEvent: Codable, Sendable, Equatable {
        public let paneId: String
        public let state: String
    }

    // MARK: - Input wire shapes

    // The `pane.input.*`, `pane.ax.*`, and `panes.list` request shapes
    // are shared `DaemonProtocol` types (`TapParams`, `SwipeParams`,
    // `MultitouchParams`, `AXPointParams`, `PanesListParams`, …), defined
    // once so the CLI and GUI clients encode the exact shape the handlers
    // below decode. Only the `panes.list` *response* entry stays here:
    // it is daemon-emitted, not a request the clients build.

    /// One entry of the bare-array `panes.list` result. Mirrors
    /// `DaemonProtocol.PanesListEntry` (the client-decoded shape).
    ///
    /// `shortId` + `name` are the three-layer identifier model.
    /// Current daemons always emit `shortId`; older clients ignore
    /// the field (Optional on the wire side).
    public struct PanesListEntry: Codable, Sendable, Equatable {
        public let paneId: String
        public let udid: String
        public let state: String
        /// Coarse device family (`watch`/`phone`/`pad`/`tv`/`unknown`).
        public let family: String
        public let shortId: String
        public let name: String?
        /// Per-pane device-control capabilities. See
        /// `DaemonProtocol.PaneCapabilities`.
        public let capabilities: PaneCapabilities
        /// Backend-neutral identity + kind discriminator.
        public let target: PaneTarget
    }

    // MARK: - Gesture / crown defaults

    // Event method names that flow through `pane.subscribe` are the
    // shared `PaneEventName` enum (DaemonProtocol); the encoder below
    // and the GUI client's decoder both key off it.

    /// Matches the typical `UIScrollView` deceleration; a reasonable
    /// "feels like a swipe, not a flick" default for automation.
    public static let swipeDefaultDurationMs: Int = 200

    /// Matches iOS's default 500ms long-press threshold.
    public static let longPressDefaultDurationMs: Int = 500

    /// Default pinch duration (300ms), slightly longer than swipe so
    /// the gesture reads as deliberate to UIKit's gesture recognizers.
    public static let pinchDefaultDurationMs: Int = 300

    /// Default crown duration (0ms): a single send of the full delta.
    /// Callers wanting a smooth scroll pass a positive `durationMs`.
    public static let crownDefaultDurationMs: Int = 0

    // MARK: - Handlers

    public static func create(
        paneCoordinator: PaneCoordinator,
        sessionManager: SessionManager
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(CreateParams.self, from: paramsJSON)
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
            // A valid payload cap must not target a session other than the
            // connection's own (the cap is `ps -E`-readable); the validated GUI
            // is the only cross-session exception.
            try SessionMethods.requirePayloadMatchesConnection(sessionId)

            guard params.kind == "sim" else {
                throw RPCMethodError.invalidParams("kind must be \"sim\"")
            }
            guard let udid = params.udid else {
                throw RPCMethodError.invalidParams("kind=\"sim\" requires `udid`")
            }
            let result: PaneCreateResult
            do {
                let ownerIncarnation = await PaneAccessPrincipal.ownerIncarnation(for: sessionId) {
                    await sessionManager.incarnation(of: sessionId)
                }
                result = try await paneCoordinator.createSim(
                    sessionId: sessionId,
                    udid: udid,
                    revision: params.revision,
                    ownerIncarnation: ownerIncarnation,
                    requireConcreteIncarnation: true,
                    isOwnerSessionAlive: { [sessionManager] priorOwner in
                        await sessionManager.isAlive(priorOwner)
                    }
                )
            } catch let error as PaneError {
                throw mapPaneError(error)
            }
            return try JSONEncoder().encode(
                CreateResponse(
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

    public static func close(
        paneCoordinator: PaneCoordinator,
        deviceCoordinator: DeviceCoordinator,
        physicalDeviceCoordinator: PhysicalDeviceCoordinator
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(CloseParams.self, from: paramsJSON)
            guard let paneId = UUID(uuidString: params.paneId) else {
                throw RPCMethodError.invalidParams("paneId must be a UUID string")
            }
            let mode: PaneCloseMode
            switch params.mode {
            case nil, "detach":
                mode = .detach

            case "shutdown":
                mode = .shutdown

            default:
                throw RPCMethodError.invalidParams(
                    "mode must be \"detach\" or \"shutdown\""
                )
            }
            let principal = try requirePrincipal()
            let result = await paneCoordinator.close(
                paneId: paneId,
                as: principal,
                mode: mode,
                expecting: params.expectedAttachment,
                // Runs inside the coordinator's own sequence, which holds the
                // pane's target reserved across it. Returning these for the
                // caller to run would let a create attach as soon as the record
                // was gone, and this close's shutdown would then kill it.
                externalCleanup: { [physicalDeviceCoordinator, deviceCoordinator] actions in
                    if let deviceId = actions.deviceTunnelToRelease {
                        // Ref-counted, so the tunnel survives while another
                        // pane still mirrors this device.
                        await physicalDeviceCoordinator.releaseKeepalive(deviceId: deviceId)
                    }
                    guard let udid = actions.udidToShutdown else { return nil }
                    do {
                        try await deviceCoordinator.shutdown(udid: udid)
                        return nil
                    } catch {
                        // Logged unconditionally, because a deferred close has
                        // no caller left to fail: the ack went out before this
                        // ran. An inline close also throws it.
                        DiagnosticLog.lifecycle.error(
                            "pane close: shutdown of \(udid, privacy: .public) failed: \(error)"
                        )
                        return error
                    }
                }
            )
            if let error = result.cleanupError as? DeviceError {
                throw DeviceMethods.mapDeviceError(error)
            }
            return try JSONEncoder().encode(RPCAck(success: true))
        }
    }

    public static func subscribe(
        paneCoordinator: PaneCoordinator
    ) -> MethodRegistry.SubscriptionHandler {
        { [paneCoordinator] paramsJSON, context in
            let params = try JSONDecoder().decode(SubscribeParams.self, from: paramsJSON)
            guard let paneId = UUID(uuidString: params.paneId) else {
                throw RPCMethodError.invalidParams("paneId must be a UUID string")
            }
            let principal = try requirePrincipal()
            let subscriptionId: UUID
            let paneStream: AsyncStream<PaneEvent>
            do {
                (subscriptionId, paneStream) = try await paneCoordinator.subscribe(
                    paneId: paneId,
                    as: principal,
                    context: context
                )
            } catch let error as PaneError {
                throw mapPaneError(error)
            }

            // Adapt the PaneEvent stream into RPC SubscriptionEvents.
            let (eventStream, eventContinuation) =
                AsyncStream<MethodRegistry.SubscriptionEvent>.makeStream()
            let encoder = JSONEncoder()
            let paneIdString = paneId.uuidString
            let adapter = Task {
                for await event in paneStream {
                    switch event {
                    case let .surfaceChanged(_, sequence):
                        let payload = SurfaceChangedEvent(
                            paneId: paneIdString,
                            sequence: sequence
                        )
                        if let encoded = try? encoder.encode(payload) {
                            eventContinuation.yield(
                                MethodRegistry.SubscriptionEvent(
                                method: PaneEventName.surfaceChanged.rawValue,
                                params: encoded
                            )
                                )
                        }

                    case let .stateChanged(_, state):
                        let payload = StateChangedEvent(
                            paneId: paneIdString,
                            state: state.rawValue
                        )
                        if let encoded = try? encoder.encode(payload) {
                            eventContinuation.yield(
                                MethodRegistry.SubscriptionEvent(
                                method: PaneEventName.stateChanged.rawValue,
                                params: encoded
                            )
                                )
                        }

                    case let .orientationChanged(_, orientation):
                        let payload = OrientationChangedEvent(
                            paneId: paneIdString,
                            orientation: orientation.rawValue
                        )
                        if let encoded = try? encoder.encode(payload) {
                            eventContinuation.yield(
                                MethodRegistry.SubscriptionEvent(
                                method: PaneEventName.orientationChanged.rawValue,
                                params: encoded
                            )
                                )
                        }
                    }
                }
                eventContinuation.finish()
            }

            // Compose the idempotent, pool-free producer cleanup: cancel
            // the event adapter and unsubscribe the coordinator
            // subscriber. Every transport (UDS, XPC sim, XPC device) uses
            // it; the device pool teardown rides the lifecycle on top.
            let cleanup = FireOnce { [weak paneCoordinator] in
                adapter.cancel()
                Task { [weak paneCoordinator] in
                    await paneCoordinator?.unsubscribe(
                        paneId: paneId,
                        subscriptionId: subscriptionId
                    )
                }
            }

            // Arm the cleanup locally the instant it's composed, so any
            // synchronous pre-result throw in this handler (the ack encode
            // below) tears the producer down regardless of transport (UDS
            // has no lifecycle to route through). An *async* drain/orphan
            // signal that arrives during setup is handled by the lifecycle
            // (XPC), not this defer. Ownership transfers to `onCancel` (and
            // the lifecycle, for XPC) on a successful return, at which point
            // the `defer` is disarmed.
            var armed: (@Sendable () -> Void)? = { cleanup() }
            defer { armed?() }

            let initialResult = try encoder.encode(
                PaneSubscribeAck(
                success: true,
                subscriptionToken: context?.subscriptionToken.uuidString
            )
                )

            // XPC also installs the same idempotent closure into the
            // lifecycle so a drain/orphan arriving during setup fires it;
            // the local `defer` covers the synchronous throw, the
            // lifecycle covers the async signal, and `FireOnce` makes the
            // overlap safe.
            if let lifecycle = context?.lifecycle {
                await lifecycle.installProducerCleanup { cleanup() }
            }
            armed = nil
            return MethodRegistry.SubscriptionResult(
                initialResult: initialResult,
                events: eventStream,
                onCancel: { cleanup() }
            )
        }
    }

    /// `pane.surfaceRelease`: one-way notification. Applies the GUI's
    /// cumulative low-water-mark ack to the device pane's pool. Authority
    /// is the peer connection: the handler reads the source connection id
    /// from the dispatch context and the pool rejects any ack whose
    /// connection ≠ the token's registered connection. Returns the
    /// standard ack shape, which the notification dispatcher discards.
    public static func surfaceRelease(
        paneCoordinator: PaneCoordinator
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(SurfaceReleaseParams.self, from: paramsJSON)
            guard let paneId = UUID(uuidString: params.paneId),
                let token = UUID(uuidString: params.subscriptionToken)
            else {
                throw RPCMethodError.invalidParams(
                    "paneId and subscriptionToken must be UUID strings"
                )
            }
            let connectionId = DispatchPeerContext.current?.connectionId ?? 0
            await paneCoordinator.releaseWatermark(
                paneId: paneId,
                token: token,
                epoch: params.leaseEpoch,
                lowestHeld: params.lowestHeld,
                connectionId: connectionId
            )
            return try JSONEncoder().encode(RPCAck(success: true))
        }
    }

    /// `pane.surfaceDrain`: one-way notification. Transport-intercepted
    /// on XPC before generic dispatch (the subscription task lives on the
    /// connection, keyed by the subscribe request id, which no registry
    /// handler can resolve). Over UDS there is no surface subscription to
    /// drain, so this registered handler (present for the registry-drift
    /// guard and to keep the method dispatchable) is a no-op.
    public static func surfaceDrain() -> MethodRegistry.Handler {
        { _ in
            try JSONEncoder().encode(RPCAck(success: true))
        }
    }

    // MARK: - Input handlers

    public static func tap(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(TapParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let principal = try requirePrincipal()
            return try await paneAck {
                try await paneCoordinator.tap(paneId: paneId, as: principal, x: params.x, y: params.y)
            }
        }
    }

    public static func touch(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(TouchParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let principal = try requirePrincipal()
            let phase = try requireTouchPhase(params.phase)
            return try await paneAck {
                try await paneCoordinator.touch(
                    paneId: paneId,
                    as: principal,
                    x: params.x,
                    y: params.y,
                    phase: phase
                )
            }
        }
    }

    public static func edgeTouch(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(EdgeTouchParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let principal = try requirePrincipal()
            let phase = try requireTouchPhase(params.phase)
            return try await paneAck {
                try await paneCoordinator.edgeTouch(
                    paneId: paneId,
                    as: principal,
                    x: params.x,
                    y: params.y,
                    phase: phase,
                    edge: params.edge
                )
            }
        }
    }

    public static func swipe(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(SwipeParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let durationMs = try requireValidDuration(params.durationMs ?? swipeDefaultDurationMs)
            let holdMs = try requireValidDuration(params.holdMs ?? 0)
            let startHoldMs = try requireValidDuration(params.startHoldMs ?? 0)
            let principal = try requirePrincipal()
            let outcome: PaneCoordinator.SwipeOutcome
            do {
                outcome = try await paneCoordinator.swipe(
                    paneId: paneId,
                    as: principal,
                    fromX: params.fromX,
                    fromY: params.fromY,
                    toX: params.toX,
                    toY: params.toY,
                    durationMs: durationMs,
                    holdMs: holdMs,
                    startHoldMs: startHoldMs
                )
            } catch let error as PaneError {
                throw mapPaneError(error)
            }
            return try JSONEncoder().encode(
                SwipeAck(
                steps: outcome.steps,
                durationMs: outcome.durationMs
            )
                )
        }
    }

    public static func edgeSwipe(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(EdgeSwipeParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let durationMs = try requireValidDuration(params.durationMs ?? swipeDefaultDurationMs)
            let holdMs = try requireValidDuration(params.holdMs ?? 0)
            let principal = try requirePrincipal()
            return try await paneAck {
                try await paneCoordinator.edgeSwipe(
                    paneId: paneId,
                    as: principal,
                    fromX: params.fromX,
                    fromY: params.fromY,
                    toX: params.toX,
                    toY: params.toY,
                    edge: params.edge,
                    durationMs: durationMs,
                    holdMs: holdMs
                )
            }
        }
    }

    public static func longPress(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(LongPressParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let durationMs = try requireValidDuration(params.durationMs ?? longPressDefaultDurationMs)
            let principal = try requirePrincipal()
            return try await paneAck {
                try await paneCoordinator.longPress(
                    paneId: paneId,
                    as: principal,
                    x: params.x,
                    y: params.y,
                    durationMs: durationMs
                )
            }
        }
    }

    public static func key(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(KeyParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let principal = try requirePrincipal()
            return try await paneAck {
                try await paneCoordinator.key(
                    paneId: paneId,
                    as: principal,
                    keyCode: params.keyCode,
                    down: params.down
                )
            }
        }
    }

    public static func button(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(ButtonParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            guard let button = HardwareButton(rawValue: params.button) else {
                throw RPCMethodError.invalidParams(
                    "button must be one of: "
                    + HardwareButton.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            let principal = try requirePrincipal()
            return try await paneAck {
                try await paneCoordinator.pressButton(paneId: paneId, as: principal, button: button)
            }
        }
    }

    public static func pinch(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(PinchParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let durationMs = try requireValidDuration(params.durationMs ?? pinchDefaultDurationMs)
            let principal = try requirePrincipal()
            return try await paneAck {
                try await paneCoordinator.pinch(
                    paneId: paneId,
                    as: principal,
                    fromF1X: params.fromF1X,
                    fromF1Y: params.fromF1Y,
                    fromF2X: params.fromF2X,
                    fromF2Y: params.fromF2Y,
                    toF1X: params.toF1X,
                    toF1Y: params.toF1Y,
                    toF2X: params.toF2X,
                    toF2Y: params.toF2Y,
                    durationMs: durationMs
                )
            }
        }
    }

    public static func multitouch(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(MultitouchParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let phase = try requireTouchPhase(params.phase)
            guard params.points.count == 2 else {
                throw RPCMethodError.invalidParams(
                    "points must contain exactly 2 contacts (got \(params.points.count))"
                )
            }
            let points = params.points.map { CGPoint(x: $0.x, y: $0.y) }
            let principal = try requirePrincipal()
            return try await paneAck {
                try await paneCoordinator.multitouch(
                    paneId: paneId,
                    as: principal,
                    phase: phase,
                    points: points
                )
            }
        }
    }

    public static func text(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(TextParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let principal = try requirePrincipal()
            return try await paneAck {
                try await paneCoordinator.text(paneId: paneId, as: principal, text: params.text)
            }
        }
    }

    public static func axTree(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(AXTreeParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let principal = try requirePrincipal()
            let treeJSON: Data
            do {
                treeJSON = try await paneCoordinator.accessibilityTree(paneId: paneId, as: principal)
            } catch let error as PaneError {
                throw mapPaneError(error)
            }
            return try wrapAXResult(key: "tree", innerJSON: treeJSON)
        }
    }

    public static func axPoint(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(AXPointParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let principal = try requirePrincipal()
            let elementJSON: Data
            do {
                elementJSON = try await paneCoordinator.accessibilityElement(
                    paneId: paneId,
                    as: principal,
                    x: params.x,
                    y: params.y
                )
            } catch let error as PaneError {
                throw mapPaneError(error)
            }
            return try wrapAXResult(key: "element", innerJSON: elementJSON)
        }
    }

    public static func axSweep(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(AXSweepParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let principal = try requirePrincipal()
            let sweepJSON: Data
            do {
                sweepJSON = try await paneCoordinator.accessibilitySweep(
                    paneId: paneId,
                    as: principal,
                    step: params.step
                )
            } catch let error as PaneError {
                throw mapPaneError(error)
            }
            // Wrap under `tree` so CLI consumers handle ax tree and ax
            // sweep responses identically, aggregating unique
            // elements into the same JSON shape as `ax tree`.
            // Agents that need to distinguish read the synthetic
            // root's `role: "AXSweepRoot"`.
            return try wrapAXResult(key: "tree", innerJSON: sweepJSON)
        }
    }

    /// `pane.location.set({paneId, location}) → {ok}`.
    ///
    /// The value is checked here, before the coordinator call, so a
    /// caller mistake reads as `invalidParams` rather than surfacing as
    /// an opaque bridge fault or a `devicectl` non-zero exit. That
    /// covers a coordinate's range and a route's whole shape (waypoint
    /// count against `RouteSpec`'s floor and cap, a positive finite
    /// speed and cadence, every waypoint on the globe), since
    /// `SimulatedLocation.defect` delegates to `RouteSpec.defect`. The
    /// GUI checks a route before framing it so the failure lands next to
    /// the row that was clicked; this is not that check trusting it, it
    /// is the daemon not trusting a client.
    ///
    /// Scenario *names* can't be validated here, since the valid set is
    /// a per-device runtime list. They are checked further down, and
    /// differently per backend: the simulator backend pre-validates
    /// against its own enumeration (CoreSimulator's setter accepts an
    /// unknown name, reports success, and changes nothing), while the
    /// device path lets `devicectl` report its own rejection. Both land
    /// on `PaneError.unknownLocationScenario` and map to `invalidParams`,
    /// so the two backends answer a typo the same way.
    public static func locationSet(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(PaneLocationSetParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            if let defect = params.location.defect {
                throw RPCMethodError.invalidParams(defect.message)
            }
            let principal = try requirePrincipal()
            return try await paneAck {
                try await paneCoordinator.setLocation(
                    paneId: paneId,
                    as: principal,
                    to: params.location
                )
            }
        }
    }

    /// `pane.location.state({paneId}) → {location, scenarios}`.
    ///
    /// `location` is what deviceterm last set, not a device reading;
    /// neither backend has a getter. See `PaneLocationStateResult`.
    public static func locationState(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(PaneLocationStateParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let principal = try requirePrincipal()
            do {
                let state = try await paneCoordinator.locationState(paneId: paneId, as: principal)
                return try JSONEncoder().encode(state)
            } catch let error as PaneError {
                throw mapPaneError(error)
            }
        }
    }

    public static func rotate(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(RotateParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            let target = try rotationTarget(params)
            let principal = try requirePrincipal()
            return try await paneAck {
                try await paneCoordinator.rotate(paneId: paneId, as: principal, target: target)
            }
        }
    }

    public static func crown(paneCoordinator: PaneCoordinator) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(CrownParams.self, from: paramsJSON)
            let paneId = try requirePaneId(params.paneId)
            // `velocity` is decoded (accepted) but deliberately not
            // forwarded; the bridge builder takes only a delta.
            let durationMs = try requireValidDuration(params.durationMs ?? crownDefaultDurationMs)
            let principal = try requirePrincipal()
            return try await paneAck {
                try await paneCoordinator.crown(
                    paneId: paneId,
                    as: principal,
                    delta: params.delta,
                    durationMs: durationMs
                )
            }
        }
    }

    /// `panes.list({sessionId, cap}) → [{paneId, udid, state}]`. This is the
    /// session-scoped discovery the CLI resolves a paneId *through*, so it
    /// validates the payload credentials and confirms the target is the
    /// provenance-checked connection's own session (the `pane.input.*` ops
    /// instead authorize the paneId against the caller's session via
    /// `PaneCoordinator.authorize`). Returns the session's sim panes only.
    public static func panesList(
        paneCoordinator: PaneCoordinator,
        sessionManager: SessionManager
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let params = try JSONDecoder().decode(PanesListParams.self, from: paramsJSON)
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
            // Only the connection's own session (or the validated GUI) may list
            // a session's panes: a stolen payload cap must not enumerate a
            // victim's panes.
            try SessionMethods.requirePayloadMatchesConnection(sessionId)
            let entries = await paneCoordinator.panesForSession(sessionId).map {
                PanesListEntry(
                    paneId: $0.paneId.uuidString,
                    udid: $0.udid,
                    state: $0.state.rawValue,
                    family: $0.family,
                    shortId: $0.shortId,
                    name: $0.name,
                    capabilities: $0.capabilities,
                    target: $0.target
                )
            }
            return try JSONEncoder().encode(entries)
        }
    }

    // MARK: - Helpers

    /// Resolve a `pane.input.rotate` request's two mutually exclusive
    /// fields into the one value the coordinator takes. The wire can
    /// carry both or neither; those are `invalidParams`, named as such
    /// rather than silently preferring one, since a client sending both
    /// has no idea which the daemon would honor.
    static func rotationTarget(_ params: RotateParams) throws -> RotationTarget {
        switch (params.orientation, params.direction) {
        case let (rawOrientation?, nil):
            guard let orientation = Orientation(rawValue: rawOrientation) else {
                throw RPCMethodError.invalidParams(
                    "orientation must be one of: "
                    + Orientation.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            return .absolute(orientation)

        case let (nil, rawDirection?):
            guard let direction = RotationDirection(rawValue: rawDirection) else {
                throw RPCMethodError.invalidParams(
                    "direction must be one of: "
                    + RotationDirection.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            return .relative(direction)

        default:
            throw RPCMethodError.invalidParams(
                "exactly one of orientation or direction is required"
            )
        }
    }

    /// Run a pure pane-input coordinator call and encode the standard
    /// `RPCAck(success: true)`, mapping a thrown `PaneError` to its RPC
    /// error. Decode and `invalidParams` field validation run in the
    /// caller *before* this wrapper, so those errors surface unchanged;
    /// only the coordinator call is guarded here. Handlers that return a
    /// data payload (`swipe`, `axTree`, …) don't use this.
    static func paneAck(_ body: () async throws -> Void) async throws -> Data {
        do {
            try await body()
        } catch let error as PaneError {
            throw mapPaneError(error)
        }
        return try JSONEncoder().encode(RPCAck(success: true))
    }

    /// Wrap an AX-tree or AX-element JSON blob from the coordinator
    /// into the canonical `{key: <blob>}` response shape. The inner
    /// JSON is re-parsed and re-serialized so the wrapper structure
    /// stays valid JSON without manual string concatenation.
    static func wrapAXResult(key: String, innerJSON: Data) throws -> Data {
        let inner = try JSONSerialization.jsonObject(with: innerJSON, options: [])
        let wrapped: [String: Any] = [key: inner]
        return try JSONSerialization.data(
            withJSONObject: wrapped,
            options: [.sortedKeys]
        )
    }

    /// Derive the pane-access principal for the current dispatch. Every
    /// pane-targeted handler (the 16 input/AX ops, `pane.subscribe`, and
    /// `pane.closeById`) calls this and threads the result into the
    /// coordinator, which gates ownership on it: a `.session` principal
    /// reaches only its own panes; the validated `.guiPeer` spans
    /// sessions. Throws `unauthorized` when there is no authenticated
    /// caller (no session and not the validated GUI): a pane operation
    /// must name a principal.
    static func requirePrincipal() throws -> PaneAccessPrincipal {
        guard let principal = PaneAccessPrincipal.fromCurrentDispatch() else {
            throw RPCMethodError.unauthorized("no authenticated caller for pane operation")
        }
        return principal
    }

    /// Parse and require a well-formed paneId string. Throws
    /// `invalidParams` on malformed input so every input handler
    /// gives the same error shape for the same mistake.
    static func requirePaneId(_ paneIdString: String) throws -> UUID {
        guard let paneId = UUID(uuidString: paneIdString) else {
            throw RPCMethodError.invalidParams("paneId must be a UUID string")
        }
        return paneId
    }

    /// Validate a gesture duration before it reaches the coordinator.
    /// Negative values and values past `PaneCoordinator
    /// .maxGestureDurationMs` are caller mistakes, so return
    /// `invalidParams` so the client sees a clear error rather than
    /// silently getting a 0-ms or clamped gesture.
    static func requireValidDuration(_ durationMs: Int) throws -> Int {
        guard durationMs >= 0 else {
            throw RPCMethodError.invalidParams("durationMs must be non-negative")
        }
        guard durationMs <= PaneCoordinator.maxGestureDurationMs else {
            throw RPCMethodError.invalidParams(
                "durationMs must be \(PaneCoordinator.maxGestureDurationMs) or less"
            )
        }
        return durationMs
    }

    static func requireTouchPhase(_ phaseString: String) throws -> TouchPhase {
        guard let phase = TouchPhase(rawValue: phaseString) else {
            throw RPCMethodError.invalidParams(
                "phase must be one of: "
                + TouchPhase.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }
        return phase
    }

    static func mapPaneError(_ error: PaneError) -> RPCMethodError {
        switch error {
        case .staleAttach:
            // The requester has already superseded this attach, so its only
            // consumer is a caller that stopped waiting. Reported rather than
            // silently succeeding, so a live caller could tell the difference.
            return RPCMethodError.invalidParams(
                "attach superseded by a newer request from the same caller"
            )

        case .notFound:
            return RPCMethodError.invalidParams("unknown paneId")

        case let .deviceNotFound(udid):
            return RPCMethodError.invalidParams("unknown UDID: \(udid)")

        case .malformedUDID:
            return RPCMethodError.invalidParams("udid must be a UUID string")

        case .paneNotActive:
            return RPCMethodError.invalidParams(
                "pane is not active (sim has shut down)"
            )

        case let .startStreamFailed(_, message):
            return RPCMethodError(
                code: RPCErrorCode.serverError,
                message: "pane.create: \(message)"
            )

        case let .hidUnavailable(_, message):
            return RPCMethodError(
                code: RPCErrorCode.serverError,
                message: "pane.create: HID unavailable: \(message)"
            )

        case let .bridgeFailed(_, operation, message):
            // Distinct from the catch-all `serverError` so machine
            // consumers can dispatch on "the CoreSimulator bridge
            // spoke up" without substring-matching the message.
            return RPCMethodError(
                code: RPCMethodError.bridgeFailedCode,
                message: "pane.\(operation.label): \(message)"
            )

        case let .unsupportedCharacter(_, character):
            return RPCMethodError.invalidParams(
                "unsupported character in text: '\(character)'"
            )

        case let .unsupportedKeyCode(_, keyCode):
            return RPCMethodError.invalidParams(
                "unsupported kVK keyCode: 0x\(String(keyCode, radix: 16))"
            )

        case let .unsupportedOperation(_, operation):
            return RPCMethodError.invalidParams(
                "operation '\(operation.label)' is not supported on this pane's device"
            )

        case let .unknownLocationScenario(_, name):
            return RPCMethodError.invalidParams(
                "unknown location scenario: '\(name)'"
            )

        case .shortIDExhausted:
            // Vanishingly improbable at this scale (32^6 ≈ 1B values);
            // surface as `serverError` rather than `invalidParams`
            // since the caller can't fix it; they should retry.
            return RPCMethodError(
                code: RPCErrorCode.serverError,
                message: "short_id alphabet exhausted; retry the request"
            )

        case .inputNotQuiesced:
            // Adoption aborted because the prior owner's held input couldn't
            // be released; the transfer didn't happen. Retryable.
            return RPCMethodError(
                code: RPCErrorCode.serverError,
                message: "couldn't reclaim the device because its input channel didn't quiesce; retry"
            )

        case .ownerNotReady:
            // The target session was torn down (or reincarnated) between the
            // handler's validation and the ownership commit, so the coordinator
            // refused to create/re-admit/transfer the pane. Retryable; the GUI
            // re-attaches once the (restored) session is ready again.
            return RPCMethodError(
                code: RPCMethodError.notReadyCode,
                message: "session not ready for pane ownership; retry shortly"
            )

        case let .paneAlreadyAttached(udid, _):
            // The udid already has a live pane under a different
            // session. No CLI verb moves it; only the human (GUI
            // drag) can re-link. `invalidParams` is the closest
            // existing code (the caller's session can't fulfill this
            // request as posed); the message identifies the udid so
            // the caller can route through `deviceterm panes list` to
            // find the existing owner and let the human re-link if
            // they actually want to take over.
            return RPCMethodError.invalidParams(
                "udid \(udid) is already attached to a different "
                + "session; only the human can move it (drag in GUI)"
            )
        }
    }
}
