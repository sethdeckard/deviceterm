// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation
import os

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
    private enum HeldTouch: Equatable {
        case single(CGPoint)
        case edge(CGPoint, Int)
        case twoFinger(CGPoint, CGPoint)
    }

    /// How a release of the held contact went.
    private enum ReleaseOutcome {
        /// It completed in time, or there was nothing to release.
        case landed
        /// It timed out, now or on an earlier attempt. It was not cancelled and
        /// may still complete, so it is waited out rather than sent again.
        /// Carries the shared wait on that exact release, taken in the same
        /// step that found it pending, so nothing that runs before the caller
        /// resumes can swap in a wait for some other contact.
        case pending(Task<Bool, Never>)
        /// It failed outright and can be sent again.
        case failed

        var landed: Bool {
            if case .landed = self { return true }
            return false
        }
    }

    /// How one send went, as far as the bridge can tell.
    private enum SendResult {
        case completed
        case timedOut
        case failed
    }

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
    /// The bound panel's display UUID, written with `boundScreenID`.
    private var boundScreenUniqueID: String?
    /// Whether the bound panel spans the hinge, updated under `inputGate`
    /// alongside `boundScreenID` because the same lane callback writes both.
    private var boundPanelSpansHinge = false
    /// The hinge-spanning panel's pixel size, written with `boundScreenID`.
    private var spanningPanelWidth = 0
    private var spanningPanelHeight = 0
    /// Told whenever the bound panel moves. Set under `inputGate`, read there
    /// and called outside it, so a handler that hops to an actor never runs
    /// with the gate held.
    private var onBoundPanel: (@Sendable () -> Void)?
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
    // A synthetic edge swipe is tagged as a system gesture on either input
    // transport (the `IndigoHIDEdge` tag, or the HID daemon's gesture
    // trailer), so it reaches SpringBoard's recognizer directly.
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
    /// Whether HID sends are completing in time. Under `inputGate`.
    private var stallTracker = InputStallTracker()
    /// Told when the HID transport starts or stops stalling. Set under
    /// `inputGate`, called outside it.
    private var onInputStall: (@Sendable (InputStallTracker.Transition) -> Void)?
    /// Told when the transport starts or stops refusing input. Set under
    /// `inputGate`, called outside it.
    private var onInputRefusal: (@Sendable () -> Void)?
    /// The contact currently held down, if any (see `HeldTouch`). A down that
    /// timed out counts, since it may still land.
    private var heldTouch: HeldTouch?
    /// Bumped by every `hold`, so work begun for one contact can tell a newer
    /// one from it even when both went down at the same point.
    private var heldEpoch: UInt64 = 0
    /// The `heldEpoch` of a contact whose release timed out and hasn't been
    /// seen to complete, or nil. Such a release is still queued in
    /// SimulatorKit, so another would only queue behind it.
    private var pendingReleaseEpoch: UInt64?
    /// The one wait on that release's outcome. Every caller awaits the same
    /// task, so a failure can't reach one caller and a clean answer another.
    private var pendingSettle: Task<Bool, Never>?
    /// The panel `heldTouch` went down on, as the screen id its sends were
    /// addressed to. Meaningful only while a contact is held, and always
    /// written with it, so a fold mid-contact cannot split one contact across
    /// two panels.
    private var heldTouchScreenID: UInt32 = 0
    /// The held contact's panel's display UUID, written with
    /// `heldTouchScreenID`.
    private var heldTouchScreenUniqueID: String?
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
    /// Lays an ordinary Simulator flat, which neither the PurpleHID event nor
    /// the foldable's vendor payload can do.
    private let deviceCtlOrientation = DeviceCtlOrientation()
    /// Runs device-orientation reads, which block for a process run, off the
    /// input queue so a read never waits behind a gesture or holds one up.
    private let deviceOrientationQueue = BlockingWorkQueue(label: "com.deviceterm.sim.device-orientation")

    var inputTransportDescription: String? {
        guard let hidClient else { return nil }
        if hidClient.sendsThroughRemoteHID { return "dtuhidd" }
        return "indigo (\(hidClient.remoteHIDUnavailableReason ?? "reason unknown"))"
    }

    /// The HID client's hardware-keyboard mode, false with no client. The
    /// mode isn't kept anywhere else, so a backend built after a reboot or a
    /// reattach starts with it off, and the keyboard went away with the old
    /// client's connection.
    var simulatesHardwareKeyboard: Bool {
        hidClient?.simulatesHardwareKeyboard ?? false
    }

    init(
        udid: String,
        family: DeviceFamily,
        displayHandle: SimDisplayHandle,
        hidClient: SimHIDClient,
        purpleClient: SimPurpleHID
    ) {
        self.udid = udid
        self.hidClient = hidClient
        self.purpleClient = purpleClient
        var capabilities = DeviceBackendCapabilities.simulator(family: family)
        capabilities.fold = SimDisplayHandle.deviceHasMultiplePanels(udid: udid)
        self.capabilities = capabilities
        self.foldHelper = FoldHelperBuilder()
        let sink = FrameMetricsSink.make(
            baseDirectory: ProcessInfo.processInfo.environment[DeviceTermEnv.frameMetrics],
            deviceId: udid,
            log: { message in
                Logger(subsystem: DiagnosticLog.subsystem, category: "mirror").debug("\(message, privacy: .public)")
            }
        )
        let slotCount = ProcessInfo.processInfo.environment[DeviceTermEnv.surfacePoolSlots]
            .flatMap(Int.init) ?? Self.defaultPoolSlots
        let pool = LeasedSurfacePool(slotCount: slotCount, recordHoldAges: sink != nil)
        self.pool = pool
        // Only a two-panel device has a lit panel to read.
        let displays = DeviceCtlDisplays()
        let activePanelReader: (@Sendable () -> DeviceCtlDisplays.ActivePanel)? = capabilities.fold
            ? { @Sendable in displays.activePanel(deviceId: udid) }
            : nil
        self.display = SimDisplayLane(
            handle: displayHandle,
            pool: pool,
            blitter: SurfaceBlitter(cacheCapacity: slotCount + 1),
            instrumentation: sink.map { sink in
                SimFramePump.Instrumentation(
                    sink: sink,
                    signposter: OSSignposter(subsystem: DiagnosticLog.subsystem, category: "mirror")
                )
            },
            activePanelReader: activePanelReader
        )
    }

    /// The screen id a touch send is addressed to, or `0` for Indigo's fixed
    /// digitizer target.
    ///
    /// A device with two panels addresses contacts by screen id, because the
    /// fixed target reaches only one of them, and which one varies from boot to
    /// boot. A new contact goes to the panel the pane is bound to. A held one
    /// stays on the panel it went down on, so its moves and its release reach
    /// that panel even if a fold has moved the binding since. A single-panel
    /// device keeps the fixed target.
    static func touchScreenID(foldable: Bool, holding: Bool, heldOn: UInt32, bound: UInt32) -> UInt32 {
        touchPanel(foldable: foldable, holding: holding, heldOn: heldOn, bound: bound, unaddressed: 0)
    }

    /// The panel a touch send is addressed to, by whatever names a panel:
    /// `unaddressed` on a single-panel device, the held contact's panel while
    /// one is down, and the bound panel otherwise. One rule for every name,
    /// so a screen id and the display UUID beside it never name two panels.
    static func touchPanel<Panel>(
        foldable: Bool,
        holding: Bool,
        heldOn: Panel,
        bound: Panel,
        unaddressed: Panel
    ) -> Panel {
        guard foldable else { return unaddressed }
        return holding ? heldOn : bound
    }

    /// Whether `error` is the bridge giving up on a send's completion, as
    /// opposed to the send failing. Matched on domain and code rather than on
    /// the message text.
    static func isSendTimeout(_ error: Error) -> Bool {
        isHIDError(error, .sendTimeout)
    }

    /// Whether `error` is the bridge refusing a send because an earlier one
    /// hadn't completed. Nothing was sent.
    static func isTransportStalled(_ error: Error) -> Bool {
        isHIDError(error, .transportStalled)
    }

    private static func isHIDError(_ error: Error, _ code: CSBHIDClientError) -> Bool {
        let error = error as NSError
        return error.domain == CSBHIDClientErrorDomain && error.code == code.rawValue
    }

    // MARK: Ownership-transfer input fence

    func currentInputGeneration() -> UInt64 { inputGate.sync { inputGeneration } }

    func isInputGenerationCurrent(_ generation: UInt64) -> Bool {
        inputGate.sync { generation == inputGeneration }
    }

    func inputSubmissionCount() -> Int { inputGate.sync { inputSubmissions } }

    func inputStallCount() -> Int { inputGate.sync { stallTracker.episodes } }

    func observeInputStall(_ handler: @escaping @Sendable (InputStallTracker.Transition) -> Void) {
        inputGate.sync { onInputStall = handler }
    }

    func isInputRefusing() -> Bool { inputGate.sync { stallTracker.isRefusing } }

    func observeInputRefusal(_ handler: @escaping @Sendable () -> Void) {
        inputGate.sync { onInputRefusal = handler }
    }

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
        if let held, !sendTouchRelease(held, hid: hid).landed {
            allReleased = false
        }
        for usage in keys {
            if accepted("keyUp", { try hid.keyUp(keyCode: usage) }) {
                inputGate.sync { _ = heldKeys.remove(usage) }
            } else {
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
            guard accepted("releaseHardwareButton", { try hid.releaseHardwareButton(button.bridgeValue) }) else {
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
    /// A release that times out is not sent again: it is still queued, and a
    /// second one would queue behind it. With `settling`, this waits for every
    /// outstanding send to complete and reports whether they did cleanly,
    /// however long that takes. Without it, a pending release reports false at
    /// once.
    func releaseHeldContact(settling: Bool) async -> Bool {
        let outcome = await inputWorkQueue.run { [self] in
            releaseHeldContactSynchronously()
        }
        switch outcome {
        case .landed:
            return true

        case .failed:
            return false

        case let .pending(settle):
            guard settling else { return false }
            return await settle.value
        }
    }

    /// The shared wait on the release pending for `epoch`, started by the
    /// first caller that finds it. Call on `inputWorkQueue`, under
    /// `inputGate`.
    ///
    /// The settle observer is registered here rather than when the task first
    /// runs. The bridge hands a late failure to whichever observer is waiting
    /// when its sends drain, so an observer registered later could take a
    /// failure belonging to a newer contact's release and leave that
    /// release's own wait reporting success. Registered before this step
    /// yields the input queue, observation begins for this pending release.
    /// Later releases can still join the ledger and extend the wait until it
    /// drains.
    private func sharedSettle(epoch: UInt64) -> Task<Bool, Never> {
        if let pendingSettle { return pendingSettle }
        let (outcome, report) = AsyncStream<(any Error)?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if let hidClient {
            hidClient.whenSendsSettle { error in
                report.yield(error)
                report.finish()
            }
        } else {
            report.finish()
        }
        let task = Task { [self] in
            var settled = false
            var lateError: (any Error)?
            for await error in outcome {
                settled = true
                lateError = error
            }
            return reconcilePendingRelease(epoch: epoch, settled: settled, lateError: lateError)
        }
        pendingSettle = task
        return task
    }

    /// Reconcile the contact whose release was pending, once its sends have
    /// settled.
    ///
    /// Fenced on `epoch` rather than on the contact's value: a new down at the
    /// same point can complete before this runs, and clearing it would leave a
    /// finger down that nothing knows to release. A moved epoch reports false
    /// so the caller looks again at what is down now.
    private func reconcilePendingRelease(epoch: UInt64, settled: Bool, lateError: (any Error)?) -> Bool {
        inputGate.sync {
            guard settled, heldEpoch == epoch else { return false }
            pendingSettle = nil
            // Cleared either way: after a failure the next attempt sends
            // again, which is the one case worth sending again.
            pendingReleaseEpoch = nil
            guard lateError == nil else { return false }
            heldTouch = nil
            return true
        }
    }

    private func releaseHeldContactSynchronously() -> ReleaseOutcome {
        let (held, settle) = inputGate.sync { () -> (HeldTouch?, Task<Bool, Never>?) in
            guard let epoch = pendingReleaseEpoch else { return (heldTouch, nil) }
            return (heldTouch, sharedSettle(epoch: epoch))
        }
        guard let held else { return .landed }
        guard let hid = try? requireHID() else {
            // No HID client: the backend is torn down, so nothing is held on a
            // live device. Same reasoning as the quiesce.
            inputGate.sync {
                heldTouch = nil
                pendingReleaseEpoch = nil
            }
            return .landed
        }
        if let settle { return .pending(settle) }
        return sendTouchRelease(held, hid: hid)
    }

    /// Send the release matching `held`'s kind, ungated. Cleared only once the
    /// release completes, so a failed one is not silently forgotten.
    private func sendTouchRelease(_ held: HeldTouch, hid: SimHIDClient) -> ReleaseOutcome {
        let result: SendResult
        switch held {
        case let .single(point):
            result = attemptRelease("tapUp") { try hid.tapUp(at: point) }

        case let .edge(point, edge):
            result = attemptRelease("edgeTouchUp") { try hid.edgeTouchUp(at: point, edge: edge) }

        case let .twoFinger(finger1, finger2):
            result = attemptRelease("twoFingerUp") { try hid.twoFingerUp(f1: finger1, f2: finger2) }
        }
        switch result {
        case .completed:
            inputGate.sync {
                if heldTouch == held { heldTouch = nil }
                pendingReleaseEpoch = nil
            }
            return .landed

        case .timedOut:
            let settle = inputGate.sync { () -> Task<Bool, Never> in
                pendingReleaseEpoch = heldEpoch
                return sharedSettle(epoch: heldEpoch)
            }
            return .pending(settle)

        case .failed:
            return .failed
        }
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
    ///
    /// `operation` names a HID send for stall tracking. Rotation passes nil:
    /// it goes through Purple or the fold helper, so its outcome says nothing
    /// about the HID transport.
    @discardableResult
    private func gatedSend(
        _ generation: UInt64,
        _ operation: String?,
        counted: Bool = true,
        _ body: () throws -> Void
    ) throws -> Bool {
        guard inputGate.sync(execute: { generation == inputGeneration }) else {
            return false
        }
        if let operation {
            try trackingStall(operation, body)
        } else {
            try body()
        }
        if counted { inputGate.sync { inputSubmissions += 1 } }
        return true
    }

    /// Run an ungated release and report whether it returned without error,
    /// counting it when it did. The quiesce and held-contact paths send
    /// through here so the footprint count covers every such send, not only
    /// the ones a caller issued.
    private func accepted(_ operation: String, _ send: () throws -> Void) -> Bool {
        if case .completed = attemptRelease(operation, send) { return true }
        return false
    }

    /// `accepted`, telling a timeout apart from a failure.
    private func attemptRelease(_ operation: String, _ send: () throws -> Void) -> SendResult {
        do {
            try trackingStall(operation, send)
        } catch {
            return Self.isSendTimeout(error) ? .timedOut : .failed
        }
        inputGate.sync { inputSubmissions += 1 }
        return .completed
    }

    /// Run one HID send and fold its outcome into the stall tracker. Only a
    /// missed completion wait counts as a stall; any other error leaves the
    /// tracker as it was, because it says nothing about whether sends are
    /// completing.
    private func trackingStall(_ operation: String, _ send: () throws -> Void) throws {
        let transition: InputStallTracker.Transition?
        do {
            try send()
            transition = inputGate.sync {
                stallTracker.noteCompleted(operation: operation, at: .now)
            }
        } catch {
            if Self.isSendTimeout(error) {
                let (began, refusal) = inputGate.sync {
                    (stallTracker.noteTimeout(operation: operation, at: .now), stallTracker.beginRefusing())
                }
                reportStall(began)
                if refusal.began { reportRefusal() }
                watchForDrain(token: refusal.token)
            } else if Self.isTransportStalled(error) {
                inputGate.sync { stallTracker.noteRefused() }
            }
            throw error
        }
        reportStall(transition)
    }

    /// End the refusal once the client's sends drain, unless a later timeout
    /// has started a newer one by then.
    ///
    /// Watches for the drain without the settle API, which consumes the error
    /// a late send reported: taking it here would leave a recovery waiting on
    /// that release to hear success.
    private func watchForDrain(token: UInt64) {
        guard let hidClient else { return }
        hidClient.whenSendsDrain { [weak self] in
            guard let self else { return }
            let ended = inputGate.sync { stallTracker.noteDrained(token: token) }
            if ended { reportRefusal() }
        }
    }

    private func reportRefusal() {
        let observer = inputGate.sync { onInputRefusal }
        observer?()
    }

    private func reportStall(_ transition: InputStallTracker.Transition?) {
        guard let transition else { return }
        let observer = inputGate.sync { onInputStall }
        observer?(transition)
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
        display.observePanelChanges { [weak self] panel in
            self?.noteBoundPanel(panel)
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
    /// instead, where the client is owned. `requireHID` applies it to touch
    /// for the same reason.
    private func noteBoundPanel(_ panel: BoundPanel) {
        let observer = inputGate.sync { () -> (@Sendable () -> Void)? in
            boundScreenID = panel.screenID
            boundScreenUniqueID = panel.uniqueID
            boundPanelSpansHinge = panel.spansHinge
            spanningPanelWidth = panel.spanningPanelWidth
            spanningPanelHeight = panel.spanningPanelHeight
            return onBoundPanel
        }
        observer?()
    }

    /// Register `handler` and signal it once.
    ///
    /// The immediate call is what lets a caller register *after* the display
    /// has bootstrapped and still learn the current panel. The lane resolves
    /// the first binding inside the bootstrap, so a caller that only took
    /// future changes would sit on the default until the next fold.
    ///
    /// The stored binding is written before the signal goes out, so a reader
    /// answering this notice never sees a panel older than the one it names.
    func observeBoundPanel(_ handler: @escaping @Sendable () -> Void) {
        inputGate.sync { onBoundPanel = handler }
        handler()
    }

    func currentBoundPanel() -> BoundPanel {
        inputGate.sync {
            BoundPanel(
                screenID: boundScreenID,
                spansHinge: boundPanelSpansHinge,
                spanningPanelWidth: spanningPanelWidth,
                spanningPanelHeight: spanningPanelHeight,
                uniqueID: boundScreenUniqueID
            )
        }
    }

    func noteHingeMoved() { display.followFold() }

    func noteHingeFound() { display.lookForLitPanel() }

    func readDeviceOrientation() async -> Orientation? {
        guard capabilities.fold else { return nil }
        let udid = self.udid
        let reader = deviceCtlOrientation
        return await deviceOrientationQueue.run { reader.uprightOrientation(deviceId: udid) }
    }

    func stopFrames() { display.stopFrames() }

    func setFrameDemand(_ demanded: Bool) { display.setFrameDemand(demanded) }

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
            try runFoldHelper(
                helper,
                onDevice: udid,
                arguments: FoldHelperSource.hingeArguments(degrees: degrees),
                failure: "the hinge helper"
            )
        }
        // Without waiting for the hinge reader to see the new angle, which
        // can lag the helper by a read.
        noteHingeMoved()
    }

    /// Switch keys between the simulator's own keyboard and a registered
    /// one. Keys held at the switch are released first, on the keyboard
    /// holding them, since the other one never saw them go down. A release
    /// that fails stops the switch, rather than leaving that key held on the
    /// keyboard being left.
    func setSimulatesHardwareKeyboard(_ enabled: Bool, generation: UInt64) async throws {
        guard capabilities.hardwareKeyboard else { throw DeviceBackendError.unsupportedHardwareKeyboard }
        try await inputWorkQueue.run { [self] in
            guard inputGate.sync(execute: { generation == inputGeneration }) else {
                throw DeviceBackendError.notActive
            }
            let client = try requireHID()
            guard client.simulatesHardwareKeyboard != enabled else { return }
            for usage in inputGate.sync(execute: { heldKeys }) {
                try client.keyUp(keyCode: usage)
                inputGate.sync { _ = heldKeys.remove(usage) }
            }
            try client.simulateHardwareKeyboard(enabled)
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

    /// The HID client, with its contacts addressed to the right panel.
    ///
    /// Applied per send, as `requireAX` applies the panel to accessibility.
    /// See `touchScreenID(foldable:holding:heldOn:bound:)` for which panel.
    private func requireHID() throws -> SimHIDClient {
        guard let hidClient else { throw DeviceBackendError.notActive }
        let (screenID, uniqueID) = inputGate.sync {
            Self.touchPanel(
                foldable: capabilities.fold,
                holding: heldTouch != nil,
                heldOn: (heldTouchScreenID, heldTouchScreenUniqueID),
                bound: (boundScreenID, boundScreenUniqueID),
                unaddressed: (UInt32(0), String?.none)
            )
        }
        hidClient.touchScreenID = screenID
        hidClient.touchScreenUniqueID = uniqueID
        return hidClient
    }

    /// Try the simulator's HID daemon again when this backend's input still
    /// goes through Indigo and nothing is held down. Called before a new
    /// contact, so a contact and its release never straddle the switch.
    private func retryRemoteInputIfIdle() {
        guard let hidClient, !hidClient.sendsThroughRemoteHID else { return }
        guard inputGate.sync(execute: { heldTouch == nil && heldKeys.isEmpty }) else { return }
        hidClient.retryRemoteHIDIfDue()
        if hidClient.sendsThroughRemoteHID {
            DiagnosticLog.input.notice("input moved to dtuhidd: udid=\(self.udid, privacy: .private)")
        }
    }

    /// Record `touch` as held, on the panel the send that produced it went to.
    ///
    /// Reads the client's target rather than the binding, because the binding
    /// can move between the send and this record. Runs on `inputWorkQueue`,
    /// after `requireHID` set that target for the send.
    private func hold(_ touch: HeldTouch) {
        let screenID = hidClient?.touchScreenID ?? 0
        let uniqueID = hidClient?.touchScreenUniqueID
        inputGate.sync {
            heldTouch = touch
            heldTouchScreenID = screenID
            heldTouchScreenUniqueID = uniqueID
            // Sends go out in order, so any release still pending lands ahead
            // of this contact and no longer describes what is down. A settle
            // already waiting on it sees the epoch move and reconciles nothing.
            heldEpoch &+= 1
            pendingReleaseEpoch = nil
            pendingSettle = nil
        }
    }

    /// Send a touch that leaves `touch` down. It is recorded as held once the
    /// send completes, and also when it times out, because a timed-out send
    /// may still land.
    private func sendHolding(
        _ generation: UInt64,
        _ operation: String,
        _ touch: HeldTouch,
        _ body: () throws -> Void
    ) throws {
        retryRemoteInputIfIdle()
        do {
            if try gatedSend(generation, operation, body) { hold(touch) }
        } catch {
            if Self.isSendTimeout(error) { hold(touch) }
            throw error
        }
    }

    /// Send a touch release. The contact is cleared once it completes; a
    /// timeout leaves it held with its release marked pending, so recovery
    /// waits that release out instead of sending another.
    private func sendReleasing(
        _ generation: UInt64,
        _ operation: String,
        _ body: () throws -> Void
    ) throws {
        do {
            if try gatedSend(generation, operation, body) {
                inputGate.sync {
                    heldTouch = nil
                    pendingReleaseEpoch = nil
                }
            }
        } catch {
            if Self.isSendTimeout(error) { inputGate.sync { pendingReleaseEpoch = heldEpoch } }
            throw error
        }
    }

    func tapDown(at point: CGPoint, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            try sendHolding(generation, "tapDown", .single(point)) { try requireHID().tapDown(at: point) }
        }
    }

    func tapUp(at point: CGPoint, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            try sendReleasing(generation, "tapUp") { try requireHID().tapUp(at: point) }
        }
    }

    func edgeTouchDown(at point: CGPoint, edge: Int, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            try sendHolding(generation, "edgeTouchDown", .edge(point, edge)) {
                try requireHID().edgeTouchDown(at: point, edge: edge)
            }
        }
    }

    func edgeTouchMove(at point: CGPoint, edge: Int, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            try sendHolding(generation, "edgeTouchMove", .edge(point, edge)) {
                try requireHID().edgeTouchMove(at: point, edge: edge)
            }
        }
    }

    func edgeTouchUp(at point: CGPoint, edge: Int, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            try sendReleasing(generation, "edgeTouchUp") { try requireHID().edgeTouchUp(at: point, edge: edge) }
        }
    }

    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            try sendHolding(generation, "twoFingerDown", .twoFinger(finger1, finger2)) {
                try requireHID().twoFingerDown(f1: finger1, f2: finger2)
            }
        }
    }

    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) async throws {
        try await inputWorkQueue.run { [self] in
            try sendReleasing(generation, "twoFingerUp") { try requireHID().twoFingerUp(f1: finger1, f2: finger2) }
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
        if try gatedSend(generation, "keyDown", { try requireHID().keyDown(keyCode: hidUsage) }) {
            inputGate.sync { _ = heldKeys.insert(hidUsage) }
        }
    }

    private func keyUpSynchronously(hidUsage: UInt32, generation: UInt64) throws {
        if try gatedSend(generation, "keyUp", { try requireHID().keyUp(keyCode: hidUsage) }) {
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
            let sent = try gatedSend(generation, "pressHardwareButton") {
                try requireHID().pressHardwareButton(button.bridgeValue)
            }
            if sent { inputGate.sync { uncertainButtons.removeAll { $0 == button } } }
        } catch {
            inputGate.sync { if !uncertainButtons.contains(button) { uncertainButtons.append(button) } }
            throw error
        }
    }

    func rotateCrown(delta: Double, generation: UInt64) async throws {
        _ = try await inputWorkQueue.run { [self] in
            try gatedSend(generation, "rotateCrown") { try requireHID().rotateCrown(delta: delta) }
        }
    }

    // A cleared generation fence reports `.dispatched`, never confirmation.
    // Neither path carries a reply, so the coordinator waits for
    // `startDisplayOrientation` to observe the display reading this returns.
    //
    // A foldable rotates through the guest helper instead of the bridge's
    // GSEvent, which changes its device orientation without the UI following,
    // and reads a quarter turn off on the inner panel. Which panel that is
    // gets read once, before the send. A fold the daemon issues cancels a
    // pending rotation and holds new ones until a panel change is observed or
    // the settling timeout expires (`PaneCoordinator`).
    // A fold made outside DeviceTerm while a rotation waits can confirm it
    // falsely, because the fold moves the shared display reading before the
    // daemon sees the panel change.
    func rotate(
        target: RotationTarget,
        confirmedOrientation: Orientation?,
        generation: UInt64
    ) async throws -> BackendRotationOutcome {
        let foldable = capabilities.fold
        guard let resolution = FoldablePanelOrientation.resolve(
            target,
            confirmed: confirmedOrientation,
            onInnerPanel: foldable && currentBoundPanel().spansHinge
        ) else {
            return .confirmationUnsupported(target: nil)
        }
        let orientation = resolution.device
        let sent: Bool
        if foldable {
            let udid = self.udid
            let helper = self.foldHelper
            sent = try await inputWorkQueue.run { [self] in
                try gatedSend(generation, nil, counted: false) {
                    try runFoldHelper(
                        helper,
                        onDevice: udid,
                        arguments: FoldHelperSource.orientationArguments(orientation),
                        failure: "the orientation helper"
                    )
                }
            }
        } else {
            sent = try await inputWorkQueue.run { [self] in
                try gatedSend(generation, nil, counted: false) {
                    guard let purpleClient else { throw DeviceBackendError.notActive }
                    try purpleClient.rotate(to: orientation.bridgeValue)
                }
            }
        }
        return sent
            ? .dispatched(target: orientation, display: resolution.display)
            : .unavailable(target: orientation)
    }

    /// Lay the device face up or face down.
    ///
    /// A foldable takes the guest helper's orientation payload, as its
    /// rotations do. Nothing reports a foldable's flat orientation back
    /// promptly (`devicectl device orientation get` answers one request
    /// behind), so that path ends `.dispatched`. Any other Simulator ignores
    /// the payload and takes `devicectl device orientation set`, whose `get`
    /// reads the new value at once, so that path is confirmed or not.
    func setFlatOrientation(_ flat: FlatOrientation, generation: UInt64) async throws
        -> BackendFlatOrientationOutcome {
        let udid = self.udid
        if capabilities.fold {
            let helper = self.foldHelper
            let sent = try await inputWorkQueue.run { [self] in
                try gatedSend(generation, nil, counted: false) {
                    try runFoldHelper(
                        helper,
                        onDevice: udid,
                        arguments: FoldHelperSource.orientationArguments(flat),
                        failure: "the orientation helper"
                    )
                }
            }
            return sent ? .dispatched : .unavailable
        }
        let deviceCtl = self.deviceCtlOrientation
        let attempt = try await inputWorkQueue.run { [self] () throws -> (sent: Bool, reported: String?) in
            var reported: String?
            let sent = try gatedSend(generation, nil, counted: false) {
                reported = try deviceCtl.set(flat, deviceId: udid)
            }
            return (sent, reported)
        }
        guard attempt.sent else { return .unavailable }
        if attempt.reported == flat.rawValue { return .confirmed }
        return .unconfirmed(observed: attempt.reported.flatMap(FlatOrientation.init(rawValue:)))
    }

    /// Run the guest helper with `arguments` and fail unless it exits zero.
    /// `failure` names what it was asked to do, for the error.
    private func runFoldHelper(
        _ helper: FoldHelperBuilder,
        onDevice udid: String,
        arguments: [String],
        failure: String
    ) throws {
        let binary = try helper.helperBinary()
        var exitStatus: Int32 = -1
        try SimFoldControl.run(
            binaryAtPath: binary,
            onDevice: udid,
            arguments: arguments,
            exitStatus: &exitStatus
        )
        guard exitStatus == 0 else {
            throw DeviceBackendError.foldCommandFailed(message: "\(failure) exited \(exitStatus)")
        }
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
