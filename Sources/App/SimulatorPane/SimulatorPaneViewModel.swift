// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import IOSurface
import Observation

/// Presentation state + daemon I/O for one
/// mirrored-device pane, sim or physical.
/// `@Observable` so the thin view controller re-renders via
/// `observe()`; pure state transitions go through SimPaneReducer.
/// Owns the pane subscription Task and the IOSurface lifetime.
///
/// Input maps to one-shot RPCs against the daemon's pane.input.* surface:
/// click/drag streams live `pane.input.touch` down/move/up events,
/// a pinch/rotate → pane.input.pinch with from/to f1/f2. Keyboard sends
/// raw NSEvent.keyCode (kVK); the daemon owns the kVK→USB-HID translation.
///
/// Surface lifecycle: surfaces arrive from the daemon over XPC as
/// `(SurfaceChangedEvent, IOSurfaceRef?)` pairs through the
/// `PaneSubscribing` role surface. The model stores the ref directly,
/// with no `IOSurfaceLookupFromXPCObject` hop and no per-frame
/// mirror-surface indirection. The first surface that resolves marks the pane as
/// rendering; subsequent surfaces replace it in place.
@MainActor
@Observable
final class SimulatorPaneViewModel {
    private enum KeyInput: Sendable {
        case down(UInt16)
        // swiftlint:disable:next identifier_name
        case up(UInt16)
    }

    /// A live-contact edge that must never be dropped. Moves ride a separate
    /// replaceable slot instead: losing one costs a position, losing a `down`
    /// or a `lift` costs the gesture or strands a finger.
    ///
    /// One stream for both single-touch and two-finger contacts, because they
    /// share the pane's digitizer. On separate pumps an Option-drag's
    /// two-finger `down` can be sent while the preceding single-touch `lift` is
    /// still in flight, and the daemon then sees a plain lift for a two-finger
    /// contact.
    private enum LiveLifecycle: Sendable {
        case touchDown(CGPoint, isEdgeGesture: Bool, gesture: UInt64)
        case touchLift(CGPoint, gesture: UInt64)
        case multiDown(CGPoint, CGPoint, gesture: UInt64)
        case multiLift(CGPoint, CGPoint, gesture: UInt64)
        /// A move is waiting in the matching slot. Carries no position: the
        /// pump reads the newest one, so a nudge that arrives after the drain
        /// already took it is a no-op.
        case touchMoveAvailable
        case multiMoveAvailable
    }

    /// A pending two-finger move, tagged with the gesture that produced it.
    private struct PendingMultitouchMove {
        let finger1: CGPoint
        let finger2: CGPoint
        let gesture: UInt64
    }

    /// Default backoff before resubscribing after the daemon connection
    /// drops mid-stream. Keeps a flapping connection from busy-looping, and
    /// grows so a connection that never comes back stops being asked several
    /// times a second. Overridable per-instance (tests inject a tiny value).
    static let defaultReconnectPolicy = RetryPolicy(
        initialDelayNanoseconds: 500_000_000,
        maximumDelayNanoseconds: 8_000_000_000
    )
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
    /// The admission this pane was mounted from, echoed back on close so a
    /// teardown racing a re-attach can't retire the newer admission. See
    /// `MirroredPaneState.attachment`.
    let attachment: UInt64?
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
    /// frame's lease holds a pool slot until it (and every command buffer
    /// that sampled it) is released. An unleased frame (under the kill
    /// switch) carries a lease that holds nothing.
    private(set) var currentSurface: SurfaceLease?
    /// The sequence of `currentSurface`, advanced only when a non-nil
    /// surface is accepted, unlike `currentSequence` which also advances on
    /// a JSON-only frame whose side-band surface was missing. The trace path
    /// pairs the rendered surface with this so a skipped frame can't
    /// mislabel the one still onscreen.
    private(set) var currentSurfaceSequence: UInt64?
    var supportsLiveTouchInput: Bool { daemonClient.supportsLiveTouchInput }
    var supportsMultitouchInput: Bool { daemonClient.supportsMultitouchInput }
    /// The pane's presentation orientation, as last reported by the
    /// daemon's `orientation.changed` pane event (`pane.subscribe`), never
    /// written by this VM's own rotate calls.
    ///
    /// A Simulator reports observed display orientation. A physical device
    /// reports a valid orientation returned by a DeviceTerm rotation reply.
    /// The latter has no passive display source, so a rotation performed by
    /// hand remains invisible. Drives render counter-rotation, the bezel, and
    /// input mapping.
    private(set) var currentOrientation: Orientation = .portrait

    // Infrastructure, not observable state. Kept out of the registrar so
    // changes don't trigger renders and `deinit` can touch the task.
    @ObservationIgnored private let daemonClient: any PaneControlling & PaneSubscribing
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    /// GUI rotation intents wait here in AppKit delivery order. A single pump
    /// preserves click order while each RPC handles bounded daemon backpressure.
    @ObservationIgnored private var pendingRotations: [RotationTarget] = []
    @ObservationIgnored private var rotationTask: Task<Void, Never>?
    /// The pending move, tagged with the gesture that produced it.
    ///
    /// A slot shared across gestures is worse than no slot: a `down` for the
    /// next drag can land while the previous `lift` is still in flight, and its
    /// move would then be sent as part of the old gesture or cleared by the old
    /// gesture's teardown.
    @ObservationIgnored private var pendingTouchMove: (point: CGPoint, gesture: UInt64)?
    /// Bumped by intake on every `.down`; the pump tracks the one it is
    /// currently servicing.
    @ObservationIgnored private var intakeGesture: UInt64 = 0
    @ObservationIgnored private var pumpGesture: UInt64 = 0
    @ObservationIgnored private var intakeMultitouchGesture: UInt64 = 0
    @ObservationIgnored private var pumpMultitouchGesture: UInt64 = 0
    /// At most one un-consumed move nudge is on the stream at a time, so a fast
    /// drag can't queue one per event behind a slow send.
    @ObservationIgnored private var touchMoveNudged = false
    /// Whether the *pump* has an open contact, which is not the same as the
    /// intake's `liveTouchHeld`: intake clears that the instant a lift is
    /// queued, while the pump may still owe the moves that preceded it.
    @ObservationIgnored private var pumpContactOpen = false
    @ObservationIgnored private var pumpMultitouchOpen = false
    @ObservationIgnored private var multitouchMoveNudged = false
    /// Live-touch keepalive: re-report a held-but-stationary finger so
    /// the OS sees continuous contact (the dwell the App Switcher /
    /// Control Center recognizers need), not a silent gap once
    /// `mouseDragged` stops firing. Tracks the last reported point, a
    /// "moved this tick" flag, and the repeating task.
    @ObservationIgnored private var liveTouchHeld = false
    @ObservationIgnored private var lastLiveTouchPoint: CGPoint = .zero
    @ObservationIgnored private var liveTouchMovedSinceTick = false
    @ObservationIgnored private var touchKeepaliveTask: Task<Void, Never>?
    /// True for the lifetime of a live drag that began in the displayed
    /// bottom-edge band, routing every contact (down/move/keepalive/lift)
    /// through `pane.input.edgeTouch` so the drag drives SpringBoard's
    /// system gesture (App Switcher) instead of scrolling the foreground
    /// app. Latched at `.down`, cleared at `.lift`. False is the ordinary
    /// plain-touch path.
    @ObservationIgnored private var activeTouchIsEdgeGesture = false
    @ObservationIgnored private var pendingMultitouchMove: PendingMultitouchMove?
    @ObservationIgnored private var multitouchMoveInFlight = false
    /// AppKit gives key events in order, but dispatching every one in an
    /// independent Task can reverse a quick down/up pair once the RPCs suspend.
    /// Feed them through one stream so the daemon (and its delta-less HID
    /// keyboard state) observes the same order AppKit did.
    @ObservationIgnored private let keyInputStream: AsyncStream<KeyInput>
    @ObservationIgnored private let keyInputContinuation: AsyncStream<KeyInput>.Continuation
    @ObservationIgnored private var keyInputTask: Task<Void, Never>?
    /// The shared live-contact stream, ordered end to end.
    ///
    /// AppKit hands these over in order, but a `Task` per event lets a `move`
    /// overtake its own `down` once the RPCs suspend, and XPC dispatch gives no
    /// arrival-order guarantee either. One pump per stream is what makes the
    /// daemon see the order the user produced. Same shape as the key pump
    /// above, and for the same reason.
    @ObservationIgnored private let liveStream: AsyncStream<LiveLifecycle>
    @ObservationIgnored private let liveContinuation: AsyncStream<LiveLifecycle>.Continuation
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    /// Backoff schedule for resubscribe attempts after the connection drops.
    @ObservationIgnored private let reconnectPolicy: RetryPolicy

    @ObservationIgnored private var wantsFrames = true
    @ObservationIgnored private var subscriptionGeneration: UInt64 = 0
    @ObservationIgnored private var subscriptionStarted = false
    @ObservationIgnored private var closed = false

    init(
        paneId: String,
        daemonClient: any PaneControlling & PaneSubscribing,
        udid: String,
        displayName: String,
        family: String,
        attachment: UInt64? = nil,
        capabilities: PaneCapabilities? = nil,
        reconnectPolicy: RetryPolicy = SimulatorPaneViewModel.defaultReconnectPolicy
    ) {
        self.paneId = paneId
        self.attachment = attachment
        self.daemonClient = daemonClient
        self.udid = udid
        self.displayName = displayName
        self.family = family
        self.capabilities = capabilities ?? .missingBlockFallback
        self.reconnectPolicy = reconnectPolicy
        (keyInputStream, keyInputContinuation) = AsyncStream<KeyInput>.makeStream()
        (liveStream, liveContinuation) = AsyncStream<LiveLifecycle>.makeStream()
    }

    deinit {
        subscriptionTask?.cancel()
        rotationTask?.cancel()
        touchKeepaliveTask?.cancel()
        keyInputTask?.cancel()
        keyInputContinuation.finish()
        liveTask?.cancel()
        liveContinuation.finish()
    }

    /// Start input pumps and the event subscription once the view is loaded.
    func start() {
        guard !closed else { return }
        startKeyInputPump()
        startTouchPumps()
        guard !subscriptionStarted else { return }
        subscriptionStarted = true
        replaceSubscription()
    }

    func setFrameDemand(_ demanded: Bool) {
        guard !closed, demanded != wantsFrames else { return }
        wantsFrames = demanded
        if !demanded {
            currentSurface = nil
            currentSurfaceSequence = nil
        }
        if subscriptionStarted { replaceSubscription() }
    }

    private func replaceSubscription() {
        let previous = subscriptionTask
        previous?.cancel()
        subscriptionGeneration += 1
        let generation = subscriptionGeneration
        let frames = wantsFrames
        let id = paneId
        let client = daemonClient
        // Captured locally so the retry sleep never touches `self`. The
        // attempt count lives in the task for the same reason: a delivered
        // event resets it from inside the drain loop, where `self` is already
        // promoted, so the backoff needs no reference of its own.
        let policy = reconnectPolicy
        subscriptionTask = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.subscriptionGeneration == generation else { return }
            var attempt = 0
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
                    stream = try await client.subscribePane(paneId: id, frames: frames)
                } catch {
                    if Task.isCancelled { return }
                    // A connection failure (a transport error, usually the
                    // connection dropping during the subscribe or its reauth
                    // retry, or the handshake's bound expiring before the
                    // helper answered) is recoverable, so back off and try
                    // again, exactly as a clean stream-end does: launchd
                    // re-launches a gone daemon on the next send, and a slow
                    // one answers the retry. A terminal daemon response
                    // (pane-not-found) or a `decode`/version fault is a
                    // definitive answer no retry changes, so it fails the pane.
                    if let clientError = error as? DaemonClientError, clientError.isConnectionFailure {
                        try? await Task.sleep(
                            nanoseconds: policy.delayNanoseconds(forAttempt: attempt)
                        )
                        attempt += 1
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
                    guard let self, self.subscriptionGeneration == generation else { return }
                    // A delivered event is the proof this subscription works,
                    // so the next drop starts its backoff over rather than
                    // inheriting the wait that got us here.
                    attempt = 0
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
                try? await Task.sleep(
                    nanoseconds: policy.delayNanoseconds(forAttempt: attempt)
                )
                attempt += 1
            }
        }
    }

    /// Apply one subscription event: adopt a surface, drive the state
    /// machine on a lifecycle change, or adopt the orientation the daemon
    /// reports. Surfaces arrive already coalesced latest-only by the
    /// transport, so each one is applied as it comes.
    private func handleSubscriptionEvent(_ event: PaneEvent) {
        switch event {
        case let .surfaceChanged(change, lease):
            applySurface(sequence: change.sequence, lease: lease)

        case let .stateChanged(change):
            state = SimPaneReducer.reduce(state, .lifecycle(change.state))

        case let .orientationChanged(change):
            // Adopt the confirmed presentation orientation the daemon reports,
            // the only writer of this value. A Simulator publishes display
            // observation; a physical device publishes a rotation reply. A
            // fresh subscription replays the daemon's current value. An unknown
            // value is ignored.
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
        closed = true
        subscriptionGeneration += 1
        subscriptionTask?.cancel()
        subscriptionTask = nil
        rotationTask?.cancel()
        rotationTask = nil
        pendingRotations.removeAll()
        liveTouchHeld = false
        stopTouchKeepalive()
        currentSurface = nil
        currentSequence = nil
        currentSurfaceSequence = nil
        keyInputTask?.cancel()
        keyInputTask = nil
        keyInputContinuation.finish()
        try? await daemonClient.closePane(paneId: paneId, mode: mode, expecting: attachment)
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
        touch(at: point, phase: phase, isEdgeGesture: false)
    }

    /// Live single-finger contact. When `isEdgeGesture` is true at `.down`
    /// the whole drag (down -> moves -> keepalive -> lift) rides
    /// `pane.input.edgeTouch` so it drives the system gesture; false keeps
    /// the ordinary `pane.input.touch` path. Latched at `.down` and read
    /// by every follow-on event (the view only supplies it on the first
    /// contact), so the keepalive, which fires with no view event, stays
    /// on the same path. Which `IndigoHIDEdge` value the drag carries is
    /// the daemon's to pick, and it latches that for the drag too.
    func touch(at point: CGPoint, phase: TouchPhase, isEdgeGesture: Bool) {
        // Idempotent, and here rather than only in `start()` so input is never
        // silently swallowed by a view model that hasn't subscribed yet.
        startTouchPumps()
        switch phase {
        case .down:
            pendingTouchMove = nil
            lastLiveTouchPoint = point
            liveTouchHeld = true
            liveTouchMovedSinceTick = true
            intakeGesture &+= 1
            startTouchKeepalive()
            // The edge is latched by the pump when it sends the down, not here:
            // the next drag's intake can run while this one's lift is still in
            // flight, and an intake-side latch would retag that lift.
            liveContinuation.yield(
                .touchDown(point, isEdgeGesture: isEdgeGesture, gesture: intakeGesture)
            )

        case .lift:
            liveTouchHeld = false
            stopTouchKeepalive()
            liveContinuation.yield(.touchLift(point, gesture: intakeGesture))

        case .move:
            lastLiveTouchPoint = point
            liveTouchMovedSinceTick = true
            enqueueTouchMove(point)
        }
    }

    /// Replace the pending move and wake the pump if it isn't already going to
    /// look. Latest-wins: a position overwritten before the pump reads it was
    /// stale anyway.
    private func enqueueTouchMove(_ point: CGPoint) {
        pendingTouchMove = (point, intakeGesture)
        guard !touchMoveNudged else { return }
        touchMoveNudged = true
        liveContinuation.yield(.touchMoveAvailable)
    }

    /// Drain the shared live-contact stream in order.
    ///
    /// Lifecycle edges ride one FIFO the pump never skips; each touch kind
    /// keeps one replaceable latest-wins move slot, drained after each edge and
    /// between sends. One buffering policy gets it wrong either way: keeping
    /// only the newest item could drop a `down` or a `lift`, while an unbounded
    /// queue keeps them but stacks stale drag positions behind a slow send.
    private func startTouchPumps() {
        guard liveTask == nil else { return }
        let stream = liveStream
        liveTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case let .touchDown(point, isEdgeGesture, gesture):
                    self.activeTouchIsEdgeGesture = isEdgeGesture
                    self.pumpGesture = gesture
                    self.pumpContactOpen = true
                    await self.deliverTouch(point, phase: .down)

                case let .touchLift(point, gesture):
                    self.pumpGesture = gesture
                    // Drain a move that arrived while the down was in flight,
                    // so the lift never lands on a stale position.
                    await self.drainPendingTouchMoves()
                    await self.deliverTouch(point, phase: .lift)
                    self.pumpContactOpen = false
                    self.activeTouchIsEdgeGesture = false
                    // Only this gesture's leftovers: the next drag may already
                    // have queued a move behind the lift.
                    if self.pendingTouchMove?.gesture == gesture {
                        self.pendingTouchMove = nil
                    }

                case .touchMoveAvailable:
                    self.touchMoveNudged = false

                case let .multiDown(finger1, finger2, gesture):
                    self.pumpMultitouchGesture = gesture
                    self.pumpMultitouchOpen = true
                    await self.deliverMultitouch(finger1: finger1, finger2: finger2, phase: .down)

                case let .multiLift(finger1, finger2, gesture):
                    self.pumpMultitouchGesture = gesture
                    await self.drainPendingMultitouchMoves()
                    await self.deliverMultitouch(finger1: finger1, finger2: finger2, phase: .lift)
                    self.pumpMultitouchOpen = false
                    if self.pendingMultitouchMove?.gesture == gesture {
                        self.pendingMultitouchMove = nil
                    }

                case .multiMoveAvailable:
                    self.multitouchMoveNudged = false
                }
                await self.drainPendingTouchMoves()
                await self.drainPendingMultitouchMoves()
            }
        }
    }

    /// Send whatever move is pending, repeatedly, until the slot is empty. A
    /// fast drag replaces the slot while a send is in flight, so the newest
    /// position goes out and the ones it overwrote are dropped rather than
    /// queued.
    private func drainPendingTouchMoves() async {
        while pumpContactOpen, let pending = pendingTouchMove, pending.gesture == pumpGesture {
            pendingTouchMove = nil
            await deliverTouch(pending.point, phase: .move)
        }
    }

    private func drainPendingMultitouchMoves() async {
        while pumpMultitouchOpen,
            let move = pendingMultitouchMove,
            move.gesture == pumpMultitouchGesture {
            pendingMultitouchMove = nil
            await deliverMultitouch(finger1: move.finger1, finger2: move.finger2, phase: .move)
        }
    }

    /// One contact event, awaited. A failed send is ignored so the pump can
    /// continue: wedging the chain would strand the terminal lift.
    private func deliverTouch(_ point: CGPoint, phase: TouchPhase) async {
        do {
            if activeTouchIsEdgeGesture {
                try await daemonClient.paneInputEdgeTouch(
                    paneId: paneId,
                    x: point.x,
                    y: point.y,
                    phase: phase
                )
            } else {
                try await daemonClient.paneInputTouch(paneId: paneId, x: point.x, y: point.y, phase: phase)
            }
        } catch {
            // Ignored so the pump keeps going: the terminal lift still has to
            // land, and a stranded contact is worse than a dropped position.
            // Same rule as the keyboard pump above.
        }
    }

    private func deliverMultitouch(finger1: CGPoint, finger2: CGPoint, phase: TouchPhase) async {
        do {
            try await daemonClient.paneInputMultitouch(
                paneId: paneId,
                phase: phase,
                finger1: finger1,
                finger2: finger2
            )
        } catch {
            // See `deliverTouch`: the lift matters more than any one frame.
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
                    // Through the same slot the drag uses, so a resend can
                    // never overtake the contact it is refreshing.
                    self.enqueueTouchMove(point)
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
    /// from the bottom edge to a shallow dwell point (`AppSwitcherGesture`),
    /// where the edge tag routes it to the system gesture rather than the
    /// foreground app without crossing the Home commit threshold. On a
    /// physical device, whose synthetic coordinate
    /// touches can't reach the system recognizer, it is the enriched
    /// system-gesture swipe (`openAppSwitcher`), falling back to a
    /// consumer-HID Home double-press. The client passes the swipe
    /// coordinates either way; the daemon ignores them on the device path.
    ///
    /// The `AppSwitcherGesture` constants describe the swipe in displayed
    /// space, bottom-edge center to the shallow switcher dwell, which is what
    /// the wire takes. The daemon rotates them into the surface's portrait-native
    /// frame and picks the matching home-indicator edge tag from its
    /// authoritative presentation orientation
    /// (`AppSwitcherGesture.plan(for:)`), which this view model's own
    /// `currentOrientation` can lag.
    func appSwitcher() {
        let id = paneId
        let client = daemonClient
        Task { @MainActor in
            try? await client.paneInputEdgeSwipe(
                paneId: id,
                fromX: AppSwitcherGesture.fromX,
                fromY: AppSwitcherGesture.fromY,
                toX: AppSwitcherGesture.toX,
                toY: AppSwitcherGesture.toY,
                durationMs: AppSwitcherGesture.durationMs,
                holdMs: AppSwitcherGesture.holdMs
            )
        }
    }

    /// Live two-finger contact frame (Option-drag pinch/rotate). Same shape as
    /// `touch`: `.down` and `.lift` are preserved in FIFO order (a dropped
    /// `.lift` would strand a contact), `.move` is latest-wins so a fast drag
    /// doesn't queue stale finger positions.
    func multitouch(phase: TouchPhase, finger1: CGPoint, finger2: CGPoint) {
        startTouchPumps()
        switch phase {
        case .down:
            pendingMultitouchMove = nil
            intakeMultitouchGesture &+= 1
            liveContinuation.yield(.multiDown(finger1, finger2, gesture: intakeMultitouchGesture))

        case .lift:
            liveContinuation.yield(.multiLift(finger1, finger2, gesture: intakeMultitouchGesture))

        case .move:
            pendingMultitouchMove = PendingMultitouchMove(
                finger1: finger1,
                finger2: finger2,
                gesture: intakeMultitouchGesture
            )
            if !multitouchMoveNudged {
                multitouchMoveNudged = true
                liveContinuation.yield(.multiMoveAvailable)
            }
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

    /// Rotate the device to an absolute orientation.
    func rotate(to orientation: Orientation) { sendRotation(.absolute(orientation)) }

    /// Rotate 90° counterclockwise, matching Apple's Device > Rotate
    /// Left UX. Cycles through every orientation under repeated calls.
    func rotateLeft() { sendRotation(.relative(.left)) }

    /// Rotate 90° clockwise, matching Apple's Device > Rotate Right.
    func rotateRight() { sendRotation(.relative(.right)) }

    /// Ask the daemon to rotate, and don't touch `currentOrientation`.
    /// `orientationChanged` carries the confirmed presentation value.
    ///
    /// Writing it here optimistically would turn the pane on intent rather
    /// than on the daemon's answer. The daemon decides whether display
    /// observation or a physical-device reply confirms the result. The GUI
    /// presents no separate rotation error; presentation still follows any
    /// confirmed orientationChanged event.
    private func sendRotation(_ target: RotationTarget) {
        guard capabilities.rotate else { return }
        pendingRotations.append(target)
        startRotationPump()
    }

    private func startRotationPump() {
        guard rotationTask == nil else { return }
        let id = paneId
        let client = daemonClient
        rotationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let target = self?.dequeueRotation() else {
                    self?.rotationTask = nil
                    return
                }
                try? await client.paneInputRotate(paneId: id, target: target)
            }
        }
    }

    private func dequeueRotation() -> RotationTarget? {
        guard !pendingRotations.isEmpty else { return nil }
        return pendingRotations.removeFirst()
    }

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

    private func applySurface(sequence: UInt64, lease: SurfaceLease?) {
        currentSequence = sequence
        // Only update the rendered surface when a lease is present.
        // A nil lease means the side-band payload was missing or
        // timed out (JSON evt arrived alone), so the GUI should keep
        // its last good frame visible, not blank the pane.
        if let lease {
            // Never skip on a matching surface id: a new `sequence` is a new
            // frame. Simulator and physical-device frames both arrive from
            // small reusable surface pools, so a repeated id carries fresh
            // pixels. Reassigning fires the render binding, which hands the
            // lease to the view and requests a draw. The view model drops
            // its prior reference here; the lease releases once the view
            // has replaced it and every command buffer holding it completes,
            // freeing the daemon hold when it was a leased frame.
            currentSurface = lease
            currentSurfaceSequence = sequence
            state = SimPaneReducer.reduce(state, .surfaceAttached)
        }
    }
}
