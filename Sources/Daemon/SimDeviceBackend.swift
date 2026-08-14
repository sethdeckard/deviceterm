// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimDeviceBackend: `DeviceBackend` over the CoreSimulator bridge.
//
// Wraps the display / HID / Purple handles acquired at pane-create
// time and lazily acquires the accessibility client (caching a
// permanent failure) the way the coordinator's per-pane record used
// to. This is a faithful move of that logic behind the seam. No
// behavior changes, the bridge calls are identical.
//
// `@unchecked Sendable`: the bridge handles are non-Sendable, but only
// the owning `PaneCoordinator` actor ever touches a backend, and the
// display callback hops back into that actor before any state is read:
// the same invariant the record class relied on.

import CoreSimulatorBridge
import DaemonProtocol
import Foundation

final class SimDeviceBackend: DeviceBackend, @unchecked Sendable {
    /// A contact still held down (nil once lifted), tracked with its kind
    /// so a transfer releases it correctly. Updated under `inputGate` as
    /// each send lands.
    private enum HeldTouch {
        case single(CGPoint)
        case edge(CGPoint, Int)
        case twoFinger(CGPoint, CGPoint)
    }

    /// The CoreSimulator UDID: needed for the lazy AX-client lookup.
    private let udid: String
    private var displayHandle: SimDisplayHandle?
    private var hidClient: SimHIDClient?
    private var purpleClient: SimPurpleHID?
    /// Lazily acquired on the first AX call; `axAcquisitionFailed`
    /// caches a permanent failure so a missing framework isn't
    /// re-probed every call. (See `accessibility` acquisition note in
    /// the bridge module.)
    private var axClient: SimAccessibility?
    private var axAcquisitionFailed = false
    /// Lazily acquired on the first location call, with the same
    /// permanent-failure latch as the AX client.
    private var locationClient: SimLocation?
    /// First acquisition failure's message, latched so a retry throws the
    /// *same* typed error the original did rather than degrading to a
    /// different classification on the wire.
    private var locationAcquisitionFailure: String?
    /// Memoized scenario list. Only a *non-empty* result is cached:
    /// CoreSimulator vends none until the device has booted, and caching
    /// that empty answer would reject every scenario for the backend's
    /// remaining lifetime.
    private var cachedLocationScenarios: [String]?

    let capabilities = DeviceBackendCapabilities.simulator
    // The simulator's synthetic HID carries the `IndigoHIDEdge` tag, so an
    // edge swipe reaches SpringBoard's system-gesture recognizer directly.
    let supportsSystemEdgeGesture = true

    // Ownership-transfer input fence. The sim sends synchronously with no
    // downstream queue, so, unlike the device backend, there is nothing
    // to buffer-drop or barrier: a transfer just bumps the generation, and
    // the paced `SimInputSynthesis` gesture checks it before each send and
    // releases its held contact when it goes stale. `inputGate` (a
    // documented DispatchQueue) serialises the counter across the gesture's
    // off-actor task and the coordinator's quiesce. Witnesses live below,
    // after `init`.
    /// Delivery queue for display-orientation callbacks. Serial, so
    /// deliveries reach the coordinator in queue order.
    private let orientationQueue = DispatchQueue(label: "com.deviceterm.sim.display-orientation")

    private let inputGate = DispatchQueue(label: "com.deviceterm.sim.input-gate")
    private var inputGeneration: UInt64 = 1
    /// The contact currently held down, if any (see `HeldTouch`).
    private var heldTouch: HeldTouch?
    private var heldKeys: Set<UInt32> = []
    /// Hardware buttons whose composite press+release *failed*: the up may
    /// not have landed (down without up), and the sim sends the pair as one
    /// bridge call, so it can't be confirmed clean. Quiesce sends an up-only
    /// release for each (never a full re-press) to un-stick it, clearing on
    /// confirmation and blocking the transfer until then.
    private var uncertainButtons: [HardwareButton] = []

    init(
        udid: String,
        displayHandle: SimDisplayHandle,
        hidClient: SimHIDClient,
        purpleClient: SimPurpleHID
    ) {
        self.udid = udid
        self.displayHandle = displayHandle
        self.hidClient = hidClient
        self.purpleClient = purpleClient
    }

    // MARK: Ownership-transfer input fence

    func currentInputGeneration() -> UInt64 { inputGate.sync { inputGeneration } }

    func isInputGenerationCurrent(_ generation: UInt64) -> Bool {
        inputGate.sync { generation == inputGeneration }
    }

    // The protocol requires `async`; the sim's quiesce is synchronous (no
    // queue to drain), so there's nothing to await.
    // swiftlint:disable:next async_without_await
    func quiesceInputForTransfer() async -> Bool {
        // Bump the generation first: the `inputGate.sync` waits out any
        // in-flight gated send, and every subsequent gesture send is then
        // dropped as stale. Snapshot the held state *without clearing*: it
        // is cleared only once its release actually lands, so a failed
        // release isn't silently lost.
        let (held, keys): (HeldTouch?, Set<UInt32>) = inputGate.sync {
            inputGeneration &+= 1
            return (heldTouch, heldKeys)
        }
        guard let hid = try? requireHID() else {
            // No HID client: the backend is torn down, so nothing is held
            // on a live device. Clean.
            inputGate.sync { heldTouch = nil; heldKeys = [] }
            return true
        }
        // Release held state directly (ungated) so it lands even though the
        // generation moved: the coordinator owns release, not the paced
        // gesture. Matched to the held contact's kind; report whether every
        // release landed so the coordinator can abort a transfer that can't
        // be made input-clean.
        var allReleased = true
        switch held {
        case let .single(point)?:
            if (try? hid.tapUp(at: point)) != nil { inputGate.sync { heldTouch = nil } } else { allReleased = false }

        case let .edge(point, edge)?:
            if (try? hid.edgeTouchUp(at: point, edge: edge)) != nil {
                inputGate.sync { heldTouch = nil }
            } else {
                allReleased = false
            }

        case let .twoFinger(finger1, finger2)?:
            if (try? hid.twoFingerUp(f1: finger1, f2: finger2)) != nil {
                inputGate.sync { heldTouch = nil }
            } else {
                allReleased = false
            }

        case nil:
            break
        }
        for usage in keys {
            if (try? hid.keyUp(keyCode: usage)) != nil { inputGate.sync { _ = heldKeys.remove(usage) } } else {
                allReleased = false
            }
        }
        // For each button whose composite couldn't be confirmed, send an
        // **up-only** release, never a full press+release, which could fire
        // a fresh action if the original failed before `down` landed. This is
        // the safe recovery: it un-sticks a button stuck down without side
        // effects, so an adoption retry can succeed rather than wedging.
        // Clear on a confirmed release; else keep it uncertain and block.
        let buttons = inputGate.sync { uncertainButtons }
        for button in buttons {
            guard (try? hid.releaseHardwareButton(button.bridgeValue)) != nil else {
                allReleased = false
                continue
            }
            inputGate.sync { uncertainButtons.removeAll { $0 == button } }
        }
        return allReleased
    }

    func resumeInput() {
        // Fresh generation (ABA guard) so a stale gesture can never match.
        inputGate.sync { inputGeneration &+= 1 }
    }

    /// Run `body` (a bridge send plus its held-state update) under
    /// `inputGate`, but only if `generation` is still current, atomically
    /// dropping a send from an operation a transfer invalidated (the check
    /// and the send share one critical section, so a bump can't slip
    /// between them). `body` updates held state only after the send
    /// succeeds, so a failed send leaves the tracker untouched. Returns
    /// whether the send actually ran (false = dropped as stale).
    @discardableResult
    private func gatedSend(_ generation: UInt64, _ body: () throws -> Void) throws -> Bool {
        try inputGate.sync {
            guard generation == inputGeneration else { return false }
            try body()
            return true
        }
    }

    // MARK: Frames

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void
    ) throws {
        // A sim pane has no leased pool, so `onFatal` never fires.
        guard let displayHandle else { throw DeviceBackendError.notActive }
        // Wrap on the bridge's queue so the retain/use-count pairing
        // happens before the autoreleased source ref escapes. A sim frame
        // takes no lease: the surface is a live CoreSimulator alias the
        // daemon doesn't own, sampled in place at 60 Hz.
        try displayHandle.start { surfaceRef in
            guard let surfaceRef else { return }
            onFrame(PublishedSurface(owned: LeasedSurface(surface: RetainedSurface(surfaceRef)), lease: nil))
        }
    }

    func stopFrames() {
        displayHandle?.stop()
    }

    func pixelDimensions() -> (Int?, Int?) {
        guard let displayHandle else { return (nil, nil) }
        let size = displayHandle.displaySize
        guard size.width > 0, size.height > 0 else { return (nil, nil) }
        return (Int(size.width), Int(size.height))
    }

    // MARK: Display orientation

    func startDisplayOrientation(
        onChange: @escaping @Sendable (Orientation) -> Void
    ) -> Bool {
        guard let displayHandle else { return false }
        do {
            try displayHandle.startOrientation(
                callback: { raw in
                    guard let orientation = Orientation(displayValue: raw) else { return }
                    onChange(orientation)
                },
                queue: orientationQueue
            )
            return true
        } catch {
            // A display that vends no orientation source leaves the pane
            // on its last known orientation. Frames are unaffected, so
            // this degrades rather than failing the pane.
            return false
        }
    }

    func stopDisplayOrientation() {
        displayHandle?.stopOrientation()
    }

    func currentDisplayOrientation() -> Orientation? {
        guard let displayHandle else { return nil }
        return Orientation(displayValue: displayHandle.currentDisplayOrientation)
    }

    // MARK: Touch / keyboard / buttons / crown

    private func requireHID() throws -> SimHIDClient {
        guard let hidClient else { throw DeviceBackendError.notActive }
        return hidClient
    }

    func tapDown(at point: CGPoint, generation: UInt64) throws {
        try gatedSend(generation) {
            try requireHID().tapDown(at: point)
            heldTouch = .single(point)
        }
    }

    func tapUp(at point: CGPoint, generation: UInt64) throws {
        try gatedSend(generation) {
            try requireHID().tapUp(at: point)
            heldTouch = nil
        }
    }

    func edgeTouchDown(at point: CGPoint, edge: Int, generation: UInt64) throws {
        try gatedSend(generation) {
            try requireHID().edgeTouchDown(at: point, edge: edge)
            heldTouch = .edge(point, edge)
        }
    }

    func edgeTouchMove(at point: CGPoint, edge: Int, generation: UInt64) throws {
        try gatedSend(generation) {
            try requireHID().edgeTouchMove(at: point, edge: edge)
            heldTouch = .edge(point, edge)
        }
    }

    func edgeTouchUp(at point: CGPoint, edge: Int, generation: UInt64) throws {
        try gatedSend(generation) {
            try requireHID().edgeTouchUp(at: point, edge: edge)
            heldTouch = nil
        }
    }

    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {
        try gatedSend(generation) {
            try requireHID().twoFingerDown(f1: finger1, f2: finger2)
            heldTouch = .twoFinger(finger1, finger2)
        }
    }

    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {
        try gatedSend(generation) {
            try requireHID().twoFingerUp(f1: finger1, f2: finger2)
            heldTouch = nil
        }
    }

    func keyDown(hidUsage: UInt32, generation: UInt64) throws {
        try gatedSend(generation) {
            try requireHID().keyDown(keyCode: hidUsage)
            heldKeys.insert(hidUsage)
        }
    }

    func keyUp(hidUsage: UInt32, generation: UInt64) throws {
        try gatedSend(generation) {
            try requireHID().keyUp(keyCode: hidUsage)
            heldKeys.remove(hidUsage)
        }
    }

    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) throws {
        // Self-releasing when it succeeds (press+release inside the bridge
        // call). But that composite can partially land, down without up,
        // and the sim can't confirm it, so on failure record it as uncertain.
        // A later *confirmed* press+release of the same control ends with the
        // button up, so it clears the uncertainty (and releases a stuck
        // button). Otherwise the transfer quiesce clears it with an up-only
        // release (never a replayed composite, which would fire a fresh
        // Home/Lock/Siri if the original failed before `down` landed); only a
        // *failed* up-only release keeps the button uncertain and blocks the
        // transfer.
        do {
            let sent = try gatedSend(generation) { try requireHID().pressHardwareButton(button.bridgeValue) }
            if sent { inputGate.sync { uncertainButtons.removeAll { $0 == button } } }
        } catch {
            inputGate.sync { if !uncertainButtons.contains(button) { uncertainButtons.append(button) } }
            throw error
        }
    }

    func rotateCrown(delta: Double, generation: UInt64) throws {
        try gatedSend(generation) { try requireHID().rotateCrown(delta: delta) }
    }

    // Reports only that the send cleared the generation fence. The bridge
    // rotates with a one-way GSEvent that carries no reply, so nothing here
    // can confirm the device moved, let alone that the display followed;
    // `true` means "sent, not dropped as stale" and no more. Presentation
    // comes from `startDisplayOrientation` instead, which does observe.
    // No async work: see the protocol's async signature.
    // swiftlint:disable:next async_without_await
    func rotate(to orientation: Orientation, generation: UInt64) async throws -> Bool {
        try gatedSend(generation) {
            guard let purpleClient else { throw DeviceBackendError.notActive }
            try purpleClient.rotate(to: orientation.bridgeValue)
        }
    }

    // MARK: Accessibility

    func accessibilityFrontmostTree() throws -> [String: Any] {
        try requireAX().frontmostTree()
    }

    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any] {
        try requireAX().elementAtPoint(pixelPoint)
    }

    /// Resolve (or lazily acquire) the AX client. Throws `.notActive`
    /// if the backend has been torn down, and `.accessibilityUnavailable`
    /// (without retrying) once acquisition has permanently failed.
    private func requireAX() throws -> SimAccessibility {
        if let axClient { return axClient }
        // The handles are released together on shutdown; a missing
        // display handle is the canonical "no longer active" signal.
        guard displayHandle != nil else { throw DeviceBackendError.notActive }
        if axAcquisitionFailed {
            throw DeviceBackendError.accessibilityUnavailable(
                message: "AccessibilityPlatformTranslation unavailable on this host"
            )
        }
        do {
            let client = try SimAccessibility.client(forUDID: udid)
            axClient = client
            return client
        } catch {
            axAcquisitionFailed = true
            throw DeviceBackendError.accessibilityUnavailable(
                message: "AccessibilityPlatformTranslation unavailable: \(BridgeMessage.unwrap(error))"
            )
        }
    }

    // MARK: Location simulation

    func setSimulatedLocation(latitude: Double, longitude: Double, generation: UInt64) throws {
        let client = try requireLocation()
        try gateLocation(generation) {
            try client.setCoordinate(latitude: latitude, longitude: longitude)
        }
    }

    func setSimulatedLocationScenario(_ name: String, generation: UInt64) throws {
        let client = try requireLocation()
        // CoreSimulator accepts an unknown scenario name without
        // changing location. Validate it against the available scenarios
        // before calling the setter; see `SimLocation.h`.
        let known = try scenarios(from: client)
        guard known.contains(name) else {
            throw DeviceBackendError.unknownLocationScenario(name: name)
        }
        try gateLocation(generation) { try client.setScenario(name) }
    }

    func startSimulatedLocationRoute(_ spec: RouteSpec, generation: UInt64) throws {
        let client = try requireLocation()
        // The wire shape and the selectors' shape differ; `SimRouteCall`
        // is the translation, kept pure so the flat alternating
        // waypoint order is unit-testable without a booted sim.
        let call = SimRouteCall(spec)
        try gateLocation(generation) {
            switch call.cadence {
            case let .distance(meters):
                try client.startRoute(
                    distance: meters,
                    speed: call.speed,
                    waypoints: call.waypoints
                )

            case let .interval(seconds):
                try client.startRoute(
                    interval: seconds,
                    speed: call.speed,
                    waypoints: call.waypoints
                )
            }
        }
    }

    func clearSimulatedLocation(generation: UInt64) throws {
        let client = try requireLocation()
        try gateLocation(generation) { try client.clear() }
    }

    /// Run a location mutation only if `generation` is still current,
    /// checked atomically with the send under `inputGate` exactly as
    /// `gatedSend` does for input. The sim's bridge calls are
    /// synchronous, so there is no suspension for a transfer to
    /// interleave with once we're inside the gate; a command admitted
    /// before a transfer and invalidated by it is dropped as
    /// `.notActive`.
    private func gateLocation(_ generation: UInt64, _ body: () throws -> Void) throws {
        try inputGate.sync {
            guard generation == inputGeneration else {
                throw DeviceBackendError.notActive
            }
            try body()
        }
    }

    func availableLocationScenarios() throws -> [String] {
        try scenarios(from: requireLocation())
    }

    /// Scenario list, memoized once non-empty.
    private func scenarios(from client: SimLocation) throws -> [String] {
        if let cachedLocationScenarios { return cachedLocationScenarios }
        let fetched = try client.availableScenarios()
        if !fetched.isEmpty { cachedLocationScenarios = fetched }
        return fetched
    }

    /// Resolve (or lazily acquire) the location client, mirroring
    /// `requireAX()`: `.notActive` once the backend is torn down, and a
    /// latched failure so a broken acquisition isn't re-probed per call.
    private func requireLocation() throws -> SimLocation {
        if let locationClient { return locationClient }
        guard displayHandle != nil else { throw DeviceBackendError.notActive }
        if let locationAcquisitionFailure {
            throw DeviceBackendError.locationUnavailable(message: locationAcquisitionFailure)
        }
        do {
            let client = try SimLocation.client(forUDID: udid)
            locationClient = client
            return client
        } catch {
            let message = BridgeMessage.unwrap(error)
            locationAcquisitionFailure = message
            throw DeviceBackendError.locationUnavailable(message: message)
        }
    }

    // MARK: Lifecycle

    func shutdownBackend() {
        // Stop the frame stream and drop the display + AX handles
        // immediately: the IOSurface use-count must release so the
        // kernel can reclaim the surface, and the AX delegate
        // registration should drop promptly.
        displayHandle?.stop()
        displayHandle = nil
        axClient = nil
        // Location holds only a `SimDevice` reference and has no
        // in-flight sequence to finish (each call is a single unpaced
        // send), so unlike HID/Purple it drops with the display handle.
        locationClient = nil
        cachedLocationScenarios = nil
        // HID + Purple are deliberately NOT cleared here. A long-running
        // input call (swipe / pinch / longPress / crown) captures this
        // backend before its first `await`; if a concurrent
        // close/shutdown races during an inter-step sleep, the gesture
        // must still complete against the same HID client: exactly as
        // it did before the backend seam, when the coordinator captured
        // the concrete `SimHIDClient` as a local. New input is already
        // gated by the coordinator niling `record.backend` (callers get
        // `paneNotActive`), so we don't need to invalidate these to
        // reject post-shutdown input. They release when this backend
        // deallocs: immediately in the common case, or once the
        // in-flight gesture's captured reference drops.
    }
}
