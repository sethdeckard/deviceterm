// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation

/// `DeviceBackend` over the CoreSimulator bridge.
///
/// Wraps the display / HID / Purple handles acquired at pane-create
/// time and lazily acquires the accessibility client, caching a
/// permanent acquisition failure so a broken client is not retried
/// per call.
///
/// `@unchecked Sendable`: the bridge handles are non-Sendable. `SimDisplayLane`
/// serializes the display handle and everything tied to its lifetime,
/// `inputWorkQueue` serializes HID/Purple work, each pane's AX queue serializes
/// accessibility work, the owning coordinator uses location state, and
/// `inputGate` protects the small state shared across those domains.
final class SimDeviceBackend: DeviceBackend, @unchecked Sendable {
    /// A contact still held down (nil once lifted), tracked with its kind
    /// so a transfer releases it correctly. Updated under `inputGate` as
    /// each send lands.
    private enum HeldTouch {
        case single(CGPoint)
        case edge(CGPoint, Int)
        case twoFinger(CGPoint, CGPoint)
    }

    /// Consecutive failed acquires before one controlled pool recovery. The
    /// device path's figure, for the same reason: long enough that an ordinary
    /// stall rides through, short enough that a pool which stays unusable is
    /// caught in about two seconds at 60 Hz.
    private static let exhaustionRecoveryThreshold = 120
    private static let defaultPoolSlots = 6

    /// The CoreSimulator UDID: needed for the lazy AX-client lookup.
    private let udid: String
    /// The display handle and everything tied to its lifetime, behind one
    /// serial domain of its own.
    private let display: SimDisplayLane
    private var hidClient: SimHIDClient?
    private var purpleClient: SimPurpleHID?
    /// Lazily acquired on the first AX call; `axAcquisitionFailed`
    /// caches a permanent failure so a missing framework isn't
    /// re-probed every call. (See `accessibility` acquisition note in
    /// the bridge module.)
    private var axClient: SimAccessibility?
    private var axAcquisitionFailed = false
    /// The panel the display is mirroring, `0` until one is resolved. Held
    /// under `inputGate`: the display lane writes it, and every accessibility
    /// call reads it before touching the client.
    private var boundScreenID: UInt32 = 0
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

    /// Everything a sim supports, plus `fold` when this particular device
    /// has a second panel. Read at pane create, which is before the display
    /// bootstrap, so the panel count is asked of the device directly rather
    /// than taken from the bound display.
    let capabilities: DeviceBackendCapabilities
    // The simulator's synthetic HID carries the `IndigoHIDEdge` tag, so an
    // edge swipe reaches SpringBoard's system-gesture recognizer directly.
    let supportsSystemEdgeGesture = true
    let rotationConfirmationSupport = RotationConfirmationSupport.displayObservation

    // Ownership-transfer input fence. `inputWorkQueue` orders every simulator
    // send with transfer quiesce. A transfer bumps the generation there, and
    // the paced `SimInputSynthesis` gesture checks it before each later send.
    // `inputGate` protects short generation and held-state snapshots across
    // the queue, paced tasks, and the coordinator.
    /// SimulatorKit's HID completion API waits synchronously. This per-pane
    /// queue preserves bridge ordering without occupying a Swift
    /// cooperative-executor worker.
    private let inputWorkQueue = BlockingWorkQueue(
        label: "com.deviceterm.daemon.sim-input"
    )

    private let inputGate = DispatchQueue(label: "com.deviceterm.sim.input-gate")
    /// Slots the published frames are copied into, so a consumer holds a
    /// surface the daemon owns rather than the one CoreSimulator keeps writing.
    private let pool: LeasedSurfacePool
    /// Whether new lazy bridge work may begin. AX work reads this from its
    /// serial blocking queue while teardown writes it on the coordinator.
    private var backendActive = true
    private var inputGeneration: UInt64 = 1
    /// Sends the HID client returned without error, for the footprint sample.
    /// Not delivery: the transport reports success for a port the guest has
    /// stopped servicing.
    private var inputSubmissions = 0
    /// The contact currently held down, if any (see `HeldTouch`).
    private var heldTouch: HeldTouch?
    private var heldKeys: Set<UInt32> = []
    /// Hardware buttons whose composite press+release *failed*: the up may
    /// not have landed (down without up), and the sim sends the pair as one
    /// bridge call, so it can't be confirmed clean. Quiesce sends an up-only
    /// release for each (never a full re-press) to un-stick it, clearing on
    /// confirmation and blocking the transfer until then.
    private var uncertainButtons: [HardwareButton] = []

    /// Builds and caches the guest-side hinge program. Held per backend
    /// rather than shared, which costs nothing: the build is keyed on the
    /// source and toolchain, so a second backend finds the first one's
    /// binary already on disk.
    private let foldHelper: FoldHelperBuilder

    init(
        udid: String,
        displayHandle: SimDisplayHandle,
        hidClient: SimHIDClient,
        purpleClient: SimPurpleHID
    ) {
        self.udid = udid
        self.hidClient = hidClient
        self.purpleClient = purpleClient
        var capabilities = DeviceBackendCapabilities.simulator
        capabilities.fold = SimDisplayHandle.deviceHasMultiplePanels(udid: udid)
        self.capabilities = capabilities
        self.foldHelper = FoldHelperBuilder()
        let slotCount = ProcessInfo.processInfo.environment[DeviceTermEnv.surfacePoolSlots]
            .flatMap(Int.init) ?? Self.defaultPoolSlots
        let pool = LeasedSurfacePool(slotCount: slotCount)
        self.pool = pool
        self.display = SimDisplayLane(
            handle: displayHandle,
            pool: pool,
            recoveryThreshold: Self.exhaustionRecoveryThreshold
        )
    }

    /// Copy each surface from `surfaces` into a pooled slot and publish it.
    ///
    /// Separate from `startFrames` so the exhaustion policy is reachable
    /// without a live CoreSimulator display: the loop needs the stream and the
    /// pool, and nothing from the bridge.
    ///
    /// Unreleased subscription holds are one expected cause of sustained
    /// exhaustion; `acquire` also returns nil when an epoch rotation exceeds
    /// the quarantine budget or a slot allocation fails. The pump attempts one
    /// controlled recovery and fails the pane through `fail` on a second bout,
    /// whatever the cause. Failing is the point: it bounds what a pool that
    /// stopped yielding slots can cost the daemon, and the pane recovers by
    /// re-attaching.
    static func pumpFrames(
        surfaces: AsyncStream<RetainedSurface>,
        pool: LeasedSurfacePool,
        recoveryThreshold: Int,
        publish: @Sendable (PublishedSurface) -> Void,
        fail: @Sendable (String) -> Void
    ) async {
        var consecutiveDrops = 0
        for await source in surfaces {
            let dims = source.withRef { (IOSurfaceGetWidth($0), IOSurfaceGetHeight($0)) }
            guard let published = await pool.acquire(width: dims.0, height: dims.1) else {
                consecutiveDrops += 1
                if consecutiveDrops >= recoveryThreshold {
                    consecutiveDrops = 0
                    switch await pool.recoverFromExhaustion() {
                    case .recovered:
                        DiagnosticLog.attach.notice(
                            """
                            surface pool unavailable; recovery will retry on \
                            the next frame
                            """
                        )

                    case .exhausted:
                        fail("surface pool stayed unavailable after "
                            + "recovery; the mirror can't continue")
                        return
                    }
                }
                continue
            }
            consecutiveDrops = 0
            // CoreSimulator owns the source and keeps writing to it, so the
            // published frame is a copy into the pool slot rather than the live
            // alias. That is what the lease accounts for, and it also keeps the
            // consumer from reading a surface while it is being written.
            published.surface.withRef { destination in
                source.withRef { origin in
                    _ = SurfaceCopy.copy(from: origin, to: destination)
                }
            }
            publish(published)
        }
    }

    // MARK: Ownership-transfer input fence

    func currentInputGeneration() -> UInt64 { inputGate.sync { inputGeneration } }

    func isInputGenerationCurrent(_ generation: UInt64) -> Bool {
        inputGate.sync { generation == inputGeneration }
    }

    func inputSubmissionCount() -> Int { inputGate.sync { inputSubmissions } }

    func quiesceInputForTransfer() async -> Bool {
        await inputWorkQueue.run { [self] in
            quiesceInputForTransferSynchronously()
        }
    }

    private func quiesceInputForTransferSynchronously() -> Bool {
        // The surrounding `inputWorkQueue` waits out earlier sends. Bump the
        // generation before snapshotting held state so every later paced
        // gesture send is dropped as stale. Keep the held state until its
        // release actually lands so a failed release is not silently lost.
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
            if accepted({ try hid.tapUp(at: point) }) {
                inputGate.sync { heldTouch = nil }
            } else {
                allReleased = false
            }

        case let .edge(point, edge)?:
            if accepted({ try hid.edgeTouchUp(at: point, edge: edge) }) {
                inputGate.sync { heldTouch = nil }
            } else {
                allReleased = false
            }

        case let .twoFinger(finger1, finger2)?:
            if accepted({ try hid.twoFingerUp(f1: finger1, f2: finger2) }) {
                inputGate.sync { heldTouch = nil }
            } else {
                allReleased = false
            }

        case nil:
            break
        }
        for usage in keys {
            if accepted({ try hid.keyUp(keyCode: usage) }) { inputGate.sync { _ = heldKeys.remove(usage) } } else {
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
            guard accepted({ try hid.releaseHardwareButton(button.bridgeValue) }) else {
                allReleased = false
                continue
            }
            inputGate.sync { uncertainButtons.removeAll { $0 == button } }
        }
        return allReleased
    }

    /// Free a contact left down by a gesture that failed partway, without
    /// touching the input generation: nothing here is being transferred, and
    /// other verbs on this pane stay valid.
    ///
    /// Ungated for the same reason the quiesce releases ungated: the release is
    /// the coordinator's, not the failed gesture's, and the gesture's own
    /// generation may already be stale.
    ///
    func releaseHeldContact() async -> Bool {
        await inputWorkQueue.run { [self] in
            releaseHeldContactSynchronously()
        }
    }

    private func releaseHeldContactSynchronously() -> Bool {
        let held: HeldTouch? = inputGate.sync { heldTouch }
        guard let held else { return true }
        guard let hid = try? requireHID() else {
            // No HID client: the backend is torn down, so nothing is held on a
            // live device. Same reasoning as the quiesce.
            inputGate.sync { heldTouch = nil }
            return true
        }
        // Cleared only once the release actually lands, so a failed one is not
        // silently forgotten.
        switch held {
        case let .single(point):
            guard accepted({ try hid.tapUp(at: point) }) else { return false }

        case let .edge(point, edge):
            guard accepted({ try hid.edgeTouchUp(at: point, edge: edge) }) else { return false }

        case let .twoFinger(finger1, finger2):
            guard accepted({ try hid.twoFingerUp(f1: finger1, f2: finger2) }) else { return false }
        }
        inputGate.sync { heldTouch = nil }
        return true
    }

    func resumeInput() {
        // Fresh generation (ABA guard) so a stale gesture can never match.
        inputGate.sync { inputGeneration &+= 1 }
    }

    /// Run `body` only if `generation` is still current. Every caller executes
    /// on `inputWorkQueue`, and transfer quiesce joins that same serial order,
    /// so a generation bump cannot slip between this check and the send.
    /// `inputGate` protects the short cross-executor read without being held
    /// across SimulatorKit's completion wait.
    ///
    /// A send that completes without throwing increments
    /// `inputSubmissionCount()` unless `counted` is false. Rotation opts out
    /// because the coordinator checks its observed orientation separately.
    @discardableResult
    private func gatedSend(
        _ generation: UInt64,
        counted: Bool = true,
        _ body: () throws -> Void
    ) throws -> Bool {
        guard inputGate.sync(execute: { generation == inputGeneration }) else {
            return false
        }
        try body()
        if counted { inputGate.sync { inputSubmissions += 1 } }
        return true
    }

    /// Run an ungated release and report whether it returned without error,
    /// counting it when it did. The quiesce and held-contact paths send
    /// through here so the footprint count covers every such send, not only
    /// the ones a caller issued.
    private func accepted(_ send: () throws -> Void) -> Bool {
        guard (try? send()) != nil else { return false }
        inputGate.sync { inputSubmissions += 1 }
        return true
    }

    // MARK: Frames

    /// Publish leased copies of the display's surface.
    ///
    /// `onDisconnect` never fires: a sim doesn't disconnect, and one that shuts
    /// down is reported through CoreSimulator's own notification, which reaches
    /// `markPanesShutdown(forUDID:)`. `onFatal` does, on sustained pool
    /// exhaustion, which is how a pane whose pool stops yielding slots fails
    /// instead of growing the daemon without bound.
    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {
        try display.startFrames(onFrame: onFrame, onFatal: onFatal)
    }

    /// Batched onto the display lane, so none of it runs on the caller's actor.
    /// `onDisconnect` is unused: a sim doesn't disconnect, and one that shuts
    /// down is reported through CoreSimulator's own notification.
    func bootstrapDisplay(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void,
        onOrientation: @escaping @Sendable (Orientation) -> Void
    ) async throws -> DisplayBootstrap {
        // Accessibility hit-testing addresses a display, so it follows the
        // panel the display settles on. Registered before the bootstrap
        // because the bootstrap is what publishes the first binding.
        display.observePanelChanges { [weak self] screenID in
            self?.noteBoundPanel(screenID)
        }
        return try await display.bootstrap(
            onFrame: onFrame,
            onFatal: onFatal,
            onOrientation: onOrientation
        )
    }

    /// Record which panel the display is mirroring. Called from the display
    /// lane, for the first binding and every fold that moves it.
    ///
    /// Deliberately writes nothing but the stored id. The accessibility
    /// client belongs to the pane's accessibility queue, and reaching across
    /// to it from here would both race that queue's own acquisition and
    /// touch the client from a second domain; `requireAX` applies the value
    /// instead, where the client is owned.
    ///
    /// Input needs no equivalent: contacts carry a normalized ratio and reach
    /// the mirrored panel through Indigo's fixed digitizer target on a
    /// foldable as well as a single-panel device.
    private func noteBoundPanel(_ screenID: UInt32) {
        inputGate.sync { boundScreenID = screenID }
    }

    func stopFrames() { display.stopFrames() }

    // MARK: Lease forwarders (to the pool)

    func registerLeaseToken(_ token: UUID, connectionId: UInt64) async {
        await pool.registerToken(token, connectionId: connectionId)
    }

    func unregisterLeaseTokenIfUnused(_ token: UUID) async -> Bool {
        await pool.unregisterTokenIfUnused(token)
    }

    func releaseWatermark(token: UUID, epoch: UInt64, lowestHeld: UInt64, connectionId: UInt64) async {
        await pool.applyWatermark(
            token: token,
            epoch: epoch,
            lowestHeld: lowestHeld,
            connectionId: connectionId
        )
    }

    func drain(token: UUID) async {
        await pool.beginDrain(token)
    }

    func poolCounters() async -> SurfacePoolCounters? {
        await pool.snapshotCounters()
    }

    func orphan(token: UUID) async {
        await pool.orphan(token)
    }

    // MARK: Fold

    /// Drive the hinge by running the guest-side helper on the device.
    ///
    /// The helper has to run inside the simulator, so this is a spawn rather
    /// than a bridge call: the event reaches the hinge from a process that
    /// links the guest's IOKit. Building it is cached, so only the first fold
    /// after a source or toolchain change pays for a compile.
    ///
    /// Runs on `inputWorkQueue` with the rest of this backend's device work,
    /// so a fold cannot interleave with a gesture mid-flight, and re-checks
    /// `generation` once it gets there: the build can take a second on a cold
    /// cache, which is long enough for the pane to change hands in between.
    func fold(toDegrees degrees: Double, generation: UInt64) async throws {
        guard capabilities.fold else { throw DeviceBackendError.unsupportedFold }
        let udid = self.udid
        let helper = self.foldHelper
        try await inputWorkQueue.run { [self] in
            guard inputGate.sync(execute: { generation == inputGeneration }) else {
                throw DeviceBackendError.notActive
            }
            let binary = try helper.helperBinary()
            var exitStatus: Int32 = -1
            try SimFoldControl.run(
                binaryAtPath: binary,
                onDevice: udid,
                arguments: [String(degrees)],
                exitStatus: &exitStatus
            )
            guard exitStatus == 0 else {
                throw DeviceBackendError.foldCommandFailed(
                    message: "the hinge helper exited \(exitStatus)"
                )
            }
        }
    }

    func pixelDimensions() -> (Int?, Int?) { display.pixelDimensions() }

    // MARK: Display orientation

    func startDisplayOrientation(
        onChange: @escaping @Sendable (Orientation) -> Void
    ) -> Bool {
        display.startOrientation(onChange: onChange)
    }

    func stopDisplayOrientation() { display.stopOrientation() }

    func currentDisplayOrientation() -> Orientation? { display.currentOrientation() }

    // MARK: Touch / keyboard / buttons / crown

    private func requireHID() throws -> SimHIDClient {
        guard let hidClient else { throw DeviceBackendError.notActive }
        return hidClient
    }

    func tapDown(at point: CGPoint, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            if try gatedSend(generation, { try requireHID().tapDown(at: point) }) {
                inputGate.sync { heldTouch = .single(point) }
            }
        }
    }

    func tapUp(at point: CGPoint, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            if try gatedSend(generation, { try requireHID().tapUp(at: point) }) {
                inputGate.sync { heldTouch = nil }
            }
        }
    }

    func edgeTouchDown(at point: CGPoint, edge: Int, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            if try gatedSend(generation, { try requireHID().edgeTouchDown(at: point, edge: edge) }) {
                inputGate.sync { heldTouch = .edge(point, edge) }
            }
        }
    }

    func edgeTouchMove(at point: CGPoint, edge: Int, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            if try gatedSend(generation, { try requireHID().edgeTouchMove(at: point, edge: edge) }) {
                inputGate.sync { heldTouch = .edge(point, edge) }
            }
        }
    }

    func edgeTouchUp(at point: CGPoint, edge: Int, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            if try gatedSend(generation, { try requireHID().edgeTouchUp(at: point, edge: edge) }) {
                inputGate.sync { heldTouch = nil }
            }
        }
    }

    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            if try gatedSend(generation, { try requireHID().twoFingerDown(f1: finger1, f2: finger2) }) {
                inputGate.sync { heldTouch = .twoFinger(finger1, finger2) }
            }
        }
    }

    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            if try gatedSend(generation, { try requireHID().twoFingerUp(f1: finger1, f2: finger2) }) {
                inputGate.sync { heldTouch = nil }
            }
        }
    }

    func keyDown(hidUsage: UInt32, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            try keyDownSynchronously(hidUsage: hidUsage, generation: generation)
        }
    }

    func keyUp(hidUsage: UInt32, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            try keyUpSynchronously(hidUsage: hidUsage, generation: generation)
        }
    }

    func typeKeystrokes(_ keystrokes: [HIDKeystroke], generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            for keystroke in keystrokes {
                if keystroke.shift {
                    try keyDownSynchronously(
                        hidUsage: KeyboardInputMap.hidShift,
                        generation: generation
                    )
                    do {
                        try keyDownSynchronously(hidUsage: keystroke.usage, generation: generation)
                        try keyUpSynchronously(hidUsage: keystroke.usage, generation: generation)
                        try keyUpSynchronously(
                            hidUsage: KeyboardInputMap.hidShift,
                            generation: generation
                        )
                    } catch {
                        try? keyUpSynchronously(
                            hidUsage: KeyboardInputMap.hidShift,
                            generation: generation
                        )
                        throw error
                    }
                } else {
                    try keyDownSynchronously(hidUsage: keystroke.usage, generation: generation)
                    try keyUpSynchronously(hidUsage: keystroke.usage, generation: generation)
                }
            }
        }
    }

    private func keyDownSynchronously(hidUsage: UInt32, generation: UInt64) throws {
        if try gatedSend(generation, { try requireHID().keyDown(keyCode: hidUsage) }) {
            inputGate.sync { _ = heldKeys.insert(hidUsage) }
        }
    }

    private func keyUpSynchronously(hidUsage: UInt32, generation: UInt64) throws {
        if try gatedSend(generation, { try requireHID().keyUp(keyCode: hidUsage) }) {
            inputGate.sync { _ = heldKeys.remove(hidUsage) }
        }
    }

    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            try pressHardwareButtonSynchronously(button, generation: generation)
        }
    }

    private func pressHardwareButtonSynchronously(
        _ button: HardwareButton,
        generation: UInt64
    ) throws {
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

    func rotateCrown(delta: Double, generation: UInt64) async throws {
        _ = try await inputWorkQueue.run { [self] in
            try gatedSend(generation) { try requireHID().rotateCrown(delta: delta) }
        }
    }

    // A cleared generation fence reports `.dispatched`, never confirmation.
    // The bridge rotates with a one-way GSEvent that carries no reply, so the
    // coordinator waits for `startDisplayOrientation` to observe the target.
    func rotate(
        target: RotationTarget,
        confirmedOrientation: Orientation?,
        generation: UInt64
    ) async throws -> BackendRotationOutcome {
        let orientation: Orientation
        switch target {
        case let .absolute(value):
            orientation = value

        case let .relative(direction):
            guard let confirmedOrientation else {
                return .confirmationUnsupported(target: nil)
            }
            orientation = direction.applied(to: confirmedOrientation)
        }
        let sent = try await inputWorkQueue.run { [self] in
            try gatedSend(generation, counted: false) {
                guard let purpleClient else { throw DeviceBackendError.notActive }
                try purpleClient.rotate(to: orientation.bridgeValue)
            }
        }
        return sent ? .dispatched(target: orientation) : .unavailable(target: orientation)
    }

    // MARK: Accessibility

    func accessibilityFrontmostTree() throws -> [String: Any] {
        try requireAX().frontmostTree()
    }

    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any] {
        try requireAX().elementAtPoint(pixelPoint)
    }

    /// Resolve (or lazily acquire) the AX client. Returns the cached client for
    /// AX work admitted before teardown. Otherwise throws `.notActive` once new
    /// bridge work is disabled, and `.accessibilityUnavailable` (without
    /// retrying) once acquisition has permanently failed.
    private func requireAX() throws -> SimAccessibility {
        let client = try acquireAX()
        // Applied per call rather than when the panel moves. This queue owns
        // the client, so it is the only place allowed to write to it, and a
        // fold can land between two accessibility calls. Cheap: a stored
        // property, not a bridge round trip.
        client.displayID = inputGate.sync { boundScreenID }
        return client
    }

    private func acquireAX() throws -> SimAccessibility {
        if let axClient { return axClient }
        guard inputGate.sync(execute: { backendActive }) else {
            throw DeviceBackendError.notActive
        }
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
    ///
    /// The gate is `backendActive` rather than whether the display handle is
    /// still held. Asking the display lane means a `queue.sync` onto the
    /// serial queue its bridge calls run on, so a wedged display would block
    /// a location call, and with it the coordinator. `inputGate` answers
    /// without touching CoreSimulator. It also closes earlier: teardown
    /// disables new bridge work before it starts releasing the display, so a
    /// location acquisition can no longer be admitted alongside a shutdown
    /// already under way.
    private func requireLocation() throws -> SimLocation {
        if let locationClient { return locationClient }
        guard inputGate.sync(execute: { backendActive }) else {
            throw DeviceBackendError.notActive
        }
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

    /// Teardown that suspends rather than blocking, so a caller waiting on it
    /// (the bootstrap supervisor disposing an abandoned attempt) keeps serving
    /// other work while CoreSimulator takes its time.
    func shutdownBackendAsync() async {
        // Stop admitting lazy bridge work before releasing the display.
        inputGate.sync { backendActive = false }
        await display.shutdownAsync()
        clearLazyClientsAfterShutdown()
    }

    /// An AX call already queued before teardown owns this backend until it
    /// returns. Keep its client stable; the pane's AX queue clears it after all
    /// admitted reads finish.
    ///
    /// Location holds only a `SimDevice` reference and has no in-flight
    /// sequence to finish (each call is a single unpaced send), so unlike
    /// HID/Purple it drops with the display handle.
    private func clearLazyClientsAfterShutdown() {
        locationClient = nil
        cachedLocationScenarios = nil
    }

    func shutdownBackend() {
        // Stop admitting lazy bridge work before releasing the display.
        inputGate.sync { backendActive = false }
        // Stop the frame stream and drop the display handle immediately: the
        // IOSurface use-count must release so the kernel can reclaim it. The
        // run token retires first, so a publish already in flight from the pump
        // is dropped rather than reaching a pane that is going away.
        display.shutdown()
        clearLazyClientsAfterShutdown()
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

    /// Called on the pane's serial AX queue after previously admitted reads
    /// finish, so dropping the client unregisters its shared-delegate token
    /// without racing a bridge call.
    func releaseAccessibilityResources() {
        axClient = nil
    }
}
