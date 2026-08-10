// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimulatorPaneViewModel: presentation state + daemon I/O for one
// sim pane, extracted from SimulatorPaneViewController.
// `@Observable` so the thin view controller re-renders via
// `observe()`; pure state transitions go through SimPaneReducer.
// Owns the pane subscription Task and the IOSurface lifetime.
//
// Input maps to one-shot RPCs against the daemon's pane.input.* surface:
// click/drag streams live `pane.input.touch` down/move/up events,
// a pinch/rotate → pane.input.pinch with from/to f1/f2. Keyboard sends
// raw NSEvent.keyCode (kVK); the daemon owns the kVK→USB-HID translation.
//
// Surface lifecycle: surfaces arrive from the daemon over XPC as
// `(SurfaceChangedEvent, IOSurfaceRef?)` pairs through the
// `PaneSubscribing` role surface. The model stores the ref directly,
// with no `IOSurfaceLookupFromXPCObject` hop and no per-frame
// mirror-surface indirection. The first surface that resolves marks the pane as
// rendering; subsequent surfaces replace it in place.

import DaemonProtocol
import IOSurface
import Observation

@MainActor
@Observable
final class SimulatorPaneViewModel {
    private enum KeyInput: Sendable {
        case down(UInt16)
        // swiftlint:disable:next identifier_name
        case up(UInt16)
    }

    private static let surfaceCoalesceIntervalNs: UInt64 = 16_000_000
    /// Default backoff before resubscribing after the daemon connection
    /// drops mid-stream. Keeps a flapping connection from busy-looping.
    /// Overridable per-instance (tests inject a tiny value).
    private static let defaultReconnectBackoffNs: UInt64 = 500_000_000
    /// Live-touch keepalive re-report cadence (~30 Hz). Faster than
    /// necessary risks redundant sends; slower than a couple frames lets
    /// the OS see a stutter. 33ms sits comfortably between.
    private static let touchKeepaliveIntervalNs: UInt64 = 33 * 1_000_000
    /// Sub-pixel offset applied (alternating sign) to each keepalive
    /// resend so the point differs frame-to-frame, because an identical resend
    /// stalls the sim's synchronous HID completion semaphore. Below the
    /// recognizer's movement threshold, so the finger reads as still.
    private static let touchKeepaliveJitter: CGFloat = 0.001

    let paneId: String
    let udid: String
    let displayName: String
    /// Coarse device family (`watch`/`phone`/`pad`/`tv`/`unknown`) from
    /// the daemon's attach response. Drives watch-aware pane sizing.
    let family: String
    /// Per-pane device-control capabilities from the daemon's attach
    /// response. A CoreSimulator pane reports everything; a physical
    /// device a subset (no crown/AX). The VM gates the verbs
    /// that differ on these so it can back any pane kind unchanged. An
    /// older daemon omits the block → `.simulator` (historical
    /// all-enabled behavior).
    let capabilities: PaneCapabilities

    private(set) var state: SimulatorPaneState = .booting
    /// Latest sequence number from `surface.changed`. Tracked so the
    /// view can correlate against the surface payload that arrived
    /// alongside it (the daemon ships them as an atomic pair on the
    /// XPC connection).
    private(set) var currentSequence: UInt64?
    /// The lease on the surface the view renders. Nil until the first pair
    /// arrives; replaced in place as the daemon yields new frames. A leased
    /// device frame's lease holds a pool slot until it (and every command
    /// buffer that sampled it) is released. An unleased frame (every
    /// simulator frame, and every device frame under the kill switch)
    /// carries a lease that holds nothing.
    private(set) var currentSurface: SurfaceLease?
    /// The sequence of `currentSurface`, advanced only when a non-nil
    /// surface is accepted, unlike `currentSequence` which also advances on
    /// a JSON-only frame whose side-band surface was missing. The trace path
    /// pairs the rendered surface with this so a skipped frame can't
    /// mislabel the one still onscreen.
    private(set) var currentSurfaceSequence: UInt64?
    var supportsLiveTouchInput: Bool { daemonClient.supportsLiveTouchInput }
    var supportsMultitouchInput: Bool { daemonClient.supportsMultitouchInput }
    /// Tracked device orientation. Advanced optimistically by
    /// `rotate(to:)` / the relative `rotateLeft/Right` helpers, and
    /// authoritatively by the daemon's `orientation.changed` pane event
    /// (`pane.subscribe`), so a rotation from outside this VM (e.g.
    /// `deviceterm rotate <orientation>`) keeps this in sync instead of
    /// drifting from the device. Defaults to `.portrait` (iOS sims boot
    /// portrait). Drives the render counter-rotation and input mapping,
    /// and derives the next orientation for the relative Rotate Left/Right
    /// menu items.
    private(set) var currentOrientation: Orientation = .portrait

    // Infrastructure, not observable state. Kept out of the registrar so
    // changes don't trigger renders and `deinit` can touch the task.
    @ObservationIgnored private let daemonClient: any PaneControlling & PaneSubscribing
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSurfaceUpdate: (
        sequence: UInt64,
        lease: SurfaceLease?
    )?
    @ObservationIgnored private var surfaceApplyTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTouchMove: CGPoint?
    @ObservationIgnored private var touchMoveInFlight = false
    /// Live-touch keepalive: re-report a held-but-stationary finger so
    /// the OS sees continuous contact (the dwell the App Switcher /
    /// Control Center recognizers need), not a silent gap once
    /// `mouseDragged` stops firing. Tracks the last reported point, a
    /// "moved this tick" flag, and the repeating task.
    @ObservationIgnored private var liveTouchHeld = false
    @ObservationIgnored private var lastLiveTouchPoint: CGPoint = .zero
    @ObservationIgnored private var liveTouchMovedSinceTick = false
    @ObservationIgnored private var touchKeepaliveTask: Task<Void, Never>?
    /// Non-nil for the lifetime of a live drag that began in the displayed
    /// bottom-edge band: the `IndigoHIDEdge` value tagging every contact
    /// (down/move/keepalive/lift) so the drag drives SpringBoard's system
    /// gesture (App Switcher) instead of scrolling the foreground app.
    /// Latched at `.down`, cleared at `.lift`. `nil` → the ordinary
    /// plain-touch path.
    @ObservationIgnored private var activeTouchEdge: Int?
    @ObservationIgnored private var pendingMultitouchMove: (finger1: CGPoint, finger2: CGPoint)?
    @ObservationIgnored private var multitouchMoveInFlight = false
    /// AppKit gives key events in order, but dispatching every one in an
    /// independent Task can reverse a quick down/up pair once the RPCs suspend.
    /// Feed them through one stream so the daemon (and its delta-less HID
    /// keyboard state) observes the same order AppKit did.
    @ObservationIgnored private let keyInputStream: AsyncStream<KeyInput>
    @ObservationIgnored private let keyInputContinuation: AsyncStream<KeyInput>.Continuation
    @ObservationIgnored private var keyInputTask: Task<Void, Never>?
    /// Backoff before a resubscribe attempt after the connection drops.
    @ObservationIgnored private let reconnectBackoffNs: UInt64

    init(
        paneId: String,
        daemonClient: any PaneControlling & PaneSubscribing,
        udid: String,
        displayName: String,
        family: String,
        capabilities: PaneCapabilities? = nil,
        reconnectBackoffNs: UInt64 = SimulatorPaneViewModel.defaultReconnectBackoffNs
    ) {
        self.paneId = paneId
        self.daemonClient = daemonClient
        self.udid = udid
        self.displayName = displayName
        self.family = family
        self.capabilities = capabilities ?? .missingBlockFallback
        self.reconnectBackoffNs = reconnectBackoffNs
        (keyInputStream, keyInputContinuation) = AsyncStream<KeyInput>.makeStream()
    }

    deinit {
        subscriptionTask?.cancel()
        touchKeepaliveTask?.cancel()
        keyInputTask?.cancel()
        keyInputContinuation.finish()
    }

    /// Start consuming the pane's event stream. Call once (from the
    /// VC's viewDidLoad). The subscription startup is keyed to VC
    /// creation, not view appearance, since a re-start would strand the
    /// prior task beyond `close()`'s reach. The daemon's subscribe
    /// handler synthesizes an initial `surface.changed` + payload
    /// pair when the pane is already rendering, so the first frame
    /// arrives over this same stream.
    func start() {
        startKeyInputPump()
        guard subscriptionTask == nil else { return }
        let id = paneId
        let client = daemonClient
        // Captured locally so the retry sleep never touches `self`.
        let backoff = reconnectBackoffNs
        subscriptionTask = Task { @MainActor [weak self] in
            // Resubscribe across daemon connection drops so a mirror doesn't
            // freeze forever on a transient XPC interruption. Each pass
            // subscribes and drains the stream; when the stream ends the
            // connection dropped (the daemon finishes it on invalidation).
            // A deliberate terminal state (shutdown/failed) or a terminal
            // daemon response to the subscribe (the pane binding is gone)
            // stops retrying; a transient transport failure backs off and
            // retries, since only a fresh attach recovers a lost binding but
            // a dropped connection recovers on its own.
            while !Task.isCancelled {
                let stream: AsyncStream<PaneEvent>
                do {
                    // `client` + `id` are captured directly, so subscribing
                    // never touches `self`; the task holds only a weak
                    // reference across this await.
                    stream = try await client.subscribePane(paneId: id)
                } catch {
                    if Task.isCancelled { return }
                    // A transport failure (the connection dropped during the
                    // subscribe or its reauth retry) is recoverable, so back off
                    // and try again, exactly as a clean stream-end does, since
                    // launchd re-launches the daemon on the next send. A
                    // terminal daemon response (pane-not-found) or a
                    // `decode`/version fault is a definitive answer no retry
                    // changes, so it fails the pane.
                    if case DaemonClientError.transport = error {
                        try? await Task.sleep(nanoseconds: backoff)
                        continue
                    }
                    if let self {
                        self.state = SimPaneReducer.reduce(
                            self.state,
                            .subscriptionFailed("\(error)")
                        )
                    }
                    return
                }
                for await event in stream {
                    if Task.isCancelled { return }
                    // Promote `self` only while handling one event; the
                    // strong binding falls out of scope before the next
                    // `for await` suspension.
                    guard let self else { return }
                    self.handleSubscriptionEvent(event)
                }
                if Task.isCancelled { return }
                // Read the retry-vs-terminal decision off a copied optional
                // so no strong `self` survives into the backoff sleep.
                // Holding one across the await would pin the VM alive past
                // `deinit`/`close`'s reach and leak the subscription task.
                let shouldRetry: Bool
                switch self?.state {
                case .booting, .rendering:
                    shouldRetry = true

                case .shutdown, .failed:
                    shouldRetry = false

                case nil:
                    return
                }
                guard shouldRetry else { return }
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
    }

    /// Apply one subscription event: coalesce a surface, drive the state
    /// machine on a lifecycle change (clearing pending surfaces on a
    /// terminal state), or adopt the device's true orientation.
    private func handleSubscriptionEvent(_ event: PaneEvent) {
        switch event {
        case let .surfaceChanged(change, lease):
            enqueueSurface(sequence: change.sequence, lease: lease)

        case let .stateChanged(change):
            if change.state == .shutdown || change.state == .failed {
                pendingSurfaceUpdate = nil
                surfaceApplyTask?.cancel()
                surfaceApplyTask = nil
            }
            state = SimPaneReducer.reduce(state, .lifecycle(change.state))

        case let .orientationChanged(change):
            // Adopt the device's true orientation (the rotate may have come
            // from `deviceterm rotate`, not this VM's own `rotate(to:)`).
            // Drives render counter-rotation + input mapping; idempotent
            // when this VM initiated it. An unknown value is ignored.
            if let orientation = Orientation(rawValue: change.orientation) {
                currentOrientation = orientation
            }
        }
    }

    private func startKeyInputPump() {
        guard keyInputTask == nil else { return }
        let id = paneId
        let client = daemonClient
        let stream = keyInputStream
        keyInputTask = Task { @MainActor in
            for await input in stream {
                guard !Task.isCancelled else { return }
                let down: Bool
                let keyCode: UInt16
                switch input {
                case let .down(value):
                    down = true
                    keyCode = value

                case let .up(value):
                    down = false
                    keyCode = value
                }
                do {
                    try await client.paneInputKey(paneId: id, keyCode: UInt32(keyCode), down: down)
                } catch {
                    // A failed input RPC must not terminate the keyboard pump:
                    // later key-up events are needed to release held HID state
                    // after a transient transport failure.
                }
            }
        }
    }

    /// Tear the daemon pane down and stop consuming events. `mode` is
    /// detach (sim keeps running) or shutdown. Async + awaited so the
    /// quit/teardown paths can guarantee the RPC has been written and
    /// acked before the GUI exits; otherwise the daemon retains the pane
    /// record (and its IOSurface stream). Idempotent.
    func close(mode: PaneCloseMode = .detach) async {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        liveTouchHeld = false
        stopTouchKeepalive()
        surfaceApplyTask?.cancel()
        surfaceApplyTask = nil
        pendingSurfaceUpdate = nil
        currentSurface = nil
        currentSequence = nil
        currentSurfaceSequence = nil
        keyInputTask?.cancel()
        keyInputTask = nil
        keyInputContinuation.finish()
        try? await daemonClient.closePane(paneId: paneId, mode: mode)
    }

    // MARK: - Input intents

    func tap(at point: CGPoint) {
        let id = paneId
        let client = daemonClient
        Task { @MainActor in
            try? await client.paneInputTap(paneId: id, x: point.x, y: point.y)
        }
    }

    func touch(at point: CGPoint, phase: TouchPhase) {
        touch(at: point, phase: phase, edge: nil)
    }

    /// Live single-finger contact. When `edge` is non-nil at `.down` the
    /// whole drag (down -> moves -> keepalive -> lift) is tagged with that
    /// `IndigoHIDEdge` value and rides `pane.input.edgeTouch` so it drives
    /// the system gesture; `nil` keeps the ordinary `pane.input.touch`
    /// path. The edge is latched at `.down` and read by every follow-on
    /// event (the view only supplies it on the first contact), so the
    /// keepalive (which fires with no view event) tags its resends too.
    func touch(at point: CGPoint, phase: TouchPhase, edge: Int?) {
        switch phase {
        case .down:
            pendingTouchMove = nil
            lastLiveTouchPoint = point
            liveTouchHeld = true
            liveTouchMovedSinceTick = true
            activeTouchEdge = edge
            startTouchKeepalive()
            sendTouch(point, phase: phase)

        case .lift:
            pendingTouchMove = nil
            liveTouchHeld = false
            stopTouchKeepalive()
            sendTouch(point, phase: phase)
            activeTouchEdge = nil

        case .move:
            lastLiveTouchPoint = point
            liveTouchMovedSinceTick = true
            pendingTouchMove = point
            flushTouchMoveIfNeeded()
        }
    }

    /// Begin re-reporting the held finger while it sits stationary. The
    /// loop ticks at `touchKeepaliveIntervalNs`: if a real `.move`
    /// landed since the last tick the normal path already reported it
    /// (just clear the flag), otherwise re-send the last point as a
    /// `.move` so the contact stream never goes silent mid-hold.
    private func startTouchKeepalive() {
        touchKeepaliveTask?.cancel()
        touchKeepaliveTask = Task { @MainActor [weak self] in
            var frame = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.touchKeepaliveIntervalNs)
                guard let self, self.liveTouchHeld else { return }
                if self.liveTouchMovedSinceTick {
                    self.liveTouchMovedSinceTick = false
                } else {
                    // Sub-pixel alternating jitter so each resend is a
                    // distinct point, because an identical resend stalls the
                    // sim's synchronous HID completion semaphore. Below
                    // the recognizer's movement threshold, so the finger
                    // reads as held-still.
                    frame += 1
                    let jitter = frame.isMultiple(of: 2)
                        ? Self.touchKeepaliveJitter
                        : -Self.touchKeepaliveJitter
                    let point = CGPoint(
                        x: self.lastLiveTouchPoint.x + jitter,
                        y: self.lastLiveTouchPoint.y
                    )
                    self.sendTouch(point, phase: .move)
                }
            }
        }
    }

    private func stopTouchKeepalive() {
        touchKeepaliveTask?.cancel()
        touchKeepaliveTask = nil
        liveTouchMovedSinceTick = false
    }

    func swipe(
        from start: CGPoint,
        to end: CGPoint,
        durationMs: Int,
        holdMs: Int = 0,
        startHoldMs: Int = 0
    ) {
        let id = paneId
        let client = daemonClient
        Task { @MainActor in
            try? await client.paneInputSwipe(
                paneId: id,
                fromX: start.x,
                fromY: start.y,
                toX: end.x,
                toY: end.y,
                durationMs: durationMs,
                holdMs: holdMs,
                startHoldMs: startHoldMs
            )
        }
    }

    /// Open the iOS App Switcher. Rides `pane.input.edgeSwipe`, which the
    /// daemon realizes per backend: on a simulator, an edge-tagged swipe up
    /// from the bottom edge to mid-screen with a dwell (`AppSwitcherGesture`),
    /// where the edge tag routes it to the system gesture rather than the
    /// foreground app. On a physical device, whose synthetic coordinate
    /// touches can't reach the system recognizer, it is the enriched
    /// system-gesture swipe (`openAppSwitcher`), falling back to a
    /// consumer-HID Home double-press. The client passes the swipe
    /// coordinates either way; the daemon ignores them on the device path.
    ///
    /// The `AppSwitcherGesture` constants describe the swipe in *displayed*
    /// (oriented) space: bottom-edge center up to mid-screen. To work in
    /// landscape they're rotated into the surface's portrait-native frame and
    /// tagged with the orientation's home-indicator edge, exactly as the live
    /// bottom-edge drag does (`edge(for:)` + `rotateOrientedToSurface`).
    /// Upside-down has no home-gesture edge (none arms the recognizer), so the
    /// fallback is *wholesale* portrait, covering both the edge tag and the
    /// coordinate rotation. That keeps the tagged gesture self-consistent (a
    /// portrait swipe tagged with the portrait edge). Falling back only the
    /// edge would tag a 180°-rotated, top-origin swipe as a bottom-edge
    /// gesture. The device path ignores both anyway.
    func appSwitcher() {
        // Use portrait wholesale when the live orientation has no home-gesture
        // edge, so the edge tag and the rotation never disagree.
        let orientation = AppSwitcherGesture.edge(for: currentOrientation) == nil
            ? .portrait
            : currentOrientation
        let edge = AppSwitcherGesture.edge(for: orientation) ?? AppSwitcherGesture.edge
        let swipeFrom = SimGestureMath.rotateOrientedToSurface(
            CGPoint(x: AppSwitcherGesture.fromX, y: AppSwitcherGesture.fromY),
            orientation: orientation
        )
        let swipeTo = SimGestureMath.rotateOrientedToSurface(
            CGPoint(x: AppSwitcherGesture.toX, y: AppSwitcherGesture.toY),
            orientation: orientation
        )
        let id = paneId
        let client = daemonClient
        Task { @MainActor in
            try? await client.paneInputEdgeSwipe(
                paneId: id,
                fromX: swipeFrom.x,
                fromY: swipeFrom.y,
                toX: swipeTo.x,
                toY: swipeTo.y,
                edge: edge,
                durationMs: AppSwitcherGesture.durationMs,
                holdMs: AppSwitcherGesture.holdMs
            )
        }
    }

    private func flushTouchMoveIfNeeded() {
        guard !touchMoveInFlight, let point = pendingTouchMove else { return }
        pendingTouchMove = nil
        touchMoveInFlight = true
        let id = paneId
        let client = daemonClient
        let edge = activeTouchEdge
        Task { @MainActor [weak self] in
            if let edge {
                try? await client.paneInputEdgeTouch(
                    paneId: id,
                    x: point.x,
                    y: point.y,
                    phase: .move,
                    edge: edge
                )
            } else {
                try? await client.paneInputTouch(
                    paneId: id,
                    x: point.x,
                    y: point.y,
                    phase: .move
                )
            }
            guard let self else { return }
            self.touchMoveInFlight = false
            self.flushTouchMoveIfNeeded()
        }
    }

    private func sendTouch(_ point: CGPoint, phase: TouchPhase) {
        let id = paneId
        let client = daemonClient
        let edge = activeTouchEdge
        Task { @MainActor in
            if let edge {
                try? await client.paneInputEdgeTouch(
                    paneId: id,
                    x: point.x,
                    y: point.y,
                    phase: phase,
                    edge: edge
                )
            } else {
                try? await client.paneInputTouch(
                    paneId: id,
                    x: point.x,
                    y: point.y,
                    phase: phase
                )
            }
        }
    }

    /// Live two-finger contact frame (Option-drag pinch/rotate). Same
    /// coalescing shape as `touch`: `.down`/`.lift` are sent immediately
    /// (a dropped `.lift` would strand a contact), `.move` is latest-wins
    /// coalesced so a fast drag doesn't queue stale finger positions.
    func multitouch(phase: TouchPhase, finger1: CGPoint, finger2: CGPoint) {
        switch phase {
        case .down:
            pendingMultitouchMove = nil
            sendMultitouch(finger1: finger1, finger2: finger2, phase: phase)

        case .lift:
            pendingMultitouchMove = nil
            sendMultitouch(finger1: finger1, finger2: finger2, phase: phase)

        case .move:
            pendingMultitouchMove = (finger1, finger2)
            flushMultitouchMoveIfNeeded()
        }
    }

    private func flushMultitouchMoveIfNeeded() {
        guard !multitouchMoveInFlight, let move = pendingMultitouchMove else { return }
        pendingMultitouchMove = nil
        multitouchMoveInFlight = true
        let id = paneId
        let client = daemonClient
        Task { @MainActor [weak self] in
            try? await client.paneInputMultitouch(
                paneId: id,
                phase: .move,
                finger1: move.finger1,
                finger2: move.finger2
            )
            guard let self else { return }
            self.multitouchMoveInFlight = false
            self.flushMultitouchMoveIfNeeded()
        }
    }

    private func sendMultitouch(finger1: CGPoint, finger2: CGPoint, phase: TouchPhase) {
        let id = paneId
        let client = daemonClient
        Task { @MainActor in
            try? await client.paneInputMultitouch(
                paneId: id,
                phase: phase,
                finger1: finger1,
                finger2: finger2
            )
        }
    }

    func pinch(
        fromF1: CGPoint,
        fromF2: CGPoint,
        toF1: CGPoint,
        toF2: CGPoint,
        durationMs: Int
    ) {
        let id = paneId
        let client = daemonClient
        Task { @MainActor in
            try? await client.paneInputPinch(
                paneId: id,
                fromF1X: fromF1.x,
                fromF1Y: fromF1.y,
                fromF2X: fromF2.x,
                fromF2Y: fromF2.y,
                toF1X: toF1.x,
                toF1Y: toF1.y,
                toF2X: toF2.x,
                toF2Y: toF2.y,
                durationMs: durationMs
            )
        }
    }

    func keyDown(keyCode: UInt16) {
        guard capabilities.key else { return }
        startKeyInputPump()
        keyInputContinuation.yield(.down(keyCode))
    }

    func keyUp(keyCode: UInt16) {
        guard capabilities.key else { return }
        startKeyInputPump()
        keyInputContinuation.yield(.up(keyCode))
    }

    /// Press a hardware button: Home / Lock / Side / Siri / Apple
    /// Pay / Digital Crown. The wrapper exists so menus, pane chrome
    /// buttons, and any future surface route through one VM-level
    /// entry point instead of constructing the daemon call at each
    /// call site. Family-appropriateness (e.g. Siri is iPhone-only)
    /// is the daemon's contract; the caller doesn't gate.
    func pressButton(_ button: HardwareButton) {
        let id = paneId
        let client = daemonClient
        Task { @MainActor in
            try? await client.paneInputButton(paneId: id, button: button)
        }
    }

    /// Rotate the device to an absolute orientation. The daemon's
    /// `pane.input.rotate` takes the target orientation, not a
    /// delta; relative menu actions go through `rotateLeft` /
    /// `rotateRight` which call this with the computed next step.
    /// Updates `currentOrientation` optimistically; the RPC is
    /// fire-and-forget so a failure leaves a drift the next
    /// rotation absorbs.
    func rotate(to orientation: Orientation) {
        guard capabilities.rotate else { return }
        currentOrientation = orientation
        let id = paneId
        let client = daemonClient
        Task { @MainActor in
            try? await client.paneInputRotate(paneId: id, orientation: orientation)
        }
    }

    /// Rotate 90° counterclockwise from the current orientation,
    /// matching Apple's Device > Rotate Left UX. Cycles through every
    /// orientation under repeated calls.
    func rotateLeft() { rotate(to: currentOrientation.rotatedLeft) }

    /// Rotate 90° clockwise from the current orientation, matching
    /// Apple's Device > Rotate Right UX. Symmetric to `rotateLeft`.
    func rotateRight() { rotate(to: currentOrientation.rotatedRight) }

    /// Drive the watchOS Digital Crown. Delta units match the
    /// daemon's `pane.input.crown` contract (~1 unit per detent;
    /// positive = forward/down). Caller (the scroll-wheel hook in
    /// the VC) is responsible for the family gate; the VM stays
    /// device-agnostic and just forwards.
    func crown(delta: Double) {
        guard capabilities.crown else { return }
        let id = paneId
        let client = daemonClient
        Task { @MainActor in
            try? await client.paneInputCrown(
                paneId: id,
                delta: delta,
                durationMs: 0
            )
        }
    }

    // MARK: - Surface lifecycle

    private func enqueueSurface(sequence: UInt64, lease: SurfaceLease?) {
        // A superseded, un-flushed lease is dropped here and releases by
        // ARC. For a leased device frame that frees the daemon's hold on
        // that generation without it ever reaching the view; an unleased
        // frame just drops with no bookkeeping.
        pendingSurfaceUpdate = (sequence, lease)
        guard surfaceApplyTask == nil else { return }
        surfaceApplyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.surfaceCoalesceIntervalNs)
            guard let self else { return }
            self.surfaceApplyTask = nil
            self.flushPendingSurface()
        }
    }

    private func flushPendingSurface() {
        guard let update = pendingSurfaceUpdate else { return }
        pendingSurfaceUpdate = nil
        applySurface(sequence: update.sequence, lease: update.lease)
    }

    private func applySurface(sequence: UInt64, lease: SurfaceLease?) {
        currentSequence = sequence
        // Only update the rendered surface when a lease is present.
        // A nil lease means the side-band payload was missing or
        // timed out (JSON evt arrived alone), so the GUI should keep
        // its last good frame visible, not blank the pane.
        if let lease {
            // Do NOT skip when the surface ID matches the current one. A new
            // `sequence` always means a new frame's pixels. Simulators update one
            // persistent surface in place (same ID every frame); physical devices
            // reuse a small daemon-owned surface pool whose IDs repeat every few
            // frames. In BOTH cases a repeated ID carries fresh content. Skipping
            // it (relying on the MTKView's continuous draw loop, which isn't
            // reliably running on connect) is what froze the device mirror on stale
            // content while fresh frames arrived. Re-assigning fires the render
            // binding → setSurface → an immediate draw of the live pixels. The
            // prior lease drops here; once its command buffers finish it
            // releases, freeing the daemon hold when it was a leased frame.
            currentSurface = lease
            currentSurfaceSequence = sequence
            state = SimPaneReducer.reduce(state, .surfaceAttached)
        }
    }
}
