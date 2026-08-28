// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Terminal pane root view that paints a
/// focus border when the pane (chrome strip + libghostty surface)
/// holds keyboard focus. Shares `PaneFocusTracker` with
/// `SimulatorPaneWrapperView`, so both pane types derive focus from the
/// same responder-chain query.
@MainActor
final class TerminalPaneWrapperView: NSView {
    /// Resolves focus from the window's responder chain; see
    /// `PaneFocusTracker` for why the chain is the only authority here.
    private let focusTracker = PaneFocusTracker()
    /// Gate the focus border. The layout controller flips this off
    /// for a tab that holds only one pane (no rearrange affordances
    /// apply, so the ring is just visual noise) and on for any
    /// multi-pane tab. Re-applies the current focused state when
    /// flipped so the visible border tracks the gate immediately.
    var focusBorderEnabled: Bool = true {
        didSet { applyFocusVisible() }
    }
    /// Fires on each resolved focus change, with the new state. The
    /// owning `TerminalPaneViewController` forwards the true edge to
    /// the tab controller so `TabState.lastFocusedTerminal` follows
    /// the user's actual typing target; the spawning-terminal
    /// heuristic for sim placement reads that field. The tracker
    /// reports only changes, so a repeated focus-true observation pass
    /// doesn't re-fire.
    var onFocusChange: ((Bool) -> Void)?
    /// The descendant that should actually hold first responder when
    /// something focuses this pane by its root view: libghostty's
    /// surface, set by the owning VC. See `becomeFirstResponder`.
    weak var inputTarget: NSView?

    /// Mirrors `SimulatorPaneWrapperView`. Both pane roots are what the
    /// layout controller hands to `makeFirstResponder`, so both have to
    /// accept and forward, or the pane would sit outside the key-view
    /// loop while claiming focus.
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Establish layer backing BEFORE libghostty installs its
        // CAMetalLayer-hosting surface as a deep descendant. The
        // focus border path also needs `wantsLayer = true` to draw,
        // but setting it lazily on first focus would flip the
        // layer-backing mode mid-life (after the Metal surface has
        // already mounted). Setting it eagerly here lets the layer
        // tree settle in one shape and stay there.
        wantsLayer = true
        // Round the border so it traces the window's bottom-corner
        // arc when the pane sits at the window edge. `masksToBounds`
        // stays false so the layer doesn't clip libghostty's
        // CAMetalLayer to the rounded path; only the drawn border
        // follows the corner radius.
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        // Publish the pane as a group in the accessibility tree.
        // AppKit prunes a plain `NSView` and promotes its children, so
        // without this the identifier the layout controller assigns
        // would never reach a dump. `.group` keeps the descendants
        // exposed rather than collapsing the pane into a leaf.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        focusTracker.onFocusChange = { [weak self] focused in
            guard let self else { return }
            applyFocusVisible()
            onFocusChange?(focused)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTracker.viewDidMoveToWindow(self)
    }

    /// Hand first responder down to libghostty's surface.
    ///
    /// `makeFirstResponder` does not consult `acceptsFirstResponder`, so
    /// without this the wrapper itself becomes first responder whenever
    /// the layout controller focuses a pane by its root view. The pane
    /// then draws its focus ring and reports `AXFocused` while every
    /// keystroke walks past it up the responder chain: focused to look
    /// at, dead to type into. `SimulatorPaneWrapperView` forwards for
    /// the same reason.
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

    /// Paint the effective focus state (focused ∧ enabled). Same
    /// shape and color source as `SimulatorPaneWrapperView` so both
    /// pane types read as one design system: 1pt border in the
    /// user's ghostty `selection-background` color (which the
    /// in-terminal text selection also uses), with
    /// `NSColor.controlAccentColor` as the fallback when the ghostty
    /// config doesn't set the key. Layer backing + corner radius are
    /// established in `init` so this just mutates border properties.
    private func applyFocusVisible() {
        let effective = focusTracker.isFocused && focusBorderEnabled
        layer?.borderWidth = effective ? 1 : 0
        let color = GhosttyThemeColors.cachedSelectionBackground()
            ?? NSColor.controlAccentColor
        layer?.borderColor = effective ? color.cgColor : NSColor.clear.cgColor
    }
}
