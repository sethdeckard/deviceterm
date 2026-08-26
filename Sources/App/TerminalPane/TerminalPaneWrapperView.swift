// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Terminal pane root view that paints a
/// focus border when the pane (chrome strip + libghostty surface)
/// holds keyboard focus. Mirrors `SimulatorPaneWrapperView`'s
/// `setFocusVisible(_:)` so the two pane types share one focus
/// affordance.
///
/// Detecting first-responder transitions is the awkward part:
/// libghostty's surface view is the actual first responder when a
/// terminal pane has focus, and the surface is a foreign-module
/// view that deviceterm doesn't subclass. There's no `becomeFirstResponder`
/// hook to call back into deviceterm from. The portable signal AppKit
/// gives us is `NSWindow.didUpdateNotification`, which fires once per
/// event-loop after responder-chain state settles. We poll
/// `window.firstResponder` on that notification and toggle the border
/// only when the resolved focus state actually changes, so the
/// per-update callback is cheap.
@MainActor
final class TerminalPaneWrapperView: NSView {
    /// `nonisolated(unsafe)` because the nonisolated deinit needs to
    /// read it for cleanup (NSObjectProtocol isn't Sendable, so a
    /// plain @MainActor stored property would be unreachable from
    /// the deinit). All other access happens on the main actor via
    /// `viewDidMoveToWindow`, so the only off-isolation read is the
    /// deinit's snapshot, and NotificationCenter.removeObserver is
    /// thread-safe, so no synchronization is needed beyond that.
    nonisolated(unsafe) private var windowObserver: NSObjectProtocol?
    private var currentFocused = false
    /// Gate the focus border. The layout controller flips this off
    /// for a tab that holds only one pane (no rearrange affordances
    /// apply, so the ring is just visual noise) and on for any
    /// multi-pane tab. Re-applies the current focused state when
    /// flipped so the visible border tracks the gate immediately.
    var focusBorderEnabled: Bool = true {
        didSet { applyFocusVisible() }
    }
    /// Fires the first time focus arrives at the pane after losing
    /// it. The owning `TerminalPaneViewController` forwards this to
    /// the tab controller so `TabState.lastFocusedTerminal` follows
    /// the user's actual typing target; the spawning-terminal
    /// heuristic for sim placement reads that field. Only the
    /// false→true edge fires; repeated focus-true notifications
    /// from the same observation pass don't re-fire.
    var onFocusGained: (() -> Void)?
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Tear down the notification observer if the wrapper is
    /// dealloc'd while still attached to a window. AppKit doesn't
    /// reliably fire `viewDidMoveToWindow(nil)` when a window closes
    /// and its view tree is released wholesale, so the
    /// viewDidMoveToWindow path alone can leak one observer per
    /// pane lifecycle. NotificationCenter.removeObserver is thread-
    /// safe so the nonisolated deinit can call it directly.
    nonisolated deinit {
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
            windowObserver = nil
        }
        guard let window else {
            // View was removed from a window, so clear the visible
            // border so a re-mount starts clean.
            currentFocused = false
            setFocusVisible(false)
            return
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFocusFromResponderChain()
            }
        }
        refreshFocusFromResponderChain()
    }

    /// Read the window's current first responder, walk its superview
    /// chain to decide whether focus is *inside* this wrapper, and
    /// toggle the border iff the resolved focus state changed since
    /// the last check.
    private func refreshFocusFromResponderChain() {
        let focused = containsFirstResponder()
        guard focused != currentFocused else { return }
        setFocusVisible(focused)
        if focused {
            onFocusGained?()
        }
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
    /// can assert which pane a focus shortcut landed on. Answers from
    /// the responder chain rather than from `currentFocused`, which
    /// tracks the drawn border and is gated by `focusBorderEnabled`. A
    /// solo pane draws no ring but still holds focus.
    override func isAccessibilityFocused() -> Bool {
        containsFirstResponder()
    }

    /// Record the caller's intent. The responder-chain walk in
    /// `refreshFocusFromResponderChain` and the externally-driven
    /// path on `SimulatorPaneWrapperView` both route through here.
    /// The effective border (intent ∧ `focusBorderEnabled`) is
    /// applied by `applyFocusVisible()` so the gate can re-evaluate
    /// without the caller re-asserting focus state.
    func setFocusVisible(_ focused: Bool) {
        currentFocused = focused
        applyFocusVisible()
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
        let effective = currentFocused && focusBorderEnabled
        layer?.borderWidth = effective ? 1 : 0
        let color = GhosttyThemeColors.cachedSelectionBackground()
            ?? NSColor.controlAccentColor
        layer?.borderColor = effective ? color.cgColor : NSColor.clear.cgColor
    }
}
