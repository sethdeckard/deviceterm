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
    }

    /// The input-target subview that should actually own first-
    /// responder status when the wrapper is asked for it.
    weak var inputTarget: NSView?
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
    /// re-runs its layout pass on assignment.
    var bezelContext: BezelContext = .init() {
        didSet { needsLayout = true }
    }
    /// Watch Digital Crown handlers, wired by the VC to the same
    /// VM closures the chrome ribbon's crown buttons already
    /// dispatch to. Click on the crown bump → `onCrownPress`;
    /// vertical drag → `onCrownUp / onCrownDown` per detent.
    var onCrownPress: () -> Void = {}
    var onCrownUp: () -> Void = {}
    var onCrownDown: () -> Void = {}

    private var currentFocused = false
    private let bezelView = LayerBackedView()
    private let bezelShapeLayer = CAShapeLayer()
    private let notchLayer = CAShapeLayer()
    private let crownLayer = CAShapeLayer()
    /// Pane-local rect the crown bump occupies, read by
    /// `SimulatorContentView` so a click on the crown lights up
    /// the wrapper's `onCrownPress` instead of starting an
    /// off-screen gesture. `.zero` means no crown (non-watch).
    /// Coordinates match the content view's bounds (bezelView is
    /// constraint-pinned to the content view + same `isFlipped`).
    private(set) var currentCrownRect: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }

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
        // notch/crown sublayers paint a touch darker for visual
        // separation against the bezel.
        bezelShapeLayer.fillColor = NSColor(white: 0.15, alpha: 1).cgColor
        notchLayer.fillColor = NSColor(white: 0.08, alpha: 1).cgColor
        crownLayer.fillColor = NSColor(white: 0.08, alpha: 1).cgColor
        bezelShapeLayer.isHidden = true
        notchLayer.isHidden = true
        crownLayer.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

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
    /// can assert which pane a focus shortcut landed on. Answers from
    /// the responder chain rather than from `currentFocused`, which
    /// tracks the drawn border: the border is gated by
    /// `focusBorderEnabled`, and it is pushed in by the pane VC rather
    /// than observed, so it can lag the real responder.
    override func isAccessibilityFocused() -> Bool {
        containsFirstResponder()
    }

    /// Record the caller's intent. The effective border
    /// (intent ∧ `focusBorderEnabled`) is applied by
    /// `applyFocusVisible()` so the gate can re-evaluate without the
    /// caller re-asserting focus.
    func setFocusVisible(_ focused: Bool) {
        currentFocused = focused
        applyFocusVisible()
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
            imageRect: image
        )?.bezelRect
    }

    /// Paint the effective focus state (focused ∧ enabled). Wraps the
    /// entire pane (chrome strip + Metal sim area), because a SwiftUI ring
    /// inside the chrome host would only surround the strip. Color
    /// comes from `GhosttyThemeColors` so the focus ring matches the
    /// user's terminal text-selection color (and the drag drop
    /// overlay); fallback to `NSColor.controlAccentColor` when the
    /// ghostty config doesn't set `selection-background`.
    private func applyFocusVisible() {
        let effective = currentFocused && focusBorderEnabled
        layer?.borderWidth = effective ? 1 : 0
        let color = GhosttyThemeColors.cachedSelectionBackground()
            ?? NSColor.controlAccentColor
        layer?.borderColor = effective ? color.cgColor : NSColor.clear.cgColor
    }

    /// Attach the bezel/notch/crown CAShapeLayers to the bezel
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
        bezelLayer.addSublayer(notchLayer)
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
            content.setDisplayFrame(inset: 0, screenCornerRadius: 0)
            return
        }
        let inset = DeviceBezelLayoutMath.maxBezelInset(family: bezelContext.family)
        // Inner corner radius: outer bezel radius minus the inset.
        // Use a probe image rect to compute the would-be outer
        // radius for this family + bounds without circularly
        // re-running the full layout. Falls back to 0 when no
        // bezel layout is produced (tv).
        guard let probeImage = SimGestureMath.imageRect(
            viewSize: bezelView.bounds.size,
            surfaceSize: bezelContext.surfaceSize,
            orientation: bezelContext.orientation,
            displayInset: inset
        ),
            let layout = DeviceBezelLayoutMath.layout(
                family: bezelContext.family,
                imageRect: probeImage
            ) else {
            content.setDisplayFrame(inset: 0, screenCornerRadius: 0)
            return
        }
        content.setDisplayFrame(
            inset: inset,
            screenCornerRadius: max(0, layout.cornerRadius - inset)
        )
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
                imageRect: imageRect
            ) else {
            bezelShapeLayer.isHidden = true
            notchLayer.isHidden = true
            crownLayer.isHidden = true
            currentCrownRect = .zero
            return
        }
        // CALayer animations + frame changes battle here, so disable
        // implicit animations so a divider drag doesn't slide the
        // bezel through several intermediate sizes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bezelShapeLayer.isHidden = false
        bezelShapeLayer.path = CGPath(
            roundedRect: layout.bezelRect,
            cornerWidth: layout.cornerRadius,
            cornerHeight: layout.cornerRadius,
            transform: nil
        )
        if let notch = layout.notchRect, let radius = layout.notchCornerRadius {
            notchLayer.isHidden = false
            notchLayer.path = CGPath(
                roundedRect: notch,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        } else {
            notchLayer.isHidden = true
        }
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
