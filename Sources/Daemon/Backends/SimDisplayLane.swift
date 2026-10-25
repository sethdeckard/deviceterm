// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation

/// The simulator display handle and everything whose lifetime is tied to it:
/// the frame run, its pump task, and the orientation observation.
///
/// The lane queue serializes display-handle lifecycle operations so starts,
/// stops, dimension reads, and orientation registration cannot race teardown.
/// Both the synchronous accessors and the async operations use that one queue,
/// which is why it is a bare `DispatchQueue` rather than a `BlockingWorkQueue`:
/// the serialization has to cover both, and that type offers no sync entry.
///
/// `frameGate` stays separate and deliberately small. Publish and fatal
/// callbacks run from the frame pump and check their run token under
/// `frameGate`, so they do not wait behind lane work. Retiring the token is on
/// `frameGate` alone for the same reason: teardown can fence callbacks without
/// first queueing behind whatever the lane is doing.
///
/// `@unchecked Sendable`: `SimDisplayHandle` is not Sendable, and every access
/// to it happens on `queue`. The `Locked` helpers assume they are already on
/// that queue, so none of them may hop back onto it and deadlock.
final class SimDisplayLane: @unchecked Sendable {
    /// What one pass of the wait for a rebound panel to light found.
    private enum LitRefreshPass {
        /// No lit frame is owed for the bound panel, so nothing was asked for.
        case notOwed
        /// The bound panel shows content, so the frame just asked for is lit.
        case content
        /// Still dark; ask again.
        case dark
        /// A newer fold or properties change arrived, so stop waiting.
        case superseded
    }

    private let queue = DispatchQueue(label: "com.deviceterm.sim.display-lane")
    /// Delivery queue for the bridge's orientation callbacks. Separate from the
    /// lane so an observation callback never lands on the lane's own queue.
    private let orientationQueue = DispatchQueue(label: "com.deviceterm.sim.display-orientation")
    // Fences frame/fatal callback eligibility against teardown. `startFrames`
    // captures the current `frameToken`; teardown bumps it (both under
    // `frameGate`). A callback fires only while its captured token is still
    // current, so no publish or fatal escapes after stop, with no
    // check-then-act window a bare cancellation check would leave.
    private let frameGate = DispatchQueue(label: "com.deviceterm.sim.frame-gate")
    private var frameToken: UInt64 = 0

    private var handle: SimDisplayHandle?
    private var frameTask: Task<Void, Never>?
    /// Hands surfaces from the bridge's callback queue to the copy pump.
    private var frameSignal: SimFrameSignal?
    private var frameCallbacks: (
        publish: @Sendable (PublishedSurface) -> Void,
        fail: @Sendable (String) -> Void
    )?
    /// The in-flight search for a panel swap, if a fold or a screen-properties
    /// change started one. Owned by `queue`, like the handle it drives.
    private var panelSwapTask: Task<Void, Never>?
    /// Bumped by each new search, by `stopOrientation()` and by shutdown, so a
    /// read a superseded search queued is skipped instead of spawning. Owned by
    /// `queue`.
    private var panelSwapGeneration: UInt64 = 0
    /// Whether a search following the active panel is running. A fold or
    /// properties change while it is only marks it dirty, rather than
    /// restarting it. Owned by `queue`.
    private var followingActivePanel = false
    /// A fold or properties change arrived since the follower's last read
    /// began. Owned by `queue`.
    private var activePanelDirty = false
    /// Bumped with every fold or properties change a search hears of, so a
    /// read can tell whether it began after the latest one. Owned by `queue`.
    private var panelChangeSerial: UInt64 = 0
    /// An orientation reported while a fold was being followed, kept back
    /// until the search has settled which panel it belongs to. Owned by
    /// `queue`.
    private var heldOrientation: Orientation?
    /// Where orientation changes go, kept so a held one can be let out later.
    /// Owned by `queue`.
    private var orientationSink: (@Sendable (Orientation) -> Void)?
    /// Looks for the lit panel again at `ActivePanelSearch.settleCheckSeconds`
    /// after the first bind. Owned by `queue`.
    private var settleTask: Task<Void, Never>?
    /// The bound panel was moved to before it had drawn, and no frame with
    /// content has been asked for since. Lane state rather than a search's, so
    /// a search that replaces another inherits it, and any of them discharges
    /// it once the panel lights. Owned by `queue`.
    private var litFrameOwed = false
    /// Told which panel the display is mirroring, whenever that changes.
    /// Owned by `queue`.
    private var onPanelChange: (@Sendable (BoundPanel) -> Void)?
    /// Stamps each frame-demand change for the pool's idle state, which is
    /// set from a task per change. Owned by `queue`.
    private var demandSerial: UInt64 = 0

    private let pool: LeasedSurfacePool
    /// Runs every pump's slot copy, one at a time, at interactive QoS.
    private let copyQueue = BlockingWorkQueue(
        label: "com.deviceterm.sim.surface-copy",
        qos: .userInteractive
    )
    /// Handed to every pump this lane starts; nil without Metal, which leaves
    /// every copy on `copyQueue`.
    private let blitter: SurfaceBlitter?
    /// Handed to every pump this lane starts; nil unless frame metrics are on.
    private let instrumentation: SimFramePump.Instrumentation?
    /// Reads which panel iOS has lit, for a two-panel device. Nil leaves panel
    /// swaps to the content search alone.
    private let activePanelReader: (@Sendable () -> DeviceCtlDisplays.ActivePanel)?
    /// Runs `activePanelReader`, which blocks for a process run, off both the
    /// lane's queue and the cooperative pool.
    private let activePanelQueue = BlockingWorkQueue(label: "com.deviceterm.sim.active-panel")

    init(
        handle: SimDisplayHandle,
        pool: LeasedSurfacePool,
        blitter: SurfaceBlitter? = nil,
        instrumentation: SimFramePump.Instrumentation? = nil,
        activePanelReader: (@Sendable () -> DeviceCtlDisplays.ActivePanel)? = nil
    ) {
        self.handle = handle
        self.pool = pool
        self.blitter = blitter
        self.instrumentation = instrumentation
        self.activePanelReader = activePanelReader
    }

    /// Read the bound panel's identity and shape in one trip, so a fold
    /// cannot land between the two reads.
    private static func boundPanel(of handle: SimDisplayHandle) -> BoundPanel {
        let spanning = handle.spanningPanelSize
        return BoundPanel(
            screenID: handle.boundScreenID,
            spansHinge: handle.boundPanelIsLargest,
            spanningPanelWidth: Int(spanning.width),
            spanningPanelHeight: Int(spanning.height),
            uniqueID: handle.boundScreenUniqueId
        )
    }

    // MARK: - Bootstrap

    /// Start frames, install orientation observation, and read the seed
    /// orientation and pixel dimensions, in one trip down the queue.
    ///
    /// One operation rather than four calls because each is a CoreSimulator
    /// round trip: batching them gives the caller a single suspension to fence
    /// and a single place to bound. Nothing here is cancellable, so a caller
    /// that gives up needs `DisplayBootstrapSupervisor` to account for the
    /// abandoned attempt.
    ///
    /// Throws only if frames cannot start. A display with no orientation source
    /// reports `observingOrientation: false` and leaves the pane usable.
    func bootstrap(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onOrientation: @escaping @Sendable (Orientation) -> Void
    ) async throws -> DisplayBootstrap {
        try await runOnQueue { [self] in
            try startFramesLocked(onFrame: onFrame, onFatal: onFatal)
            // The panel is resolved by the line above, so publish it here,
            // on this queue. A caller that read it afterwards and applied it
            // itself would be doing two unordered steps, and a fold landing
            // between them would be overwritten by the older snapshot.
            onPanelChange?(handle.map(Self.boundPanel(of:)) ?? BoundPanel(screenID: 0, spansHinge: false))
            if let handle, handle.hasMultiplePanels {
                DiagnosticLog.panel.notice("first bind: screen \(handle.boundScreenID, privacy: .public)")
            }
            let observing = startOrientationLocked(onChange: onOrientation)
            // The first binding is a guess on a two-panel device: the picker
            // reads content, and at boot neither panel may have drawn yet, so
            // it can land on the dark one. Search now as a fold would, and
            // again over the next minute, since a boot can move the lit panel
            // after that with no fold to prompt a look.
            searchForPanelSwap()
            startSettleChecksLocked()
            let dimensions = pixelDimensionsLocked()
            return DisplayBootstrap(
                pixelWidth: dimensions.0,
                pixelHeight: dimensions.1,
                seedOrientation: currentOrientationLocked(),
                observingOrientation: observing
            )
        }
    }

    /// Stop the frame stream and drop the handle, off the caller's executor.
    ///
    /// The run token retires *before* the wait, so a publish already in flight
    /// is fenced immediately rather than only once the queue drains. Retirement
    /// depends on this completing, so it is deliberately not fire-and-forget.
    func shutdownAsync() async {
        invalidateFrameRun()
        await runOnQueue { [self] in shutdownLocked() }
    }

    // MARK: - Frames

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void
    ) throws {
        try queue.sync { try startFramesLocked(onFrame: onFrame, onFatal: onFatal) }
    }

    func stopFrames() {
        invalidateFrameRun()
        queue.sync {
            invalidateFrameRun()
            handle?.stop()
            releaseFrameRunLocked()
        }
    }

    /// Enqueued synchronously by the coordinator, preserving demand order
    /// without blocking its actor on a CoreSimulator call.
    ///
    /// Losing demand also idles the pool, which frees its slots as their holds
    /// release; regaining it lets the pool grow back. Each change carries a
    /// serial taken here, on the queue, which prevents a late demand change
    /// from overriding a newer one.
    func setFrameDemand(_ demanded: Bool) {
        if !demanded { invalidateFrameRun() }
        queue.async { [self] in
            guard let handle, let callbacks = frameCallbacks else { return }
            demandSerial += 1
            let serial = demandSerial
            let pool = self.pool
            Task { await pool.setIdle(!demanded, serial: serial) }
            if demanded {
                if frameTask != nil {
                    frameSignal?.notify()
                    return
                }
                do {
                    try startFramesLocked(onFrame: callbacks.publish, onFatal: callbacks.fail)
                } catch {
                    callbacks.fail("could not resume simulator display: \(error)")
                }
            } else {
                invalidateFrameRun()
                handle.pauseFrames()
                releaseFrameRunLocked()
            }
        }
    }

    private func readFrame(token: UInt64) async -> RetainedSurface? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard frameGate.sync(execute: { token == frameToken }),
                    let surface = handle?.currentSurface() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: RetainedSurface(surface))
            }
        }
    }

    func pixelDimensions() -> (Int?, Int?) { queue.sync { pixelDimensionsLocked() } }

    // MARK: - Bound panel

    /// Observe which panel the display is mirroring, which accessibility
    /// needs because hit-testing addresses a display rather than whichever
    /// one is lit.
    ///
    /// `handler` runs on the lane queue for the binding the bootstrap
    /// resolves and again whenever a fold moves it, so the observer sees
    /// them in the order they happened and never has to read the panel back
    /// itself. Register before `bootstrap`, or the first one is missed.
    func observePanelChanges(_ handler: @escaping @Sendable (BoundPanel) -> Void) {
        queue.sync { onPanelChange = handler }
    }

    // MARK: - Display orientation

    func startOrientation(onChange: @escaping @Sendable (Orientation) -> Void) -> Bool {
        queue.sync { startOrientationLocked(onChange: onChange) }
    }

    func stopOrientation() {
        queue.sync {
            // Cancels whichever search is stored now. A callback already
            // running can still arm another one after this returns, and
            // shutdown is what cancels that.
            panelSwapTask?.cancel()
            panelSwapTask = nil
            settleTask?.cancel()
            settleTask = nil
            panelSwapGeneration &+= 1
            followingActivePanel = false
            activePanelDirty = false
            heldOrientation = nil
            orientationSink = nil
            handle?.stopOrientation()
        }
    }

    func currentOrientation() -> Orientation? { queue.sync { currentOrientationLocked() } }

    // MARK: - Lifecycle

    func shutdown() {
        invalidateFrameRun()
        queue.sync { shutdownLocked() }
    }

    /// Retire the current frame run so any publish or fatal still in flight from
    /// it is dropped. Serialised with the callbacks on `frameGate`, and
    /// deliberately not on `queue`: fencing must not wait for lane work.
    ///
    /// Teardown calls this twice, and both calls are needed. The first fences
    /// the run that exists now, without waiting for the lane. The second runs
    /// once teardown is ordered on the lane, because a start that won the queue
    /// in between installed a *newer* token that the first bump did not retire.
    /// Cancelling the pump task does not close that gap: cancellation is not a
    /// join, so a publish already in flight still checks the token.
    func invalidateFrameRun() {
        frameGate.sync { frameToken += 1 }
    }

    // MARK: - Queue-local work

    private func runOnQueue<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runOnQueue(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                operation()
                continuation.resume()
            }
        }
    }

    private func startFramesLocked(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void
    ) throws {
        guard let handle else { throw DeviceBackendError.notActive }
        let pool = self.pool
        let copyQueue = self.copyQueue
        let blitter = self.blitter
        let instrumentation = self.instrumentation
        frameCallbacks = (onFrame, onFatal)
        // Install a fresh run token; teardown bumps it to fence late callbacks.
        // Checked and invoked together under `frameGate`, so teardown and a
        // publish are mutually ordered with no window between them.
        let gate = frameGate
        let token = gate.sync {
            frameToken += 1
            return frameToken
        }
        let publish: @Sendable (PublishedSurface) -> Void = { [weak self] published in
            guard let self else { return }
            gate.sync { if token == self.frameToken { onFrame(published) } }
        }
        let fail: @Sendable (String) -> Void = { [weak self] reason in
            guard let self else { return }
            gate.sync { if token == self.frameToken { onFatal(reason) } }
        }
        releaseFrameRunLocked()
        let signal = SimFrameSignal()
        frameSignal = signal
        frameTask = Task { [weak self] in
            await SimFramePump(
                signal: signal,
                pool: pool,
                copyQueue: copyQueue,
                blitter: blitter,
                instrumentation: instrumentation,
                read: { [weak self] in await self?.readFrame(token: token) },
                publish: publish,
                fail: fail
            ).run()
            // Drop the cached textures so the slots an idle pool frees aren't
            // kept alive. This run has awaited its own last blit; a newer
            // run's in-flight blit keeps its textures, and its next blit
            // rebuilds the cache.
            blitter?.purge()
        }
        do {
            try handle.startInvalidations { surface in
                signal.notify(surface.map(RetainedSurface.init))
            }
            signal.notify()
        } catch {
            // The continuation and pump task are already installed above, so a
            // throw here would leave them running against a stream nothing
            // feeds. Retire this run before handing the error back.
            frameGate.sync { frameToken += 1 }
            releaseFrameRunLocked()
            throw error
        }
    }

    private func startOrientationLocked(
        onChange: @escaping @Sendable (Orientation) -> Void
    ) -> Bool {
        guard let handle else { return false }
        do {
            try handle.startOrientation(
                callback: { [weak self] raw in
                    let orientation = Orientation(displayValue: raw)
                    guard let self else {
                        if let orientation { onChange(orientation) }
                        return
                    }
                    if let orientation { self.reportOrientation(orientation) }
                    // A screen-properties change reaches here whenever it
                    // reads as a cardinal orientation, whether or not the
                    // orientation moved, and a fold can raise one. When it
                    // does, the rotation it reports is incidental.
                    self.searchForPanelSwap()
                },
                queue: orientationQueue
            )
            orientationSink = onChange
            return true
        } catch {
            // If orientation observation cannot start, leave the pane on its
            // last known orientation. Frames are unaffected, so the pane
            // remains usable.
            return false
        }
    }

    /// Pass an orientation change on, unless a fold is being followed.
    ///
    /// iOS reports one interface orientation for the whole device, read the
    /// same on either panel. Closing a landscape device turns it to portrait
    /// for the cover, and that arrives while the lane is still bound to the
    /// inner panel, so passing it straight on would draw the inner panel's
    /// last frame turned a quarter. Kept back, it lands with the panel it
    /// belongs to.
    private func reportOrientation(_ orientation: Orientation) {
        queue.async { [self] in
            guard activePanelReader != nil, followingActivePanel else {
                orientationSink?(orientation)
                return
            }
            heldOrientation = orientation
            DiagnosticLog.panel.notice("orientation held: \(orientation.rawValue, privacy: .public)")
        }
    }

    /// Let a held orientation out, on the lane's queue. With `serial`, only if
    /// no fold or properties change has arrived since the read it names
    /// began, since a later one may move the panel again.
    private func releaseHeldOrientationLocked(ifCurrent serial: UInt64? = nil) {
        if let serial, serial != panelChangeSerial { return }
        guard let orientation = heldOrientation else { return }
        heldOrientation = nil
        DiagnosticLog.panel.notice("orientation released: \(orientation.rawValue, privacy: .public)")
        orientationSink?(orientation)
    }

    /// Look for the lit panel again at each of
    /// `ActivePanelSearch.settleCheckSeconds`. On the lane's queue.
    private func startSettleChecksLocked() {
        guard let handle, handle.hasMultiplePanels else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            var elapsed: UInt64 = 0
            for seconds in ActivePanelSearch.settleCheckSeconds {
                try? await Task.sleep(nanoseconds: (seconds - elapsed) * 1_000_000_000)
                elapsed = seconds
                guard !Task.isCancelled, let self else { return }
                self.followFold()
            }
        }
    }

    // MARK: - Following a fold

    /// Look for the panel a fold lit, whoever made it.
    ///
    /// A fold's own screen-properties change can't be relied on for this: the
    /// callback is registered on the bound panel, and one going dark raises
    /// few of them, so a pane could sit on it for many seconds after iOS lit
    /// the other.
    func followFold() { searchForPanelSwap() }

    /// Start looking for the lit panel to move to another display candidate,
    /// which is what a fold does on a two-panel device.
    ///
    /// With an `activePanelReader`, the search asks it which panel iOS has lit
    /// and moves straight there, paced by `ActivePanelSearch`. That follows
    /// iOS's decision rather than the old panel's fade. Without one, or once a
    /// read fails, it falls back to `searchByContent()`. A device with one
    /// panel never searches. A running active-panel follower absorbs the
    /// change and reads again; a content search is replaced.
    ///
    /// After rebinding, an active frame run is replaced with a fresh signal,
    /// pump, and token.
    private func searchForPanelSwap() {
        queue.async { [self] in
            guard let handle, handle.hasMultiplePanels else { return }
            panelChangeSerial &+= 1
            if activePanelReader != nil, followingActivePanel {
                // A dragged hinge raises a change for every fold, faster than
                // one read completes. Restarting on each would discard every
                // read before it answered, so the running follower absorbs
                // the change and reads again instead.
                activePanelDirty = true
                return
            }
            panelSwapTask?.cancel()
            panelSwapGeneration &+= 1
            let generation = panelSwapGeneration
            let reader = activePanelReader
            followingActivePanel = reader != nil
            activePanelDirty = false
            panelSwapTask = Task { [weak self] in
                guard let self else { return }
                if let reader {
                    await self.followActivePanel(reader, generation: generation)
                } else {
                    await self.searchByContent()
                }
            }
        }
    }

    /// Follow the panel `reader` says is lit, a cycle at a time, going round
    /// again whenever a fold or properties change arrived during a cycle.
    private func followActivePanel(
        _ reader: @escaping @Sendable () -> DeviceCtlDisplays.ActivePanel,
        generation: UInt64
    ) async {
        while !Task.isCancelled {
            guard let fellBack = await followActivePanelOnce(reader, generation: generation) else { return }
            if fellBack {
                // Retire before searching by content, so the next change
                // starts a fresh follower that cancels this search.
                _ = await finishFollowing(generation: generation, force: true)
                await searchByContent()
                return
            }
            guard await finishFollowing(generation: generation, force: false) == false else { return }
        }
    }

    /// One cycle: read until the reader names another panel, then move there,
    /// or until `ActivePanelSearch` ends the cycle. True when it handed over to
    /// the content search, false when it ended on its own, nil when a stop
    /// superseded it.
    ///
    /// Every read that names the bound panel also waits for it to light, if
    /// a frame is still owed for it, since a newer change can cut a move's own
    /// wait short.
    private func followActivePanelOnce(
        _ reader: @escaping @Sendable () -> DeviceCtlDisplays.ActivePanel,
        generation: UInt64
    ) async -> Bool? {
        var reads = 0
        var budgetSerial: UInt64?
        while !Task.isCancelled {
            // Reads queue behind one another, and cancelling a task doesn't
            // take its read off the queue, so each checks it still belongs
            // to the current search before spawning anything. A read starting
            // now covers any change that marked the follower dirty. Nothing on
            // `queue` waits for this queue, so the sync can't deadlock.
            let read = await activePanelQueue.run { [weak self] () -> (DeviceCtlDisplays.ActivePanel, UInt64)? in
                guard let self else { return nil }
                let serial = self.queue.sync { () -> UInt64? in
                    guard self.panelSwapGeneration == generation else { return nil }
                    self.activePanelDirty = false
                    return self.panelChangeSerial
                }
                guard let serial else { return nil }
                return (reader(), serial)
            }
            guard let (reading, serial) = read, !Task.isCancelled else { return nil }
            // A change since the last read gets a full set of reads of its
            // own. iOS lights the new panel a moment after the fold, so a
            // fold landing just before the last read would otherwise get one
            // read, taken too early to see the swap.
            if serial != budgetSerial {
                budgetSerial = serial
                reads = 0
            }
            reads += 1
            let bound = await boundScreenID()
            let step = ActivePanelSearch.next(afterReads: reads, reading: reading, bound: bound)
            let readDescription = String(describing: reading)
            let stepDescription = String(describing: step)
            DiagnosticLog.panel.notice(
                """
                read \(reads, privacy: .public): \(readDescription, privacy: .public), \
                bound \(bound, privacy: .public) -> \(stepDescription, privacy: .public)
                """
            )
            switch step {
            case let .rebind(screenID):
                let moved = await rebind(toScreenID: screenID)
                DiagnosticLog.panel.notice(
                    "rebind to screen \(screenID, privacy: .public): \(moved ? "moved" : "failed", privacy: .public)"
                )
                if moved {
                    await refreshUntilLit(since: serial)
                    return false
                }

            case let .wait(nanoseconds):
                if reading == .panel(bound) {
                    await releaseHeldOrientation(ifCurrent: serial)
                    await refreshUntilLit(since: serial)
                }
                try? await Task.sleep(nanoseconds: nanoseconds)

            case .stop:
                await releaseHeldOrientation(ifCurrent: serial)
                await refreshUntilLit(since: serial)
                return false

            case .searchByContent:
                return true
            }
        }
        return nil
    }

    /// `releaseHeldOrientationLocked(ifCurrent:)`, from off the lane's queue.
    private func releaseHeldOrientation(ifCurrent serial: UInt64) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                releaseHeldOrientationLocked(ifCurrent: serial)
                continuation.resume()
            }
        }
    }

    /// End the follower unless a change arrived during its last cycle. True
    /// when it ended. `force` ends it regardless. A follower a stop already
    /// superseded ends too, without touching the flags the stop reset.
    private func finishFollowing(generation: UInt64, force: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard panelSwapGeneration == generation else {
                    continuation.resume(returning: true)
                    return
                }
                if !force, activePanelDirty {
                    activePanelDirty = false
                    continuation.resume(returning: false)
                    return
                }
                followingActivePanel = false
                activePanelDirty = false
                releaseHeldOrientationLocked()
                continuation.resume(returning: true)
            }
        }
    }

    /// Poll the bridge for a panel swap it can see in the framebuffers, paced
    /// by `PanelSwapCadence`.
    ///
    /// Only moves once the bound panel reads black, so it lags a swap by the
    /// old panel's fade. The fallback for a device whose lit panel can't be
    /// read any other way.
    ///
    /// While a lit frame is owed for the bound panel, each attempt that
    /// doesn't move asks for one: a panel that lights in place sends nothing
    /// on an idle device. The search only stops on its own once that panel
    /// shows content, so the frame is asked for first.
    private func searchByContent() async {
        DiagnosticLog.panel.notice("content search: start")
        var attempts = 0
        while !Task.isCancelled {
            let rebound = await rebindToLitPanel()
            attempts += 1
            if rebound {
                let screen = await boundScreenID()
                DiagnosticLog.panel.notice(
                    "content search: screen \(screen, privacy: .public) on attempt \(attempts, privacy: .public)"
                )
            } else if await requestFrame(since: nil) == .content {
                DiagnosticLog.panel.notice("content search: lit frame on attempt \(attempts, privacy: .public)")
            }
            // Sampled only once the quick phase is over, where it decides
            // whether to go on; before that the answer is ignored.
            let pending = !rebound && PanelSwapCadence.isPatient(afterAttempts: attempts)
                ? await swapStillPending()
                : true
            switch PanelSwapCadence.next(afterAttempts: attempts, rebound: rebound, swapPending: pending) {
            case .stop:
                DiagnosticLog.panel.notice("content search: stop after \(attempts, privacy: .public) attempts")
                return

            case let .wait(nanoseconds):
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    /// While a lit frame is owed for the bound panel, ask for a frame every
    /// `litRefreshIntervalNanoseconds` until it shows content, giving up after
    /// `litRefreshAttempts`. Stops early once a fold or properties change newer
    /// than `serial` arrives, leaving the follower to read again rather than
    /// wait out a panel the change may have darkened; the frame stays owed.
    ///
    /// A move made on the active flag lands before the new panel has drawn, so
    /// the frame it seeds is black, and an idle device raises no frame
    /// callback when the panel lights. The request made on the pass that sees
    /// content is the one that fetches the lit frame.
    private func refreshUntilLit(since serial: UInt64) async {
        for attempt in 1...ActivePanelSearch.litRefreshAttempts {
            guard !Task.isCancelled else { return }
            switch await requestFrame(since: serial) {
            case .notOwed:
                return

            case .superseded:
                DiagnosticLog.panel.notice("lit refresh: superseded on attempt \(attempt, privacy: .public)")
                return

            case .content:
                DiagnosticLog.panel.notice("lit refresh: content on attempt \(attempt, privacy: .public)")
                return

            case .dark:
                try? await Task.sleep(nanoseconds: ActivePanelSearch.litRefreshIntervalNanoseconds)
            }
        }
        let attempts = ActivePanelSearch.litRefreshAttempts
        DiagnosticLog.panel.notice("lit refresh: no content after \(attempts, privacy: .public)")
    }

    /// If a lit frame is owed, ask the running frame pump for one and say
    /// whether the bound panel shows content, settling the debt when it does,
    /// on the lane's own queue. A lane with no handle reports content. Asks
    /// for nothing once a change newer than `serial` has arrived; nil asks
    /// regardless.
    private func requestFrame(since serial: UInt64?) async -> LitRefreshPass {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard litFrameOwed else {
                    continuation.resume(returning: .notOwed)
                    return
                }
                if let serial, panelChangeSerial != serial {
                    continuation.resume(returning: .superseded)
                    return
                }
                frameSignal?.notify()
                let content = handle?.boundPanelShowsContent() ?? true
                if content { litFrameOwed = false }
                continuation.resume(returning: content ? .content : .dark)
            }
        }
    }

    /// The bound panel's screen id, on the lane's own queue. `0` once the lane
    /// has no handle.
    private func boundScreenID() async -> UInt32 {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: handle?.boundScreenID ?? 0)
            }
        }
    }

    /// Move the binding to the panel with `screenID`, on the lane's own queue.
    /// True when it moved.
    private func rebind(toScreenID screenID: UInt32) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let handle, handle.rebind(toScreenID: screenID) else {
                    continuation.resume(returning: false)
                    return
                }
                adoptReboundPanelLocked(handle, litFrameOwed: true)
                continuation.resume(returning: true)
            }
        }
    }

    /// Whether the bound panel shows no sampled content, on the lane's own
    /// queue. A panel that can't be sampled counts as pending too, since it
    /// can't show that no swap is under way. A lane with no handle has nothing
    /// left to follow, so it reports no swap pending.
    private func swapStillPending() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: handle.map { !$0.boundPanelShowsContent() } ?? false)
            }
        }
    }

    /// Ask the bridge to move onto the lit panel, on the lane's own queue.
    /// True when the bound panel actually changed.
    private func rebindToLitPanel() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let handle, handle.rebindToLitPanel() else {
                    continuation.resume(returning: false)
                    return
                }
                // Moved only because the panel already reads lit, so the
                // frame the move seeds has content.
                adoptReboundPanelLocked(handle, litFrameOwed: false)
                continuation.resume(returning: true)
            }
        }
    }

    /// Restart an active frame run on the panel `handle` has just moved to,
    /// and report the new panel. On the lane's queue. `litFrameOwed` says the
    /// panel may not have drawn yet, so a lit frame is still to be asked for.
    ///
    /// The observer is told from here rather than by the caller, so the new
    /// panel is reported under the same queue hop that moved the binding and
    /// cannot be read back stale.
    private func adoptReboundPanelLocked(_ handle: SimDisplayHandle, litFrameOwed: Bool) {
        self.litFrameOwed = litFrameOwed
        if frameTask != nil, let callbacks = frameCallbacks {
            invalidateFrameRun()
            do {
                try startFramesLocked(onFrame: callbacks.publish, onFatal: callbacks.fail)
            } catch {
                callbacks.fail("could not resume rebound simulator display: \(error)")
            }
        }
        onPanelChange?(Self.boundPanel(of: handle))
        // Read off the new panel, which supersedes anything held for the old
        // one. Its own registration seeds no orientation of its own.
        heldOrientation = nil
        if let orientation = currentOrientationLocked() {
            DiagnosticLog.panel.notice("orientation on rebind: \(orientation.rawValue, privacy: .public)")
            orientationSink?(orientation)
        }
    }

    private func pixelDimensionsLocked() -> (Int?, Int?) {
        guard let handle else { return (nil, nil) }
        let size = handle.displaySize
        guard size.width > 0, size.height > 0 else { return (nil, nil) }
        return (Int(size.width), Int(size.height))
    }

    private func currentOrientationLocked() -> Orientation? {
        guard let handle else { return nil }
        return Orientation(displayValue: handle.currentDisplayOrientation)
    }

    /// Stop the frame stream and drop the handle. The IOSurface use-count must
    /// release so the kernel can reclaim it.
    private func shutdownLocked() {
        invalidateFrameRun()
        panelSwapTask?.cancel()
        panelSwapTask = nil
        settleTask?.cancel()
        settleTask = nil
        panelSwapGeneration &+= 1
        followingActivePanel = false
        activePanelDirty = false
        heldOrientation = nil
        orientationSink = nil
        litFrameOwed = false
        // Unregisters orientation observation too: the coordinator fences its
        // pump locally and leaves this bridge call to teardown, which runs off
        // the caller's executor.
        handle?.stopOrientation()
        handle?.stop()
        handle = nil
        frameCallbacks = nil
        // Held by the lane and closing over the backend, so it goes with the
        // handle rather than outliving the thing it reports about.
        onPanelChange = nil
        releaseFrameRunLocked()
    }

    private func releaseFrameRunLocked() {
        frameSignal?.finish()
        frameSignal = nil
        frameTask?.cancel()
        frameTask = nil
    }
}
