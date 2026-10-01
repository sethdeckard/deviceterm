// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol

/// The sim pane's AppKit root view,
/// holding the SwiftUI chrome strip, a layer-backed device-frame
/// (bezel) view, and the Metal content view as siblings. The
/// subclass exists for two reasons:
///
///   1. When `PaneLayoutViewController` swaps the focused sim pane with
///      a neighbor (⌘⇧← / ⌘⇧→), it restores keyboard focus by
///      calling `window?.makeFirstResponder(focused.view)`. The view
///      it sees is the pane VC's root, and a plain `NSView` defaults
///      `acceptsFirstResponder` to false, so the post-swap pane would
///      silently lose keyboard focus and responder-chain
///      participation.
///
///   2. Painting the device-frame bezel that sits behind the
///      transparent Metal letterbox. Per-family geometry comes from
///      `DeviceBezelLayoutMath`; the wrapper owns the layout pass +
///      layer updates so the bezel re-fits on every pane resize.
///
/// Input still lives on the Metal-hosting `SimulatorContentView`
/// referenced by `inputTarget`. `becomeFirstResponder` forwards
/// there. The watch Digital Crown is hit-tested by the content
/// view against `currentCrownRect` (published by the wrapper) and
/// routes click/drag through the `onCrownPress` / `onCrownUp` /
/// `onCrownDown` closures the wrapper exposes.
@MainActor
final class SimulatorPaneWrapperView: NSView {
    /// Snapshot of the inputs the bezel layout depends on. The VC
    /// rebuilds this struct on every render() pass; the wrapper
    /// only re-lays-out when one of the fields differs from the
    /// previous value (the struct's `Equatable` conformance gates
    /// the change via the property's `didSet`).
    struct BezelContext: Equatable, Sendable {
        var family: DeviceFamily = .unknown
        var surfaceSize: CGSize = .zero
        var orientation: Orientation = .portrait
        /// Whether the device folds at all, which is what separates a
        /// foldable's cover panel from an ordinary phone's only display.
        /// The two are the same shape on the wire and a very different
        /// shape on the device.
        var foldable = false
        /// Whether the panel on show is the one the hinge runs through, which
        /// decides whether this device frame carries a fold at all.
        var spansHinge = false
        /// How far that fold is bent, or nil when the panel is flat.
        var crease: FoldCreaseGeometry.Crease?
    }

    /// The input-target subview that should actually own first-
    /// responder status when the wrapper is asked for it.
    weak var inputTarget: NSView?
    /// Fires on each resolved focus change, with the new state. The
    /// owning VC mirrors it into the chrome's view model, where SwiftUI
    /// reads it for the title brightening.
    var onFocusChange: ((Bool) -> Void)?
    /// Gate the focus border. The layout controller flips this off
    /// when the tab holds only one pane so the ring doesn't draw
    /// over a non-rearrangeable surface, and on for any multi-pane
    /// tab. Re-applies the current focused state when flipped.
    var focusBorderEnabled: Bool = true {
        didSet { applyFocusVisible() }
    }
    /// Pushed by the VC on every render. The bezel reshapes
    /// whenever the device family arrives, the IOSurface
    /// dimensions change, or the device rotates. The wrapper
    /// re-runs its layout pass only when the context changes:
    /// render runs on every frame, and a layout pass per frame
    /// starves the main thread while several panes animate.
    var bezelContext: BezelContext = .init() {
        didSet {
            if bezelContext != oldValue { needsLayout = true }
        }
    }
    /// Watch Digital Crown handlers, wired by the VC to the same
    /// VM closures the chrome ribbon's crown buttons already
    /// dispatch to. Click on the crown bump → `onCrownPress`;
    /// vertical drag → `onCrownUp / onCrownDown` per detent.
    var onCrownPress: () -> Void = {}
    var onCrownUp: () -> Void = {}
    var onCrownDown: () -> Void = {}

    /// Resolves focus from the window's responder chain; see
    /// `PaneFocusTracker` for why the chain is the only authority here.
    private let focusTracker = PaneFocusTracker()
    private let bezelView = LayerBackedView()
    private let bezelShapeLayer = CAShapeLayer()
    private let crownLayer = CAShapeLayer()
    /// Pane-local rect the crown bump occupies, read by
    /// `SimulatorContentView` so a click on the crown lights up
    /// the wrapper's `onCrownPress` instead of starting an
    /// off-screen gesture. `.zero` means no crown (non-watch).
    /// Coordinates match the content view's bounds (bezelView is
    /// constraint-pinned to the content view + same `isFlipped`).
    private(set) var currentCrownRect: CGRect = .zero
    /// The bent outline last painted, when the panel is creased. Held so the
    /// gesture-capturing region is the shape on screen rather than the flat
    /// rect it was cut from: once the halves turn away, that rect covers pane
    /// background the device no longer occupies.
    private var currentCreasedBezelPath: CGPath?

    override var acceptsFirstResponder: Bool { true }

    /// Which of the device's panels this pane is framing.
    ///
    /// Read everywhere the layout is computed rather than passed around, so
    /// the painted outline, the hit-tested rect and the screen's rounded
    /// corners cannot be built from different panels.
    private var bezelPanel: DeviceBezelLayoutMath.Panel {
        guard bezelContext.foldable else { return .standard }
        return bezelContext.spansHinge ? .foldableInner : .foldableCover
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Eager layer backing + rounded corners so the focus border
        // traces the window's bottom-corner arc when the pane sits
        // at the window edge. `masksToBounds` stays false so we
        // don't clip the Metal sim view to the rounded path; only
        // the drawn border follows the corner radius.
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        // Publish the pane as a group in the accessibility tree. AppKit
        // prunes a plain `NSView` and promotes its children, so without
        // this the identifier the layout controller assigns would never
        // reach a dump. `.group` keeps the descendants exposed rather
        // than collapsing the pane into a leaf.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        bezelView.translatesAutoresizingMaskIntoConstraints = false
        bezelView.wantsLayer = true
        // NOTE: `bezelView.layer` is nil at this point. `wantsLayer
        // = true` schedules layer creation but doesn't create it
        // immediately. `masksToBounds` is set inside
        // `installBezelSublayersIfNeeded()` so it actually takes
        // effect once AppKit materializes the layer.
        // Bezel fill: dark neutral that reads on top of the
        // ghostty bg without clashing with the focus border. The
        // crown sublayer paints a touch darker for visual
        // separation against the bezel.
        bezelShapeLayer.fillColor = NSColor(white: 0.15, alpha: 1).cgColor
        crownLayer.fillColor = NSColor(white: 0.08, alpha: 1).cgColor
        bezelShapeLayer.isHidden = true
        crownLayer.isHidden = true

        focusTracker.onFocusChange = { [weak self] focused in
            guard let self else { return }
            applyFocusVisible()
            onFocusChange?(focused)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Re-arm the focus tracker whenever the pane's window changes.
    /// This is what clears the ring when a tab switch pulls the pane
    /// out of the window: AppKit drops the first responder without
    /// delivering `resignFirstResponder`, so nothing else would.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTracker.viewDidMoveToWindow(self)
    }

    /// Insert the bezel view into the hierarchy BELOW the Metal
    /// content view. Callable from the VC after both subviews are
    /// added (the VC keeps subview ordering authoritative).
    func installBezelLayer(belowContentView contentView: NSView) {
        addSubview(bezelView, positioned: .below, relativeTo: contentView)
        NSLayoutConstraint.activate([
            bezelView.topAnchor.constraint(equalTo: contentView.topAnchor),
            bezelView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bezelView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bezelView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    override func becomeFirstResponder() -> Bool {
        guard let target = inputTarget,
            target.acceptsFirstResponder,
            let window else {
            return super.becomeFirstResponder()
        }
        return window.makeFirstResponder(target)
    }

    /// Report focus to the accessibility tree, so the UI-test harness
    /// can assert which pane a focus shortcut landed on. Answers the
    /// chain directly so accessibility reflects current focus without
    /// waiting for the tracker's next refresh.
    override func isAccessibilityFocused() -> Bool {
        containsFirstResponder()
    }

    /// Recompute bezel geometry from the current bounds + context.
    /// Cheap on a steady state, since the `bezelContext.didSet` only
    /// flags layout when the inputs actually change.
    override func layout() {
        super.layout()
        applyBezel()
    }

    /// The screen rect inside the content (Metal) region. Uses
    /// the same letterbox math the shader does so the bezel sits
    /// exactly around the rendered screen. Includes the
    /// family's bezel inset so the screen leaves margin for the
    /// bezel on all sides. Returns nil when the surface hasn't
    /// bound yet (no bezel can be drawn without knowing where
    /// the screen lives).
    func currentImageRect() -> CGRect? {
        let inset = DeviceBezelLayoutMath.maxBezelInset(family: bezelContext.family)
        return SimGestureMath.imageRect(
            viewSize: bezelView.bounds.size,
            surfaceSize: bezelContext.surfaceSize,
            orientation: bezelContext.orientation,
            displayInset: inset
        )
    }

    /// The bezel rect in the content view's coordinate space.
    /// `bezelView` is constraint-pinned to the Metal content view
    /// and shares its `isFlipped = true`, so bezelView-local
    /// coordinates and content-view-local coordinates are
    /// identical, so no translation is needed. Used by the content
    /// view's mouseDown to decide whether a click outside the
    /// screen rect is still inside the gesture-capturing region.
    func contentLocalBezelRect() -> CGRect? {
        guard let image = currentImageRect() else { return nil }
        return DeviceBezelLayoutMath.layout(
            family: bezelContext.family,
            imageRect: image,
            panel: bezelPanel,
            orientation: bezelContext.orientation
        )?.bezelRect
    }

    /// Whether `point` is on the device frame, in the content view's space.
    ///
    /// Follows the painted outline on a creased panel and the plain rect
    /// otherwise, so a click beside a folded device lands on the pane rather
    /// than reaching the guest as an off-screen gesture. A flat device is
    /// hit-tested against its rectangle, corner regions included.
    func bezelContains(_ point: CGPoint) -> Bool {
        if let path = currentCreasedBezelPath {
            return path.contains(point)
        }
        return contentLocalBezelRect()?.contains(point) ?? false
    }

    /// Paint the effective focus state (focused ∧ enabled). Wraps the
    /// entire pane (chrome strip + Metal sim area), because a SwiftUI ring
    /// inside the chrome host would only surround the strip. Color
    /// comes from `GhosttyThemeColors` so the focus ring matches the
    /// user's terminal text-selection color (and the drag drop
    /// overlay); fallback to `NSColor.controlAccentColor` when the
    /// ghostty config doesn't set `selection-background`.
    private func applyFocusVisible() {
        let effective = focusTracker.isFocused && focusBorderEnabled
        layer?.borderWidth = effective ? 1 : 0
        let color = GhosttyThemeColors.cachedSelectionBackground()
            ?? NSColor.controlAccentColor
        layer?.borderColor = effective ? color.cgColor : NSColor.clear.cgColor
    }

    /// Attach the bezel/crown CAShapeLayers to the bezel
    /// view's backing layer. Called from `applyBezel` on each
    /// layout pass; idempotent, early-returning once attached.
    /// Doing it lazily (not in `init`) sidesteps the
    /// `wantsLayer`-vs-`makeBackingLayer` ordering: by the time
    /// `layout()` fires, the view is in a window and AppKit has
    /// materialized `bezelView.layer`.
    private func installBezelSublayersIfNeeded() {
        guard let bezelLayer = bezelView.layer,
            bezelShapeLayer.superlayer == nil else { return }
        // The bezel CAShapeLayer's rounded-rect path extends
        // OUTWARD from the screen rect by the family's inset
        // (8–24pt). When the rendered screen reaches the
        // bezelView's edges (tall portrait in a tall pane), the
        // bezel path would paint outside the layer's bounds,
        // into the chrome strip above and the divider below.
        // Clip to bounds so overflow is dropped; in the typical
        // letterboxed case there's plenty of inside room and the
        // full bezel is visible. (The wrapper's own layer stays
        // unclipped, since its focus border traces the window's
        // bottom-corner arc and needs to draw past its bounds.)
        bezelLayer.masksToBounds = true
        bezelLayer.addSublayer(bezelShapeLayer)
        bezelLayer.addSublayer(crownLayer)
    }

    /// Push the family-derived display frame (bezel inset + screen
    /// corner radius) to the Metal content view so its shader
    /// shrinks the aspect-fit by the inset (leaving margin for the
    /// bezel on all sides) and its layer mask rounds the screen
    /// corners. Computed from the same `DeviceBezelLayoutMath`
    /// the wrapper uses for its own bezel painting so the two
    /// stay in sync.
    private func pushDisplayFrameToContent() {
        guard let content = inputTarget as? SimulatorContentView else { return }
        guard bezelView.bounds.width > 0, bezelView.bounds.height > 0 else {
            content.setDisplayFrame(inset: 0, screenCorners: .square)
            return
        }
        let inset = DeviceBezelLayoutMath.maxBezelInset(family: bezelContext.family)
        // Use a probe image rect to size the panel's own rounding for this
        // family + bounds without circularly re-running the full layout.
        // Falls back to 0 when no bezel layout is produced (tv).
        guard let probeImage = SimGestureMath.imageRect(
            viewSize: bezelView.bounds.size,
            surfaceSize: bezelContext.surfaceSize,
            orientation: bezelContext.orientation,
            displayInset: inset
        ),
            let layout = DeviceBezelLayoutMath.layout(
                family: bezelContext.family,
                imageRect: probeImage,
                panel: bezelPanel,
                orientation: bezelContext.orientation
            ) else {
            content.setDisplayFrame(inset: 0, screenCorners: .square)
            return
        }
        content.setDisplayFrame(
            inset: inset,
            screenCorners: layout.screenCornerRadii
        )
    }

    /// A rounded outline with a radius of its own at each corner, which
    /// `CGPath(roundedRect:)` cannot express.
    ///
    /// Traced from the top edge clockwise in this view's flipped
    /// coordinates, so `minY` is the top. Each radius yields to half the
    /// shorter side, past which the arcs would cross and the outline would
    /// stop being the rect.
    private func roundedPath(
        rect: CGRect,
        corners: DeviceBezelLayout.Corners
    ) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let topLeft = min(corners.topLeft, limit)
        let topRight = min(corners.topRight, limit)
        let bottomLeft = min(corners.bottomLeft, limit)
        let bottomRight = min(corners.bottomRight, limit)
        let topLeading = CGPoint(x: rect.minX, y: rect.minY)
        let topTrailing = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomTrailing = CGPoint(x: rect.maxX, y: rect.maxY)
        let bottomLeading = CGPoint(x: rect.minX, y: rect.maxY)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addArc(tangent1End: topTrailing, tangent2End: bottomTrailing, radius: topRight)
        path.addArc(tangent1End: bottomTrailing, tangent2End: bottomLeading, radius: bottomRight)
        path.addArc(tangent1End: bottomLeading, tangent2End: topLeading, radius: bottomLeft)
        path.addArc(tangent1End: topLeading, tangent2End: topTrailing, radius: topLeft)
        path.closeSubpath()
        return path
    }

    /// The device frame as two bent halves, drawn from the same `Crease` the
    /// renderer bends the picture with, so the frame cannot disagree with what
    /// it frames.
    ///
    /// One path with two subpaths rather than two layers: the bezel is a flat
    /// dark fill, and the shading that makes the fold read is the picture's.
    private func creasedBezelPath(
        layout: DeviceBezelLayout,
        imageRect: CGRect,
        crease: FoldCreaseGeometry.Crease
    ) -> CGPath {
        let vertical = FoldCreaseGeometry.creaseRunsVertically(in: bezelContext.orientation)
        let halves = FoldCreaseGeometry.halves(
            of: layout.bezelRect,
            foldedAbout: imageRect,
            crease: crease,
            vertical: vertical
        )
        let radii = layout.cornerRadii
        let path = CGMutablePath()
        // Each half keeps the two radii belonging to the side of the picture
        // it is, so a panel whose corners differ keeps them across the fold.
        // A vertical crease splits the picture left from right, so a half's
        // outer corners are the two down one side; a horizontal one splits
        // top from bottom.
        append(
            half: halves.leading,
            lowRadius: vertical ? radii.topLeft : radii.topLeft,
            highRadius: vertical ? radii.bottomLeft : radii.topRight,
            to: path
        )
        append(
            half: halves.trailing,
            lowRadius: vertical ? radii.topRight : radii.bottomLeft,
            highRadius: vertical ? radii.bottomRight : radii.bottomRight,
            to: path
        )
        return path
    }

    /// Trace one half: rounded at the two outer corners, square where it meets
    /// the crease, because the fold is a crease and not an edge.
    ///
    /// `lowRadius` belongs to the corner at the low end of the crease's
    /// along-axis and `highRadius` to the other, matching `HalfQuad`'s own
    /// `outerLow` and `outerHigh`.
    private func append(
        half: FoldCreaseGeometry.HalfQuad,
        lowRadius: CGFloat,
        highRadius: CGFloat,
        to path: CGMutablePath
    ) {
        func distance(_ start: CGPoint, _ end: CGPoint) -> CGFloat {
            hypot(end.x - start.x, end.y - start.y)
        }
        // A tangent arc wider than the edges it joins produces a shape that is
        // not the quad, so each radius yields to the shortest of them.
        let limit = min(
            distance(half.creaseLow, half.outerLow) / 2,
            distance(half.outerLow, half.outerHigh) / 2,
            distance(half.outerHigh, half.creaseHigh) / 2
        )
        let low = min(lowRadius, limit)
        let high = min(highRadius, limit)
        // Starting midway down the first edge, so the opening arc has the
        // run-up `addArc(tangent1End:…)` needs.
        path.move(
            to: CGPoint(
                x: (half.creaseLow.x + half.outerLow.x) / 2,
                y: (half.creaseLow.y + half.outerLow.y) / 2
            )
        )
        path.addArc(tangent1End: half.outerLow, tangent2End: half.outerHigh, radius: low)
        path.addArc(tangent1End: half.outerHigh, tangent2End: half.creaseHigh, radius: high)
        path.addLine(to: half.creaseHigh)
        path.addLine(to: half.creaseLow)
        path.closeSubpath()
    }

    private func applyBezel() {
        installBezelSublayersIfNeeded()
        pushDisplayFrameToContent()
        guard bezelView.bounds.width > 0,
            bezelView.bounds.height > 0,
            bezelContext.surfaceSize.width > 0,
            bezelContext.surfaceSize.height > 0,
            let imageRect = currentImageRect(),
            let layout = DeviceBezelLayoutMath.layout(
                family: bezelContext.family,
                imageRect: imageRect,
                panel: bezelPanel,
                orientation: bezelContext.orientation
            ) else {
            bezelShapeLayer.isHidden = true
            crownLayer.isHidden = true
            currentCrownRect = .zero
            currentCreasedBezelPath = nil
            return
        }
        // CALayer animations + frame changes battle here, so disable
        // implicit animations so a divider drag doesn't slide the
        // bezel through several intermediate sizes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bezelShapeLayer.isHidden = false
        currentCreasedBezelPath = bezelContext.crease.map {
            creasedBezelPath(layout: layout, imageRect: imageRect, crease: $0)
        }
        bezelShapeLayer.path = currentCreasedBezelPath ?? roundedPath(
            rect: layout.bezelRect,
            corners: layout.cornerRadii
        )
        if let crown = layout.crownRect, let radius = layout.crownCornerRadius {
            crownLayer.isHidden = false
            crownLayer.path = CGPath(
                roundedRect: crown,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            currentCrownRect = crown
        } else {
            crownLayer.isHidden = true
            currentCrownRect = .zero
        }
        CATransaction.commit()
    }
}

private extension SimulatorPaneWrapperView {
    /// Trivial layer-backed NSView used by the wrapper's bezel hosting.
    /// Splitting it out keeps the wrapper's own layer (which carries
    /// the focus border + corner radius) separate from the bezel's
    /// sublayer tree, so a focus-state flip doesn't repaint the bezel
    /// path and vice versa. `isFlipped = true` matches the
    /// `SimulatorContentView` (also flipped) so bezel-rect coords are
    /// directly comparable to content-view view points.
    @MainActor
    final class LayerBackedView: NSView {
        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    }
}
