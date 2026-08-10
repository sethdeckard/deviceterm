// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceBackend: the seam between `PaneCoordinator` and whatever
// drives a pane's display + input.
//
// This protocol is the indirection between the coordinator's per-pane
// record and whatever actually drives the pane. A pane can be driven by
// the four CoreSimulator bridge handles (`SimDisplayHandle`,
// `SimHIDClient`, `SimPurpleHID`, `SimAccessibility`) or by a
// physically-connected device (the split CoreDevice tunnel pipeline),
// and the coordinator doesn't know the difference.
//
// Division of labor: the **coordinator** owns every device-agnostic
// concern: gesture interpolation (swipe/pinch stepping), keymap
// translation (kVK→HID, ASCII→key), JSON shaping of AX trees, error
// context (paneId + verb label), dedup, and lifecycle. A **backend**
// exposes only primitive operations plus its capability set; it never
// interpolates or translates. That keeps the interpolation/keymap
// logic in one place, shared by every backend.

import CoreGraphics
import DaemonProtocol
import Foundation

/// Per-pane device-control capabilities. The coordinator gates each
/// input and accessibility verb on the relevant flag, so one daemon can
/// host a sim pane (supports everything) beside a physical-device pane
/// (a subset) without a daemon-wide capability switch; those flags drive
/// the coordinator's per-verb `unsupportedOperation` guard, `location`
/// included. `pane.location.set` gates on it through `requireBackend`,
/// and `pane.location.state` reports no scenarios for a backend that
/// lacks it.
struct DeviceBackendCapabilities: Sendable, Equatable {
    /// Everything a CoreSimulator pane supports. The daemon imposes no
    /// per-verb restriction on sims. Family-based gating (e.g. hiding
    /// Crown on a phone) is a GUI concern, not a daemon one, so every
    /// flag is `true`.
    static let simulator = DeviceBackendCapabilities(
        touch: true,
        key: true,
        text: true,
        button: true,
        rotate: true,
        crown: true,
        accessibility: true,
        location: true
    )

    /// The **maximal** physical-device capability set: relay-backed input
    /// (touch via the digitizer, hardware buttons, orientation, and
    /// `key`/`text` via a host-registered virtual keyboard) plus location
    /// through `devicectl`. Crown (no hardware) and accessibility (no AX
    /// service over the tunnel) are never supported. A concrete backend
    /// derives the relay-backed flags from which channels/roles opened;
    /// location is independent of them. This is a fixture/default, not
    /// every device's set.
    static let physicalDevice = DeviceBackendCapabilities(
        touch: true,
        key: true,
        text: true,
        button: true,
        rotate: true,
        crown: false,
        accessibility: false,
        location: true
    )

    var touch: Bool
    var key: Bool
    var text: Bool
    var button: Bool
    var rotate: Bool
    var crown: Bool
    var accessibility: Bool
    var location: Bool

    /// The same set with `location` cleared.
    ///
    /// For any conformer that takes the protocol's throwing location
    /// defaults: advertising location while using those defaults would
    /// make the wire capability disagree with backend dispatch.
    var withoutLocation: DeviceBackendCapabilities {
        var copy = self
        copy.location = false
        return copy
    }
}

/// Backend-level error vocabulary. The coordinator translates these to
/// `PaneError`, adding the paneId + verb context it owns. Genuine
/// bridge send-errors are deliberately *not* wrapped here. They
/// propagate raw so the coordinator wraps them as `bridgeFailed` via
/// `BridgeMessage.unwrap`.
enum DeviceBackendError: Error {
    /// The backend has been torn down (its sim shut down / its device
    /// detached). The coordinator maps it to `paneNotActive`.
    case notActive
    /// Lazy accessibility acquisition permanently failed for this
    /// backend (the platform-translation framework is missing on this
    /// host). Carries the message the coordinator surfaces under the
    /// `ax.acquire` operation.
    case accessibilityUnavailable(message: String)
    /// Edge-tagged system gestures (home / App Switcher) aren't supported
    /// by this backend kind. Only the CoreSimulator backend implements
    /// them; physical devices use their own gesture path.
    case unsupportedEdgeGesture
    /// Location simulation isn't implemented by this backend kind (the
    /// stub, and any conformer that takes the protocol defaults).
    case unsupportedLocation
    /// Lazy location acquisition permanently failed for this backend.
    /// Carries the first failure's message so a retry classifies the
    /// same way the original did, as `accessibilityUnavailable` does.
    ///
    /// **Acquisition only.** The wire mapper labels this
    /// `location.acquire`, so a failure that happened while *performing*
    /// a command must not borrow it. The client would be told the
    /// acquisition failed for an operation that got past acquisition
    /// fine. Use `locationCommandFailed` for those.
    case locationUnavailable(message: String)
    /// A location command reached the device layer and failed there, a
    /// non-zero `devicectl` exit being the usual case. Distinct from
    /// `locationUnavailable` so the wire error names the verb the caller
    /// actually invoked rather than a hardcoded acquisition step.
    case locationCommandFailed(message: String)
    /// The location tool answered, but its output couldn't be
    /// understood: a payload whose shape doesn't match what this version
    /// expects.
    ///
    /// Split from `locationUnavailable` because the two demand opposite
    /// responses. A device that isn't reachable is routine, and callers
    /// degrade quietly. Unintelligible output means the tool's schema
    /// moved under us, which is a defect: it makes every device look
    /// like it has no trips, and it is invisible unless something says
    /// so. Keeping it distinguishable is what lets a caller degrade
    /// *and* complain.
    case locationOutputMalformed(message: String)
    /// A scenario absent from a simulator backend's available scenarios.
    /// Rejected before calling CoreSimulator because its setter silently
    /// accepts unknown names, returning success while changing nothing.
    /// The physical-device backend forwards names to `devicectl`, which
    /// reports its own rejection.
    case unknownLocationScenario(name: String)
}

/// The display + input primitives a pane backend must provide. All
/// methods are synchronous and called only from inside the
/// `PaneCoordinator` actor; the frame callback hops back into that
/// actor before any coordinator state is touched.
protocol DeviceBackend: AnyObject, Sendable {
    /// What this backend can do; drives the coordinator's per-verb gate.
    var capabilities: DeviceBackendCapabilities { get }

    /// Whether a synthesized edge-tagged touch swipe actually reaches
    /// SpringBoard's system-gesture recognizer on this backend. True for the
    /// CoreSimulator backend (the `IndigoHIDEdge` tag routes it). False for a
    /// physical device: its digitizer report reaches the foreground app but
    /// not the gesture manager, so the App Switcher must be realized another
    /// way (a consumer-HID Home double-press). Drives the coordinator's
    /// App Switcher dispatch.
    var supportsSystemEdgeGesture: Bool { get }

    // MARK: Frames

    /// Begin streaming frames. `onFrame` is invoked on the producer's
    /// queue with each freshly-published surface; the coordinator hops
    /// to its actor to fan it out. `onFatal` fires at most once when frame
    /// streaming fails terminally: an unrecoverable surface-pool exhaustion
    /// (after its one controlled recovery) or the frame pipeline giving up, and
    /// the coordinator fails the pane. Backends that can't fail terminally never
    /// call it. Throws if the stream can't start.
    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void
    ) throws
    /// Stop streaming and release the display subscription. Idempotent.
    func stopFrames()
    /// Native pixel dimensions, or `(nil, nil)` if not yet known
    /// (pre-first-frame, or post-shutdown).
    func pixelDimensions() -> (Int?, Int?)

    // MARK: Touch (points are normalized 0…1, origin top-left)
    //
    // Every input primitive carries the operation's `generation`: the
    // token the coordinator captured at admission (atomically with the
    // ownership gate) and threaded through the synthesis. The backend
    // stamps (device pump) or gates (sim, atomically with the send) on it,
    // so a send from an operation an ownership transfer has invalidated
    // never reaches the new owner's device. A backend with no input fence
    // ignores it.

    func tapDown(at point: CGPoint, generation: UInt64) throws
    func tapUp(at point: CGPoint, generation: UInt64) throws
    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws
    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws

    // MARK: Edge-tagged touch (system gestures, sim-only)
    //
    // A touch tagged with the screen edge it originates from, which iOS
    // routes to SpringBoard's system edge-gesture recognizer (home
    // indicator / App Switcher) instead of app content. `edge` is the raw
    // `IndigoHIDEdge` value. Only the CoreSimulator backend implements
    // these; other backends inherit the default that throws
    // `unsupportedEdgeGesture`.

    func edgeTouchDown(at point: CGPoint, edge: Int, generation: UInt64) throws
    func edgeTouchMove(at point: CGPoint, edge: Int, generation: UInt64) throws
    func edgeTouchUp(at point: CGPoint, edge: Int, generation: UInt64) throws

    // MARK: System gesture (App Switcher, device-only)
    //
    // Open the iOS App Switcher via a system-gesture touch swipe on the device,
    // the home-indicator gesture a plain synthetic touch can't reach. `edge` is
    // the `IndigoHIDEdge` value of the home-indicator's current display edge, so
    // the swipe rotates with the device. Only the physical-device backend
    // implements this; others inherit the default that throws
    // `unsupportedEdgeGesture`, so the coordinator falls back to a Home
    // double-press.
    func openAppSwitcher(edge: Int, generation: UInt64) throws

    // MARK: Keyboard (HID usage codes, translation is the caller's job)

    func keyDown(hidUsage: UInt32, generation: UInt64) throws
    func keyUp(hidUsage: UInt32, generation: UInt64) throws

    // MARK: Buttons / rotation / crown

    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) throws
    /// Rotate to `orientation`, returning whether the device **actually
    /// performed** it: `true` only when the rotation ran (not fenced by a
    /// transfer that bumped the generation) *and* the device settled on the
    /// requested orientation. `false` for a fenced or failed-to-reach
    /// rotation. The coordinator broadcasts `orientationChanged` only on
    /// `true`, so the GUI never rotates its presentation for a rotation the
    /// device did not make. A synchronous backend performs it inline and
    /// reports its own send outcome.
    func rotate(to orientation: Orientation, generation: UInt64) async throws -> Bool
    func rotateCrown(delta: Double, generation: UInt64) throws

    // MARK: Accessibility (lazy acquisition lives in the backend)

    /// The frontmost app's AX tree as the bridge's raw dict. Throws
    /// `DeviceBackendError.accessibilityUnavailable` if acquisition
    /// permanently failed; lets a per-call bridge error propagate raw.
    func accessibilityFrontmostTree() throws -> [String: Any]
    /// The single AX element at a pixel-space point (same dict shape
    /// minus `children`).
    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any]

    // MARK: Lifecycle

    /// Tear down device resources. **Never reboots a real device**. The
    /// only effect is releasing this host's handles/streams.
    ///
    /// Contract: an input call already in flight (a multi-step
    /// swipe/pinch/longPress/crown that captured this backend before its
    /// first `await`) must still be able to complete its remaining
    /// primitives after `shutdownBackend()` runs. The coordinator gates
    /// *new* input by niling `record.backend`, so a conformer must not
    /// invalidate the input path out from under a captured reference:
    /// release input resources via the object's own lifetime instead.
    func shutdownBackend()

    // MARK: Ownership-transfer input fence
    //
    // When a pane is adopted into a new session (the prior owner's GUI
    // died), input the *prior* owner already enqueued must not execute
    // against the new owner's device. This is distinct from
    // `shutdownBackend`, which deliberately *drains* buffered input so an
    // in-flight gesture completes. That is exactly the wrong contract for a
    // transfer. The coordinator fences input around the ownership flip:

    /// Invalidate the current input generation for an ownership transfer:
    /// stop admitting new input, discard any buffered/queued input with
    /// cancellation (do **not** drain-and-execute), release any held
    /// touch/key contact on the prior owner's behalf (so the new owner
    /// doesn't inherit a finger or key still down), and return only once
    /// no stale input can still send. That returned `await` is the
    /// no-further-send fence. Paired with `resumeInput`.
    ///
    /// Returns `true` iff every held-input release actually landed. A `false`
    /// means the backend can't guarantee the device is input-clean (a
    /// release send failed, which is *not* proof the tunnel is down, it can
    /// be transient), and the coordinator must **abort the transfer** rather
    /// than flip ownership onto a device that may still hold the prior
    /// owner's input.
    func quiesceInputForTransfer() async -> Bool

    /// Open a fresh input generation so the new owner's input is admitted
    /// again. Called by the coordinator after the ownership flip, or on an
    /// aborted transfer for the surviving owner. Idempotent.
    func resumeInput()

    /// The current input generation: a paced gesture captures it at
    /// admission and re-checks it (via `isInputGenerationCurrent`) before
    /// every send, so a transfer that bumps the generation stops the
    /// gesture rather than letting it drive the new owner's device. A
    /// backend with no cancellable input keeps it constant.
    func currentInputGeneration() -> UInt64
    /// Whether `generation` is still current: false once a transfer has
    /// invalidated it. A monotonic generation means a captured value never
    /// becomes current again (ABA-safe across a quiesce+resume).
    func isInputGenerationCurrent(_ generation: UInt64) -> Bool

    // MARK: Surface-lease overlay (device panes only)
    //
    // A backend that owns a leased surface pool registers each XPC
    // subscription's token, applies its cumulative release acks, and drains
    // or orphans it on teardown. Sim/stub backends have no pool and inherit
    // the default no-ops below.

    /// Register a subscription token so the pool admits grants for it.
    func registerLeaseToken(_ token: UUID, connectionId: UInt64) async
    /// Drop a token that holds nothing: the fast path for both setup
    /// failure and a graceful drain of a token with no outstanding holds.
    /// Returns false when the token still holds a grant, so the caller
    /// falls back to `drain`.
    func unregisterLeaseTokenIfUnused(_ token: UUID) async -> Bool
    /// Apply a cumulative low-water-mark release ack, honored only from the
    /// registering connection.
    func releaseWatermark(token: UUID, epoch: UInt64, lowestHeld: UInt64, connectionId: UInt64) async
    /// Graceful drain: no new grants; outstanding leases still drain via
    /// acks.
    func drain(token: UUID) async
    /// Abrupt loss: orphan the token (held slots quarantined, never
    /// force-freed; late acks still drain them).
    func orphan(token: UUID) async

    // MARK: Location simulation

    // The mutations carry `generation:` for the same reason the input
    // verbs do. The physical-device conformer suspends on a `devicectl`
    // subprocess, and an ownership transfer can commit during that
    // suspension: without the fence a prior owner's command would land
    // after the flip, and two in-flight commands could complete out of
    // order. Conformers that suspend must serialize these against each
    // other and drop a command whose generation has gone stale.
    //
    // `availableLocationScenarios` is a read, so it is unfenced.

    /// Pin the device to a fixed coordinate until cleared.
    func setSimulatedLocation(latitude: Double, longitude: Double, generation: UInt64) async throws
    /// Start a named scenario.
    ///
    /// Whether an unknown name is rejected here is conformer-specific:
    /// the simulator must pre-check it (CoreSimulator accepts unknown
    /// names silently), while a conformer whose underlying tool reports
    /// its own failure may forward the name and surface that instead.
    /// Either way an unknown name must produce an error, never a silent
    /// success.
    func setSimulatedLocationScenario(_ name: String, generation: UInt64) async throws
    /// Walk the device along a caller-supplied route.
    ///
    /// Route playback and a named scenario are the same operation with
    /// different waypoint sources, so this shares the `location`
    /// capability rather than adding one of its own. If a backend ever
    /// supports points but not routes, that is when the flag splits.
    ///
    /// `spec` arrives already validated (`RouteSpec.defect`), so a
    /// conformer may pass it on without re-checking arity or ranges.
    func startSimulatedLocationRoute(_ spec: RouteSpec, generation: UInt64) async throws
    /// Stop any running scenario or route and drop the simulated
    /// position.
    func clearSimulatedLocation(generation: UInt64) async throws
    /// The named scenarios this backend offers. May legitimately be
    /// empty (a simulator vends none until booted).
    func availableLocationScenarios() async throws -> [String]
}

extension DeviceBackend {
    // Default: only the CoreSimulator backend routes a synthetic edge swipe
    // to the system recognizer. Physical devices fall back to the button
    // realization of the App Switcher.
    var supportsSystemEdgeGesture: Bool { false }

    // Default: only the CoreSimulator backend overrides these. Other
    // backends (physical device, stub) reject edge gestures.
    func edgeTouchDown(at point: CGPoint, edge: Int, generation: UInt64) throws {
        throw DeviceBackendError.unsupportedEdgeGesture
    }
    func edgeTouchMove(at point: CGPoint, edge: Int, generation: UInt64) throws {
        throw DeviceBackendError.unsupportedEdgeGesture
    }
    func edgeTouchUp(at point: CGPoint, edge: Int, generation: UInt64) throws {
        throw DeviceBackendError.unsupportedEdgeGesture
    }

    // Default: only the physical-device backend opens the App Switcher via a
    // system-gesture touch swipe. Others throw, so the coordinator falls back to
    // the Home double-press realization.
    func openAppSwitcher(edge: Int, generation: UInt64) throws {
        throw DeviceBackendError.unsupportedEdgeGesture
    }

    // Default: no surface pool, so lease bookkeeping is a no-op. Only a
    // backend that owns a `LeasedSurfacePool` overrides these. (The empty
    // async bodies satisfy the async protocol requirement.)
    // swiftlint:disable async_without_await
    func registerLeaseToken(_ token: UUID, connectionId: UInt64) async {}
    func unregisterLeaseTokenIfUnused(_ token: UUID) async -> Bool { true }
    func releaseWatermark(token: UUID, epoch: UInt64, lowestHeld: UInt64, connectionId: UInt64) async {}
    func drain(token: UUID) async {}
    func orphan(token: UUID) async {}
    // swiftlint:enable async_without_await

    // Default input fence: a backend whose input is synchronous and holds
    // no cancellable in-flight state (the stub) has nothing to quiesce.
    // The simulator backend overrides `quiesceInputForTransfer` to bump a
    // cooperative-cancellation generation the synthesis loop checks; the
    // device backend threads it through its buffered pumps. `resumeInput`
    // is a no-op wherever admission isn't generation-gated.
    // swiftlint:disable async_without_await
    func quiesceInputForTransfer() async -> Bool { true }
    // swiftlint:enable async_without_await
    func resumeInput() {}
    func currentInputGeneration() -> UInt64 { 0 }
    func isInputGenerationCurrent(_ generation: UInt64) -> Bool { true }

    // Default: a backend that hasn't wired location rejects it rather
    // than silently succeeding. A conformer taking these defaults must
    // also report `location: false` in its capabilities, so its
    // advertised capability agrees with backend dispatch;
    // `StubDeviceBackend` is the in-tree example.
    // swiftlint:disable async_without_await
    func setSimulatedLocation(latitude: Double, longitude: Double, generation: UInt64) async throws {
        throw DeviceBackendError.unsupportedLocation
    }
    func setSimulatedLocationScenario(_ name: String, generation: UInt64) async throws {
        throw DeviceBackendError.unsupportedLocation
    }
    func startSimulatedLocationRoute(_ spec: RouteSpec, generation: UInt64) async throws {
        throw DeviceBackendError.unsupportedLocation
    }
    func clearSimulatedLocation(generation: UInt64) async throws {
        throw DeviceBackendError.unsupportedLocation
    }
    func availableLocationScenarios() async throws -> [String] {
        throw DeviceBackendError.unsupportedLocation
    }
    // swiftlint:enable async_without_await
}

extension DeviceBackendCapabilities {
    /// Wire projection for `pane.create` / `panes.list`. The daemon-only
    /// `DeviceBackendCapabilities` (which drives the coordinator's
    /// per-verb gate) maps 1:1 to the Foundation-only `PaneCapabilities`
    /// wire shape. This is not a protocol conformance (it's a
    /// type→wire mapping the wire module must never link the daemon type
    /// for) so it lives in this daemon-side extension.
    var wire: PaneCapabilities {
        PaneCapabilities(
            touch: touch,
            key: key,
            text: text,
            button: button,
            rotate: rotate,
            crown: crown,
            accessibility: accessibility,
            location: location
        )
    }
}
