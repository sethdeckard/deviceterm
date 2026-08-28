// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// Minimal harness: wraps the wrapper view, its host window, and a
/// first-responder-accepting descendant in one helper so tests can
/// destructure them. SwiftLint forbids tuple returns wider than 2,
/// so a tiny struct is the idiomatic shape.
private struct MountedWrapper {
    let wrapper: TerminalPaneWrapperView
    let window: NSWindow
    let responderTarget: NSView
}

/// Pin the focus-border toggle and
/// the responder-chain-walk lookup. The wrapper observes
/// `NSWindow.didUpdateNotification` so AppKit's responder-chain
/// transitions (which we can't directly hook on libghostty's
/// foreign-module surface view) toggle the border. Four claims:
///
///   1. Layer backing is established at init, before any descendant
///      Metal-hosting surface gets installed. libghostty's surface
///      brings a CAMetalLayer with it, so the wrapper opts into layer
///      backing eagerly: the layer tree settles in one shape instead of
///      flipping mode mid-life on first focus.
///   2. `containsFirstResponder()`, which the tracker polls, returns
///      true for the wrapper or one of its descendants, and false
///      otherwise. The walk is the essential logic: a refactor that
///      swaps `superview` for `nextResponder` would silently miss
///      focus on subviews mounted indirectly.
///   3. Toggling focus into and out of the descendant updates the
///      border. This is the visible behavior the user sees.
///   4. The border derives only from the responder chain; no setter
///      can assert a conflicting focus state.
@MainActor
struct TerminalPaneWrapperViewTests {
    /// Build a wrapper mounted in a real window with a single
    /// keyboard-accepting subview as the surrogate "libghostty
    /// surface". The wrapper's responder-chain walk is what we're
    /// testing, not anything libghostty-specific.
    private func makeMountedWrapper() -> MountedWrapper {
        let wrapper = TerminalPaneWrapperView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let target = FirstResponderView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        wrapper.addSubview(target)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = wrapper
        return MountedWrapper(
            wrapper: wrapper,
            window: window,
            responderTarget: target
        )
    }

    @Test
    func layerBackingEstablishedAtInit() {
        // Eager `wantsLayer = true` lets the layer tree settle
        // before libghostty's Metal surface mounts as a deep
        // descendant. A regression that flips this to lazy (on first
        // focus) would risk reshuffling the layer hierarchy while
        // the Metal layer is live.
        let wrapper = TerminalPaneWrapperView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 200)
        )
        #expect(wrapper.wantsLayer == true)
        #expect(wrapper.layer != nil)
    }

    @Test
    func focusArrivingDrawsBorder() async throws {
        let mount = makeMountedWrapper()
        #expect(mount.wrapper.layer?.borderWidth ?? -1 == 0)
        _ = mount.window.makeFirstResponder(mount.responderTarget)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect((mount.wrapper.layer?.borderWidth ?? 0) == 1)
    }

    @Test
    func focusLeavingClearsBorder() async throws {
        let mount = makeMountedWrapper()
        _ = mount.window.makeFirstResponder(mount.responderTarget)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        _ = mount.window.makeFirstResponder(mount.window)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(mount.wrapper.layer?.borderWidth ?? -1 == 0)
    }

    @Test
    func focusBorderGateSuppressesBorderEvenWhenFocused() async throws {
        // Solo-pane tabs flip the gate off; the wrapper should refuse
        // to draw the border even when focus arrives. A regression
        // that ignores the gate would paint a ring around the only
        // pane in the tab, where the rearrange affordance the ring
        // implies doesn't exist there.
        let mount = makeMountedWrapper()
        mount.wrapper.focusBorderEnabled = false
        _ = mount.window.makeFirstResponder(mount.responderTarget)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(mount.wrapper.layer?.borderWidth ?? -1 == 0)
    }

    @Test
    func focusBorderGateFlippingOnRefreshesActiveBorder() async throws {
        // Flipping the gate from off → on while focus is held should
        // re-paint the border without focus having to move again. The
        // layout controller relies on this when a second pane joins a
        // solo tab: the gate flips, the already-focused wrapper picks
        // it up.
        let mount = makeMountedWrapper()
        mount.wrapper.focusBorderEnabled = false
        _ = mount.window.makeFirstResponder(mount.responderTarget)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(mount.wrapper.layer?.borderWidth ?? -1 == 0)
        mount.wrapper.focusBorderEnabled = true
        #expect((mount.wrapper.layer?.borderWidth ?? 0) == 1)
    }

    @Test
    func focusChangeReportsEachEdgeOnce() async throws {
        // The tracker gates on resolved changes, so a steady state
        // across several window updates must not re-report. The tab
        // controller writes nav state from this edge; a per-update
        // callback would write on every event-loop pass.
        let mount = makeMountedWrapper()
        var reported: [Bool] = []
        mount.wrapper.onFocusChange = { reported.append($0) }
        _ = mount.window.makeFirstResponder(mount.responderTarget)
        for _ in 0..<3 {
            mount.window.update()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(reported == [true])
    }

    @Test
    func layerCornerRadiusMatchesWindowCornerArc() {
        // The bottom corners of the wrapper sit flush with the
        // window's rounded corner when the pane is at the window
        // edge; the cornerRadius lets the focus border trace the
        // arc instead of getting clipped to an L-shape. A
        // regression that flips this to 0 would paint a square
        // border that sticks out of the window at the bottom
        // corners.
        let wrapper = TerminalPaneWrapperView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 200)
        )
        #expect((wrapper.layer?.cornerRadius ?? 0) > 0)
    }

    @Test
    func focusingTheWrapperForwardsToTheSurface() {
        // `makeFirstResponder` does not consult `acceptsFirstResponder`,
        // so without the forward the wrapper itself takes first responder
        // whenever the layout controller focuses a pane by its root view,
        // which covers every pane-navigation and rearrange shortcut. The
        // pane would then look focused and swallow nothing: keystrokes
        // walk past it up the chain and never reach libghostty.
        let mount = makeMountedWrapper()
        mount.wrapper.inputTarget = mount.responderTarget
        #expect(mount.window.makeFirstResponder(mount.wrapper))
        #expect(mount.window.firstResponder === mount.responderTarget)
    }

    @Test
    func focusingTheWrapperWithNoSurfaceYetIsHarmless() {
        // The VC sets `inputTarget` in `viewDidLoad`, so a focus attempt
        // before the surface exists must not trap or refuse.
        let mount = makeMountedWrapper()
        #expect(mount.wrapper.inputTarget == nil)
        #expect(mount.window.makeFirstResponder(mount.wrapper))
    }

    @Test
    func responderChainWalkClaimsDescendant() async throws {
        // The wrapper's hook is NSWindow.didUpdateNotification, which
        // fires asynchronously after the responder change settles.
        // Force a synchronous update + a brief yield so the queued
        // notification handler runs before we read the border.
        let mount = makeMountedWrapper()
        _ = mount.window.makeFirstResponder(mount.responderTarget)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect((mount.wrapper.layer?.borderWidth ?? 0) == 1)
    }

    @Test
    func responderChainWalkClearsBorderWhenFocusLeaves() async throws {
        let mount = makeMountedWrapper()
        _ = mount.window.makeFirstResponder(mount.responderTarget)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect((mount.wrapper.layer?.borderWidth ?? 0) == 1)

        // Move focus to a view outside the wrapper. The window's
        // contentView wrapper is the responder root, so making the
        // window itself first responder takes focus out of the
        // wrapper's subtree.
        _ = mount.window.makeFirstResponder(mount.window)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(mount.wrapper.layer?.borderWidth ?? -1 == 0)
    }
}

/// Tiny `NSView` subclass that opts into first-responder status so
/// `window.makeFirstResponder(_:)` succeeds against it. Stands in for
/// libghostty's surface view. The responder-chain walk doesn't care
/// what the descendant's class is, only that it's a subview.
@MainActor
private final class FirstResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
