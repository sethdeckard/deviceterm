// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol
import IOSurface
import Metal
import MetalKit
import SurfaceTrace

/// The MTKView that renders a simulator's
/// IOSurface as a textured quad each frame, plus the NSResponder input
/// handlers that synthesize taps/swipes/pinches. The Metal + IOSurface
/// zero-copy texture path and the aspect-fit letterbox math were
/// established empirically against a live simulator, so the specifics
/// are worth preserving exactly. The *pure* geometry lives in
/// `SimGestureMath`; the
/// responder overrides and gesture accumulation stay here because
/// input dispatch (and AppKit's multi-touch synthesis) must live on the
/// responder (see AGENTS.md SwiftUI/AppKit boundary). The view never
/// sees the daemon; it reports gestures through `SimulatorInputDelegate`
/// and the VC forwards them to the view model.
final class SimulatorContentView: MTKView, MTKViewDelegate {
    /// One detent = `crownDragDetentPoints` of vertical drag.
    /// Smaller = more sensitive. ~8pt feels close to the physical
    /// crown's click-stops.
    private static let crownDragDetentPoints: CGFloat = 8
    /// Fixed pinch center for the Option-drag gesture (screen center in
    /// normalized surface space). Finger 1 = mouse, finger 2 mirrors here.
    private static let multitouchAnchor = CGPoint(x: 0.5, y: 0.5)
    /// How long the mouse must stay pressed (without crossing the tap
    /// threshold) before a stationary hold lands as a live `.down` contact,
    /// so a press-and-hold registers as iOS long-press instead of collapsing
    /// to a tap on release. Matches iOS's ~500ms long-press recognizer.
    private static let longPressHoldThresholdNs: UInt64 = 500_000_000

    weak var inputDelegate: SimulatorInputDelegate?
    private(set) var surfaceSize: CGSize = .zero
    /// The lease on the surface the view is drawing. Held here (and by
    /// each in-flight command buffer) so a device frame's pool hold isn't
    /// released until the surface is no longer current and every draw that
    /// sampled it has completed.
    private var currentSurface: SurfaceLease?
    /// Pane id for off-by-default surface trace rows; set by the owning
    /// view controller only for physical-device panes (nil disables
    /// tracing, so simulator panes never scan or emit rows).
    var tracePaneId: String?
    /// The wire sequence of the last frame marked for a trace scan, so a
    /// delivered frame is traced at most once no matter how many times the
    /// continuous draw loop repaints it (a superseded frame may go untraced).
    private var lastTracedSequence: UInt64?
    /// The expected trace id (wire sequence) for a frame not yet traced;
    /// consumed on the next draw.
    private var pendingTraceSequence: UInt64?
    /// Owns the Metal command queue, pipeline, and shader; fed the live
    /// surface + orientation + bezel geometry each `draw(in:)`.
    private let renderer: SimulatorMetalRenderer
    /// Locally-tracked device orientation; the shader rotates UV
    /// sampling to display the IOSurface upright when the sim is
    /// in landscape (CoreSimulator keeps delivering the surface at
    /// the original portrait pixel dimensions with rotated content
    /// inside, so a render-side counter-rotation is what makes the
    /// content look upright). Owner pushes updates via
    /// `setOrientation(_:)` whenever the VM's `currentOrientation`
    /// changes.
    private var orientation: Orientation = .portrait
    /// Margin (in points) reserved on each side of this view for
    /// the wrapper's bezel layer to paint into. The shader's
    /// aspect-fit shrinks the rendered screen by `2 × displayInset`
    /// on each axis so a `displayInset`-wide bezel strip is visible
    /// around the screen. Pushed by the wrapper on every render
    /// pass; zero for tv / unknown until the bezel context is set.
    /// Exposed read-only so non-gesture mappings (AX hover) can
    /// reuse the same value. Every coord translation must use
    /// the same inset the shader does.
    private(set) var displayInset: CGFloat = 0
    /// Inner corner radius (in points) applied to the rendered
    /// screen via the screen-mask layer. Matches the bezel's
    /// inner curve so the screen reads as a real device's display
    /// (rounded inside the bezel, not a sharp rectangle). Set
    /// alongside `displayInset` so the two stay in sync.
    private var screenCornerRadius: CGFloat = 0
    private var dragStart: CGPoint?
    private var dragStartTime: Date?
    private var liveTouchActive = false
    /// Latched at mouseDown for a single-finger drag that began in the
    /// displayed bottom-edge band on a sim pane, so the drag drives the
    /// system gesture (App Switcher) rather than scrolling the app.
    /// False is the ordinary touch path. Sent to the delegate on the
    /// first `.down` and cleared at lift.
    private var liveTouchIsEdgeGesture = false
    /// Pending hold timer for a stationary press. Scheduled when a
    /// single-finger press lands on-screen; if it fires before any drag,
    /// crown, or release intervenes, it promotes the press to a live `.down`
    /// (a held finger) so iOS sees a long-press. Cancelled the moment a real
    /// drag begins or the mouse lifts.
    private var longPressHoldTask: Task<Void, Never>?
    /// Latched at mouseDown when Option is held (and the daemon supports
    /// it): the drag is a two-finger pinch/rotate for its whole life,
    /// regardless of whether Option is released mid-drag. `…Active` flips
    /// once the first `.down` has been emitted (two-stage, like
    /// `liveTouchActive`) so a bare Option-click sends nothing.
    /// The pinch is center-anchored: finger 1 = mouse, finger 2 mirrors
    /// about `multitouchAnchor`.
    private var multitouchArmed = false
    private var multitouchActive = false
    /// Visual affordance for the live two-finger gesture: the anchor
    /// dot + two contact dots + connecting line, like Simulator.app's
    /// Option-drag. A sublayer of THIS view's `CAMetalLayer` (not the
    /// wrapper's bezel layer, which sits *below* the Metal drawable and
    /// would be occluded by the rendered screen). Geometry is flipped to
    /// match the view's `isFlipped = true` so view points map directly.
    private let multitouchOverlayLayer = CAShapeLayer()
    private var gestureActive = false
    private var gestureCenter: CGPoint = .zero
    private var gestureSeparation: CGFloat = 0
    private var gestureAngle: CGFloat = 0
    private var gestureStartTime: Date?
    private var gestureStartF1: CGPoint = .zero
    private var gestureStartF2: CGPoint = .zero
    private var scrollGestureTimer: DispatchWorkItem?
    /// Tracks an in-flight click that started on the watch
    /// Digital Crown bump. Set in `mouseDown` when the click hits
    /// the wrapper's `currentCrownRect`; drives `mouseDragged` to
    /// fire crown detents and `mouseUp` to fire press-or-release.
    /// Mutually exclusive with `dragStart`, since a crown gesture
    /// can't double as a screen gesture.
    private var crownDragActive = false
    private var crownDragAccumulator: CGFloat = 0
    /// Set true on any `mouseDragged` movement during a crown
    /// gesture, separate from `crownDragAccumulator` (which
    /// subtracts back toward zero on every detent). Without this
    /// flag, a drag that lands exactly on a detent boundary
    /// leaves the accumulator at 0 and `mouseUp` mis-fires a
    /// crown press in addition to the detent it already sent.
    private var crownDragMoved = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        // `AppDelegate.applicationDidFinishLaunching` probes Metal at
        // launch and surfaces a clear NSAlert + terminates when no
        // device is exposed. Reaching here therefore implies Metal is
        // available; the precondition documents the invariant + still
        // traps if the launch guard ever regresses, without violating
        // AGENTS.md's library-code rule against `fatalError`.
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure(
                "Metal device unavailable in SimulatorContentView.init; "
                + "AppDelegate's launch guard should have caught this"
            )
        }
        // The view's `colorPixelFormat` is set to `.bgra8Unorm` below;
        // hand the renderer the same so its pipeline attachment matches.
        renderer = SimulatorMetalRenderer(device: device, pixelFormat: .bgra8Unorm)
        super.init(frame: .zero, device: device)
        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm
        // Transparent letterbox: the wrapper paints a device-frame
        // bezel behind this view. Clearing to (0,0,0,0) plus
        // `layer.isOpaque = false` lets the bezel show through
        // wherever the shader's aspect-fit quad doesn't cover. The
        // shader never draws outside the quad's NDC rect, so
        // transparency is automatic outside it with no fragment-side
        // changes. MTKView doesn't expose `isOpaque` as settable;
        // configuring the backing layer is the supported path
        // (`wantsLayer = true` is implicit on MTKView).
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        autoResizeDrawable = true
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false
        delegate = self
        multitouchOverlayLayer.fillColor = NSColor(white: 1, alpha: 0.40).cgColor
        multitouchOverlayLayer.strokeColor = NSColor(white: 1, alpha: 0.90).cgColor
        multitouchOverlayLayer.lineWidth = 1.5
        // Top-left origin, matching the view's flipped coordinates so the
        // dot positions below are used verbatim.
        multitouchOverlayLayer.isGeometryFlipped = true
        // Above the Metal drawable.
        multitouchOverlayLayer.zPosition = 1_000
        multitouchOverlayLayer.isHidden = true
        layer?.addSublayer(multitouchOverlayLayer)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSurface(_ lease: SurfaceLease?) {
        currentSurface = lease
        if let surface = lease?.surface {
            surfaceSize = CGSize(
                width: IOSurfaceGetWidth(surface),
                height: IOSurfaceGetHeight(surface)
            )
            // Force the freshly delivered frame onscreen immediately. This view
            // draws continuously via the MTKView display loop, but that loop isn't
            // reliably ticking on first connect (the view often isn't in a
            // laid-out, visible window when the first frames arrive), so a new
            // surface would otherwise sit unshown until an unrelated event (a mouse
            // click, a layout pass) kicked the loop. That was the "mirror frozen on
            // connect until you interact" bug, most visible on physical-device
            // panes whose frames are change-driven. Drawing on arrival makes frames
            // show regardless of the loop's state; the continuous loop still covers
            // in-place same-surface damage updates (the simulator path). Guarded on
            // `window` so nothing is drawn before the view is placed (no drawable).
            if window != nil { draw() }
        }
    }

    /// Push the device's current orientation in. The shader uses it
    /// to rotate UV sampling so the rendered content is upright; the
    /// aspect-fit math swaps texture width/height for landscape so
    /// the quad fills its pane in the correct aspect rather than
    /// letterboxing the rotated content into a portrait box. No
    /// effect until the next `draw(in:)` pass.
    func setOrientation(_ orientation: Orientation) {
        self.orientation = orientation
    }

    /// Push the wrapper's device-frame geometry in. `inset` is the
    /// per-side bezel margin the shader's aspect-fit must reserve
    /// (in points); `screenCornerRadius` is the inner corner radius
    /// applied via a rounded-rect mask so the rendered screen has
    /// rounded corners that match the device's display.
    func setDisplayFrame(inset: CGFloat, screenCornerRadius: CGFloat) {
        displayInset = inset
        self.screenCornerRadius = screenCornerRadius
    }

    // MARK: MTKViewDelegate

    func draw(in view: MTKView) {
        // Peek (don't consume) the pending trace: retire it only if the
        // renderer actually installs it (reached commit), so an early
        // return doesn't lose the frame's trace permanently.
        let trace = peekConsumerTrace()
        let installed = renderer.render(
            lease: currentSurface,
            orientation: orientation,
            displayInset: displayInset,
            screenCornerRadius: screenCornerRadius,
            in: view,
            trace: trace
        )
        if installed { pendingTraceSequence = nil }
    }

    /// Apply a freshly delivered frame: arm its trace sequence **before**
    /// setting the surface, since `setSurface` draws synchronously and the
    /// draw must see this frame's expected id, not the previous one's.
    /// `traceSequence` is nil for sim panes.
    func applyFrame(lease: SurfaceLease?, traceSequence: UInt64?) {
        markTraceSequence(traceSequence)
        setSurface(lease)
    }

    /// Record the wire sequence of a freshly delivered frame so the next
    /// draw traces it. Device panes only (nil for sim, via `tracePaneId`).
    private func markTraceSequence(_ sequence: UInt64?) {
        guard let sequence, sequence != lastTracedSequence else { return }
        lastTracedSequence = sequence
        pendingTraceSequence = sequence
    }

    /// The consumer trace context for a not-yet-traced frame; nil when
    /// tracing is off, no pane id is set, or this frame was already traced.
    /// Does not consume the pending sequence; `draw` clears it only after a
    /// successful install.
    private func peekConsumerTrace() -> SurfaceConsumerTrace? {
        guard let sink = SurfaceTraceSink.guiConsumer,
            let paneId = tracePaneId,
            let expected = pendingTraceSequence else { return nil }
        return SurfaceConsumerTrace(
            paneId: paneId,
            sink: sink,
            delayNanoseconds: SurfaceTraceSink.consumerDelayNanoseconds,
            expectedTraceId: expected
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: Input

    /// AppKit calls this to fetch the contextual menu just before
    /// popping it up. Take the opportunity to make this content
    /// view first responder so the menu's `nil`-target items
    /// dispatch through THIS pane's responder chain. Without
    /// this, a right-click on a backgrounded sim leaves whichever
    /// pane was already focused as first responder, and the
    /// context menu's actions end up targeting the wrong sim VC.
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        cancelLongPressHold()
        liveTouchIsEdgeGesture = false
        let viewPoint = convert(event.locationInWindow, from: nil)
        // Option-drag → live two-finger pinch/rotate, center-anchored
        // (Simulator.app's affordance). Latched here for the whole drag;
        // explicit Option wins over the crown bump. The first `.down`
        // isn't sent until the drag crosses the tap threshold, so a bare
        // Option-click does nothing. Option+Shift could relocate the
        // focal point off-center in a future revision.
        if event.modifierFlags.contains(.option),
            inputDelegate?.simulatorPaneSupportsMultitouchInput == true,
            let origin = normalizedTouchPoint(for: event) {
            multitouchArmed = true
            multitouchActive = false
            dragStart = origin
            dragStartTime = Date()
            return
        }
        // Watch Digital Crown takes precedence over both the
        // screen gesture and the bezel-extended gesture. The crown
        // bump sits inside the bezel area but isn't a touch
        // surface. Clicks here drive `onCrownPress` on the
        // wrapper (which routes to `pressButton(.digitalCrown)`)
        // and vertical drags fire detents. Without this branch,
        // a click on the painted crown would be captured as an
        // off-screen swipe by the `isPointInBezel` path below.
        if isPointInCrown(viewPoint) {
            crownDragActive = true
            crownDragAccumulator = 0
            crownDragMoved = false
            return
        }
        if let normalized = SimGestureMath.normalizedPoint(
            viewPoint: viewPoint,
            viewSize: bounds.size,
            surfaceSize: surfaceSize,
            orientation: orientation,
            displayInset: displayInset
        ) {
            dragStart = normalized
            dragStartTime = Date()
            liveTouchIsEdgeGesture = isEdgeGestureStart(viewPoint: viewPoint)
            scheduleLongPressHold(at: normalized, isEdgeGesture: liveTouchIsEdgeGesture)
            return
        }
        // Outside the screen rect, accept the gesture start only
        // when the click landed inside the bezel area. This is the
        // path the iOS app-switcher swipe rides on: the user
        // presses the bezel below the bottom edge and drags up
        // into the screen. `extendedNormalizedPoint` produces
        // out-of-[0,1] coords (e.g., y > 1), which the daemon's
        // HID contract accepts as off-screen input.
        guard isPointInBezel(viewPoint),
            let extended = SimGestureMath.extendedNormalizedPoint(
                viewPoint: viewPoint,
                viewSize: bounds.size,
                surfaceSize: surfaceSize,
                orientation: orientation,
                displayInset: displayInset
            )
        else { return }
        dragStart = extended
        dragStartTime = Date()
        liveTouchIsEdgeGesture = isEdgeGestureStart(viewPoint: viewPoint)
    }

    /// Whether a drag starting at `viewPoint` should drive the system
    /// edge gesture rather than a plain touch. True only when the pane
    /// supports live edge gestures and the start sits in the displayed
    /// bottom-edge band.
    ///
    /// The daemon resolves and latches the tag with
    /// `AppSwitcherGesture.edge(for:)`, rotating the drag's events
    /// through that same orientation.
    private func isEdgeGestureStart(viewPoint: CGPoint) -> Bool {
        guard inputDelegate?.simulatorPaneSupportsEdgeGesture == true,
            let displayed = SimGestureMath.extendedNormalizedPoint(
                viewPoint: viewPoint,
                viewSize: bounds.size,
                surfaceSize: surfaceSize,
                orientation: orientation,
                displayInset: displayInset
            )
        else { return false }
        return SimGestureMath.isInBottomEdgeBand(orientedY: displayed.y)
    }

    /// Arm the stationary-hold timer for a press that landed on-screen at
    /// `point` (carrying `edge` if it began in the bottom-edge band). After
    /// the long-press threshold, if no drag, multitouch, crown, or release
    /// has intervened, promote the press to a live `.down` so a finger is
    /// held down on the sim. The VM's keepalive then sustains the contact,
    /// matching iOS's long-press. Replaces any previously-armed timer.
    private func scheduleLongPressHold(at point: CGPoint, isEdgeGesture: Bool) {
        cancelLongPressHold()
        guard inputDelegate?.simulatorPaneSupportsLiveTouchInput == true else { return }
        longPressHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.longPressHoldThresholdNs)
            guard let self,
                !Task.isCancelled,
                self.dragStart != nil,
                !self.liveTouchActive,
                !self.multitouchActive,
                !self.crownDragActive
            else { return }
            self.liveTouchActive = true
            self.inputDelegate?.simulatorPaneDidTouch(at: point, phase: .down, isEdgeGesture: isEdgeGesture)
        }
    }

    private func cancelLongPressHold() {
        longPressHoldTask?.cancel()
        longPressHoldTask = nil
    }

    override func mouseDragged(with event: NSEvent) {
        if multitouchArmed,
            let start = dragStart,
            let current = normalizedTouchPoint(for: event),
            multitouchActive || !SimGestureMath.isTap(from: start, to: current) {
            let anchor = Self.multitouchAnchor
            if !multitouchActive {
                cancelLongPressHold()
                multitouchActive = true
                // Land both fingers at the press point first (initial
                // contact), then stream movement, the same shape as the
                // single-finger live path's `.down` at `start`.
                inputDelegate?.simulatorPaneDidMultitouch(
                    phase: .down,
                    finger1: start,
                    finger2: SimGestureMath.mirroredPoint(anchor: anchor, current: start)
                )
            }
            inputDelegate?.simulatorPaneDidMultitouch(
                phase: .move,
                finger1: current,
                finger2: SimGestureMath.mirroredPoint(anchor: anchor, current: current)
            )
            updateMultitouchOverlay(for: event)
            return
        }
        if inputDelegate?.simulatorPaneSupportsLiveTouchInput == true,
            let start = dragStart,
            let point = normalizedTouchPoint(for: event),
            liveTouchActive || !SimGestureMath.isTap(from: start, to: point) {
            if !liveTouchActive {
                cancelLongPressHold()
                liveTouchActive = true
                inputDelegate?.simulatorPaneDidTouch(at: start, phase: .down, isEdgeGesture: liveTouchIsEdgeGesture)
            }
            inputDelegate?.simulatorPaneDidTouch(at: point, phase: .move, isEdgeGesture: false)
            return
        }
        // A press that began on-screen but is now dragged off both the
        // screen and the bezel yields a nil normalized point, so the
        // live-touch branch above can't engage, yet the pointer has moved
        // far beyond the tap threshold (it left the device frame entirely).
        // Cancel the pending long-press hold; otherwise it fires a spurious
        // .down at the origin and swallows the swipe on mouseUp.
        if longPressHoldTask != nil, !liveTouchActive, dragStart != nil,
            normalizedTouchPoint(for: event) == nil {
            cancelLongPressHold()
        }
        guard crownDragActive else { return }
        // Content view is `isFlipped = true`, so `deltaY > 0` is
        // the user dragging DOWN in screen space; conventionally
        // a watch crown rotated DOWN scrolls content DOWN, so the
        // sign maps direct without flipping. Accumulate detents
        // until the threshold is crossed.
        if event.deltaY != 0 {
            crownDragMoved = true
        }
        crownDragAccumulator += event.deltaY
        while crownDragAccumulator >= Self.crownDragDetentPoints {
            (superview as? SimulatorPaneWrapperView)?.onCrownDown()
            crownDragAccumulator -= Self.crownDragDetentPoints
        }
        while crownDragAccumulator <= -Self.crownDragDetentPoints {
            (superview as? SimulatorPaneWrapperView)?.onCrownUp()
            crownDragAccumulator += Self.crownDragDetentPoints
        }
    }

    override func mouseUp(with event: NSEvent) {
        cancelLongPressHold()
        if multitouchArmed {
            let wasActive = multitouchActive
            multitouchArmed = false
            multitouchActive = false
            dragStart = nil
            dragStartTime = nil
            clearMultitouchOverlay()
            // Always release if a `.down` was sent, because a dropped `.lift`
            // would strand a two-finger contact. A bare Option-click
            // (never activated) sends nothing.
            if wasActive {
                let anchor = Self.multitouchAnchor
                let endFinger1 = normalizedTouchPoint(for: event)
                    ?? SimGestureMath.unitClamped(
                        viewPoint: convert(event.locationInWindow, from: nil),
                        viewSize: bounds.size
                    )
                inputDelegate?.simulatorPaneDidMultitouch(
                    phase: .lift,
                    finger1: endFinger1,
                    finger2: SimGestureMath.mirroredPoint(anchor: anchor, current: endFinger1)
                )
            }
            return
        }
        if crownDragActive {
            crownDragActive = false
            // Treat as a press only when zero drag motion was
            // observed. The accumulator alone can't decide:
            // landing exactly on a detent boundary subtracts the
            // accumulator back to 0 even though the user clearly
            // rotated the crown, so a press-after-rotate would
            // spuriously fire Crown Press too.
            if !crownDragMoved {
                (superview as? SimulatorPaneWrapperView)?.onCrownPress()
            }
            crownDragAccumulator = 0
            crownDragMoved = false
            return
        }
        guard let start = dragStart, let startTime = dragStartTime else { return }
        dragStart = nil
        dragStartTime = nil
        let endNormalized = normalizedTouchPoint(for: event)
            ?? SimGestureMath.unitClamped(
                viewPoint: convert(event.locationInWindow, from: nil),
                viewSize: bounds.size
            )
        let durationMs = max(0, Int(Date().timeIntervalSince(startTime) * 1_000))
        let wasLiveTouch = liveTouchActive
        if wasLiveTouch {
            liveTouchActive = false
            inputDelegate?.simulatorPaneDidTouch(at: endNormalized, phase: .lift, isEdgeGesture: false)
            liveTouchIsEdgeGesture = false
        } else if SimGestureMath.isTap(from: start, to: endNormalized) {
            inputDelegate?.simulatorPaneDidTap(at: start)
        }
        if !wasLiveTouch, !SimGestureMath.isTap(from: start, to: endNormalized) {
            inputDelegate?.simulatorPaneDidSwipe(
                from: start,
                to: endNormalized,
                durationMs: max(durationMs, 16)
            )
        }
    }

    // A Command chord is the app's, never the guest's. So is any chord
    // the catalog binds: an item that validated disabled does not consume
    // its event, so the keystroke arrives here as an ordinary key press,
    // and forwarding it would type a shortcut into the device as HID. The
    // ⌃⇧ chords are the ones that reach this without Command.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || KeybindingCatalog.claims(event) {
            super.keyDown(with: event); return
        }
        inputDelegate?.simulatorPaneKeyDown(keyCode: event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || KeybindingCatalog.claims(event) {
            super.keyUp(with: event); return
        }
        inputDelegate?.simulatorPaneKeyUp(keyCode: event.keyCode)
    }

    override func magnify(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        switch event.phase {
        case .began:
            startGestureIfNeeded(at: viewPoint)

        case .changed:
            guard gestureActive else { return }
            gestureSeparation = SimGestureMath.scaledSeparation(
                gestureSeparation,
                by: event.magnification
            )

        case .ended, .cancelled:
            flushGesture()

        default:
            break
        }
    }

    override func rotate(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        switch event.phase {
        case .began:
            startGestureIfNeeded(at: viewPoint)

        case .changed:
            guard gestureActive else { return }
            gestureAngle += CGFloat(event.rotation) * .pi / 180.0

        case .ended, .cancelled:
            flushGesture()

        default:
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let mods = event.modifierFlags
        let cmd = mods.contains(.command)
        let opt = mods.contains(.option)
        guard cmd || opt else {
            // Bare scroll: route to the delegate's crown hook (the
            // VC family-gates: watch sims drive the crown, others
            // drop the event). Don't fall through to super: sim
            // panes don't host scrollable content, so propagation
            // is dead-weight, and consuming makes the gesture feel
            // owned by the pane regardless of family.
            let delta = SimGestureMath.crownDelta(
                scrollingDeltaY: event.scrollingDeltaY,
                precision: event.hasPreciseScrollingDeltas
            )
            inputDelegate?.simulatorPaneDidCrown(delta: delta)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        startGestureIfNeeded(at: viewPoint)
        guard gestureActive else { return }
        let deltaY = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY : event.deltaY * 8
        if cmd {
            gestureSeparation = SimGestureMath.scaledSeparation(
                gestureSeparation,
                by: deltaY / 200.0
            )
        } else if opt {
            gestureAngle += deltaY / 180.0
        }
        scrollGestureTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushGesture() }
        scrollGestureTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(200),
            execute: work
        )
    }

    // MARK: - Helpers

    /// Paint the multitouch affordance for the current mouse position.
    /// Drawn in view space: the anchor is the rendered screen's center
    /// (reflection about it commutes with the affine view↔surface map, so
    /// this stays consistent with the surface-space HID fingers). The
    /// mouse is finger 1; finger 2 is its reflection about the anchor.
    private func updateMultitouchOverlay(for event: NSEvent) {
        guard let imageRect = SimGestureMath.imageRect(
            viewSize: bounds.size,
            surfaceSize: surfaceSize,
            orientation: orientation,
            displayInset: displayInset
        ) else {
            multitouchOverlayLayer.isHidden = true
            return
        }
        let anchor = CGPoint(x: imageRect.midX, y: imageRect.midY)
        let finger1 = convert(event.locationInWindow, from: nil)
        let finger2 = CGPoint(x: anchor.x * 2 - finger1.x, y: anchor.y * 2 - finger1.y)
        let path = CGMutablePath()
        path.move(to: finger1)
        path.addLine(to: finger2)
        let dots: [(center: CGPoint, radius: CGFloat)] = [(finger1, 7), (finger2, 7), (anchor, 4)]
        for (center, radius) in dots {
            path.addEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        multitouchOverlayLayer.frame = bounds
        multitouchOverlayLayer.path = path
        multitouchOverlayLayer.isHidden = false
        CATransaction.commit()
    }

    private func clearMultitouchOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        multitouchOverlayLayer.isHidden = true
        multitouchOverlayLayer.path = nil
        CATransaction.commit()
    }

    private func normalizedTouchPoint(for event: NSEvent) -> CGPoint? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let inScreen = SimGestureMath.normalizedPoint(
            viewPoint: viewPoint,
            viewSize: bounds.size,
            surfaceSize: surfaceSize,
            orientation: orientation,
            displayInset: displayInset
        ) {
            return inScreen
        }
        if isPointInBezel(viewPoint),
            let extended = SimGestureMath.extendedNormalizedPoint(
                viewPoint: viewPoint,
                viewSize: bounds.size,
                surfaceSize: surfaceSize,
                orientation: orientation,
                displayInset: displayInset
            ) {
            return extended
        }
        return nil
    }

    /// Whether `viewPoint` is inside the wrapper's currently-painted
    /// device-frame bezel (and therefore a valid gesture origin for
    /// off-screen swipes). Returns false when no bezel is painted
    /// (tv / non-rendering states), or when the wrapper isn't the
    /// superview. Both are safe defaults for the gating in mouseDown
    /// / mouseUp.
    private func isPointInBezel(_ viewPoint: NSPoint) -> Bool {
        guard let wrapper = superview as? SimulatorPaneWrapperView,
            let bezel = wrapper.contentLocalBezelRect() else { return false }
        return bezel.contains(viewPoint)
    }

    /// Whether `viewPoint` is inside the wrapper's watch Digital
    /// Crown rect. The wrapper's `currentCrownRect` is in the
    /// bezel-view coordinate space, which (because bezelView is
    /// constraint-pinned to this view and shares `isFlipped`)
    /// matches this view's local coordinates directly. A 4pt
    /// inset on both axes widens the hit region so the click
    /// target isn't pixel-tight at small watch sizes.
    private func isPointInCrown(_ viewPoint: NSPoint) -> Bool {
        guard let wrapper = superview as? SimulatorPaneWrapperView else { return false }
        let crown = wrapper.currentCrownRect
        guard !crown.isEmpty else { return false }
        return crown.insetBy(dx: -4, dy: -4).contains(viewPoint)
    }

    private func startGestureIfNeeded(at viewPoint: NSPoint) {
        if gestureActive { return }
        guard let center = SimGestureMath.normalizedPoint(
            viewPoint: viewPoint,
            viewSize: bounds.size,
            surfaceSize: surfaceSize,
            orientation: orientation,
            displayInset: displayInset
        )
        else { return }
        gestureCenter = center
        gestureSeparation = SimGestureMath.pinchInitialSeparation
        gestureAngle = 0
        gestureActive = true
        gestureStartTime = Date()
        let (finger1, finger2) = SimGestureMath.fingers(
            center: gestureCenter,
            separation: gestureSeparation,
            angle: gestureAngle
        )
        gestureStartF1 = finger1
        gestureStartF2 = finger2
    }

    private func flushGesture() {
        guard gestureActive else { return }
        let (endF1, endF2) = SimGestureMath.fingers(
            center: gestureCenter,
            separation: gestureSeparation,
            angle: gestureAngle
        )
        let durationMs: Int = gestureStartTime.map {
            max(16, Int(Date().timeIntervalSince($0) * 1_000))
        } ?? 200
        gestureActive = false
        gestureStartTime = nil
        inputDelegate?.simulatorPaneDidPinch(
            fromF1: gestureStartF1,
            fromF2: gestureStartF2,
            toF1: endF1,
            toF2: endF2,
            durationMs: durationMs
        )
    }
}
