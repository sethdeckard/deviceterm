// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import DaemonProtocol
import Testing

/// Pin the sim pane's focus border to the window's responder chain.
///
/// The border has to answer the same question the terminal pane's does,
/// and answer it from the same place. Focus must be re-resolved when the
/// pane leaves its window: AppKit resets `window.firstResponder` when a
/// first-responder view is pulled out of the view hierarchy, and does so
/// without routing through `makeFirstResponder`, so no
/// `resignFirstResponder` is ever delivered. A tab switch does exactly
/// that to every pane in the outgoing tab.
@MainActor
struct SimulatorPaneWrapperViewTests {
    /// The wrapper, its host window, and the intermediate host view the
    /// pane is mounted under. The pane cannot be the window's
    /// `contentView` here: these tests need to *remove* it from the view
    /// hierarchy, which is what a tab switch does.
    private struct MountedPane {
        let viewController: SimulatorPaneViewController
        let wrapper: SimulatorPaneWrapperView
        let window: NSWindow
        let host: NSView
    }

    private func makeViewController() -> SimulatorPaneViewController {
        let pane = SimPaneState(
            paneId: "p1",
            udid: "U-TEST",
            displayName: "iPhone 17 Pro",
            family: "phone"
        )
        return SimulatorPaneViewController(
            simPane: pane,
            daemonClient: FakeDaemonClient(),
            advisory: .silent()
        )
    }

    private func makeMountedPane() throws -> MountedPane {
        let viewController = makeViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        window.contentView = host
        viewController.view.frame = host.bounds
        viewController.loadViewIfNeeded()
        host.addSubview(viewController.view)
        let wrapper = try #require(
            viewController.view as? SimulatorPaneWrapperView,
            "VC root view is not the wrapper subclass"
        )
        return MountedPane(
            viewController: viewController,
            wrapper: wrapper,
            window: window,
            host: host
        )
    }

    @Test
    func clearsBorderWhenRemovedFromWindow() async throws {
        // The tab-switch shape, reduced to its smallest form.
        // `TabStripViewController.applySelection` removes the outgoing
        // tab's whole subtree from the window. That must clear the pane's
        // focus ring before the returning tab focuses its terminal;
        // otherwise both panes appear focused at once.
        let mount = try makeMountedPane()
        _ = mount.window.makeFirstResponder(mount.viewController.view)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect((mount.wrapper.layer?.borderWidth ?? 0) == 1)

        mount.viewController.view.removeFromSuperview()
        #expect(mount.wrapper.layer?.borderWidth ?? -1 == 0)
    }

    @Test
    func borderTracksTheResponderChainBothDirections() async throws {
        let mount = try makeMountedPane()
        #expect(mount.wrapper.layer?.borderWidth ?? -1 == 0)
        _ = mount.window.makeFirstResponder(mount.viewController.view)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect((mount.wrapper.layer?.borderWidth ?? 0) == 1)

        _ = mount.window.makeFirstResponder(mount.window)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(mount.wrapper.layer?.borderWidth ?? -1 == 0)
    }

    @Test
    func focusBorderGateSuppressesBorderEvenWhenFocused() async throws {
        // A solo pane has no neighbor to swap with and no divider to
        // drag, so the layout controller gates the ring off. The pane
        // still holds focus; only the affordance is suppressed.
        let mount = try makeMountedPane()
        mount.wrapper.focusBorderEnabled = false
        _ = mount.window.makeFirstResponder(mount.viewController.view)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(mount.wrapper.layer?.borderWidth ?? -1 == 0)
        #expect(mount.wrapper.isAccessibilityFocused())
    }

    @Test
    func focusChangeReportsEachEdgeOnce() async throws {
        // The VC mirrors this into the chrome view model. Reporting
        // only resolved changes keeps that off the per-window-update
        // path.
        let mount = try makeMountedPane()
        var reported: [Bool] = []
        mount.wrapper.onFocusChange = { reported.append($0) }
        _ = mount.window.makeFirstResponder(mount.viewController.view)
        for _ in 0..<3 {
            mount.window.update()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(reported == [true])
    }
}
