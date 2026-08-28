// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// The tab-switch focus restore, driven through a real
/// `PaneLayoutViewController` in a real window.
///
/// `PaneFocusRestoreDecisionTests` covers which slot the ladder picks.
/// What this adds is the wiring around it: that the controller resolves
/// what is mounted and in what order from its own state, and that focus
/// actually lands on the chosen pane after the tab's view tree has been
/// pulled out of the window and put back, which is what selecting
/// another tab and returning does to it.
@MainActor
struct PaneFocusRestoreTests {
    private struct Mounted {
        let controller: PaneLayoutViewController
        let window: NSWindow
        let host: NSView
    }

    private static let primary = TerminalPaneID(value: 1)
    private static let primarySlot = PaneSlot.terminal(primary)
    private static let simSlot = PaneSlot.sim(udid: "u-test")

    /// A two-leaf tab: primary terminal beside a sim pane. Two leaves
    /// let these tests tell remembered-pane focus apart from the
    /// fallback, and check that only one pane is ringed.
    private func mount() -> Mounted {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(Self.primarySlot), .leaf(Self.simSlot)],
            extents: [1, 1]
        )
        let controller = PaneLayoutViewController(
            tabID: TabID(value: 1),
            router: nil,
            initialTree: tree,
            initialPaneVCs: [
                Self.primarySlot: StubPaneViewController(),
                Self.simSlot: StubPaneViewController()
            ]
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = host
        host.addSubview(controller.view)
        pin(controller.view, to: host)
        host.layoutSubtreeIfNeeded()
        return Mounted(controller: controller, window: window, host: host)
    }

    private func pin(_ view: NSView, to host: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
    }

    /// Reproduce what `TabStripViewController.applySelection` does on a
    /// real selection change: drop the tab's whole subtree, then put it
    /// back and restore focus.
    private func switchAwayAndBack(
        _ mount: Mounted,
        remembered: PaneSlot?,
        primaryTerminal: TerminalPaneID? = primary
    ) {
        mount.controller.view.removeFromSuperview()
        mount.host.addSubview(mount.controller.view)
        pin(mount.controller.view, to: mount.host)
        mount.host.layoutSubtreeIfNeeded()
        mount.controller.restoreFocus(
            remembered: remembered,
            primaryTerminal: primaryTerminal
        )
    }

    @Test
    func returningToATabFocusesTheRememberedPane() {
        // The pane the user was actually working in, not the tab's
        // primary terminal.
        let mount = mount()
        _ = mount.window.makeFirstResponder(
            mount.controller.paneVCs[Self.simSlot]?.view
        )
        #expect(mount.controller.focusedSlot() == Self.simSlot)

        switchAwayAndBack(mount, remembered: Self.simSlot)
        #expect(mount.controller.focusedSlot() == Self.simSlot)
    }

    @Test
    func focusLandsOnTheInputTargetNotThePaneRoot() {
        // Restoring by root view relies on each wrapper forwarding to
        // its input target. A pane left holding first responder at its
        // root looks focused and receives no keystrokes.
        let mount = mount()
        switchAwayAndBack(mount, remembered: Self.simSlot)
        let paneVC = mount.controller.paneVCs[Self.simSlot] as? StubPaneViewController
        #expect(mount.window.firstResponder === paneVC?.inputTarget)
    }

    @Test
    func aRememberedPaneThatIsGoneFallsBackToTheTerminal() {
        let mount = mount()
        switchAwayAndBack(mount, remembered: .sim(udid: "u-closed-while-away"))
        #expect(mount.controller.focusedSlot() == Self.primarySlot)
    }

    @Test
    func onlyOnePaneDrawsAFocusRingAfterTheCycle() async throws {
        // After returning to a tab, exactly one ring remains: the pane
        // that holds focus.
        //
        // The ring resolves on `NSWindow.didUpdateNotification`, which
        // the app gets from the run loop and a test has to pump by hand,
        // so settle before reading it.
        let mount = mount()
        _ = mount.window.makeFirstResponder(
            mount.controller.paneVCs[Self.simSlot]?.view
        )
        switchAwayAndBack(mount, remembered: Self.simSlot)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)

        let ringed = [Self.primarySlot, Self.simSlot].filter { slot in
            let view = mount.controller.paneVCs[slot]?.view as? ForwardingPaneView
            return (view?.layer?.borderWidth ?? 0) > 0
        }
        #expect(ringed == [Self.simSlot])
    }
}

/// Stands in for a real pane VC: a root view that forwards focus to an
/// inner target and paints a ring while it holds it, the shape both
/// `TerminalPaneWrapperView` and `SimulatorPaneWrapperView` have.
@MainActor
private final class StubPaneViewController: NSViewController {
    let inputTarget = FocusableView()

    override func loadView() {
        let root = ForwardingPaneView()
        root.inputTarget = inputTarget
        root.addSubview(inputTarget)
        view = root
    }
}

/// Mirrors the production wrappers: forwards first responder to its
/// input target, and derives its ring from the responder chain through
/// the same `PaneFocusTracker` they use.
@MainActor
private final class ForwardingPaneView: NSView {
    weak var inputTarget: NSView?

    private let focusTracker = PaneFocusTracker()

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        focusTracker.onFocusChange = { [weak self] focused in
            self?.layer?.borderWidth = focused ? 1 : 0
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTracker.viewDidMoveToWindow(self)
    }

    override func becomeFirstResponder() -> Bool {
        guard let inputTarget, let window else { return super.becomeFirstResponder() }
        return window.makeFirstResponder(inputTarget)
    }
}

@MainActor
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
