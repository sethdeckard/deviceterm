// SPDX-License-Identifier: GPL-3.0-or-later
//
// ⌘W driven through a real `PaneLayoutViewController` in a real window.
//
// The resolution table itself is covered in
// `PaneCloseTargetDecisionTests`. What these add is the derivation the
// controller performs before consulting it: the focused slot, and the
// terminal count read out of the layout tree. Counting panes instead of
// terminals is the mistake the mixed-pane cases below are here to catch,
// and it is invisible to a pure test.

@testable import App
import AppKit
import Testing

@MainActor
struct PaneLayoutCloseTests {
    /// Controller plus the window keeping it alive, since a released
    /// window takes the responder state with it.
    private struct Mounted {
        let controller: PaneLayoutViewController
        let window: NSWindow
    }

    private static let terminalA = PaneSlot.terminal(TerminalPaneID(value: 1))
    private static let terminalB = PaneSlot.terminal(TerminalPaneID(value: 2))
    private static let sim = PaneSlot.sim(udid: "udid-a")
    private static let pending = PaneSlot.pending(PendingPaneID(value: 7))

    // MARK: - Resolution from the live tree

    @Test
    func aSoleTerminalResolvesToTheTab() {
        let mount = makeMounted(slots: [Self.terminalA])
        focus(Self.terminalA, in: mount)
        #expect(mount.controller.closeTarget() == .tab)
    }

    @Test
    func oneOfTwoTerminalsResolvesToItsOwnPane() {
        let mount = makeMounted(slots: [Self.terminalA, Self.terminalB])
        focus(Self.terminalB, in: mount)
        #expect(mount.controller.closeTarget() == .pane(Self.terminalB))
    }

    @Test
    func theLastTerminalBesideASimStillResolvesToTheTab() {
        // Two panes, one terminal. A leaf count would read this as a
        // multi-pane tab and try to drop the terminal on its own, which
        // the Router refuses, leaving ⌘W doing nothing at all.
        let mount = makeMounted(slots: [Self.terminalA, Self.sim])
        focus(Self.terminalA, in: mount)
        #expect(mount.controller.closeTarget() == .tab)
    }

    @Test
    func theSimBesideTheLastTerminalResolvesToItsOwnPane() {
        let mount = makeMounted(slots: [Self.terminalA, Self.sim])
        focus(Self.sim, in: mount)
        #expect(mount.controller.closeTarget() == .pane(Self.sim))
    }

    @Test
    func focusOutsideTheTabResolvesToTheTab() {
        let mount = makeMounted(slots: [Self.terminalA, Self.terminalB])
        #expect(mount.controller.focusedSlot() == nil)
        #expect(mount.controller.closeTarget() == .tab)
    }

    // MARK: - The menu item follows the resolution

    @Test
    func theMenuItemNamesWhatTheKeystrokeWouldClose() {
        let mount = makeMounted(slots: [Self.terminalA, Self.terminalB])
        let item = NSMenuItem(
            title: "Close Pane",
            action: #selector(PaneLayoutViewController.closeFocusedPaneOrTab(_:)),
            keyEquivalent: "w"
        )
        focus(Self.terminalB, in: mount)
        #expect(mount.controller.validateUserInterfaceItem(item))
        #expect(item.title == "Close Pane")

        // Focus moves between validation passes, so the title has to be
        // recomputed on each one rather than set once.
        mount.controller.paneVCs[Self.terminalB]?.view.removeFromSuperview()
        mount.controller.tree = .leaf(Self.terminalA)
        focus(Self.terminalA, in: mount)
        #expect(mount.controller.validateUserInterfaceItem(item))
        #expect(item.title == "Close Tab")
    }

    // MARK: - Dispatch to the pane

    @Test
    func closingAFocusedPendingPaneCancelsItsAttach() {
        // The placeholder's Close button is the only other way to cancel
        // an attach, and it is a SwiftUI button with no menu item behind
        // it. ⌘W has to reach the same closure or a keyboard user is
        // stuck with a failed placeholder.
        let pendingVC = PendingPaneViewController(
            pending: PendingPaneState(
                id: PendingPaneID(value: 7),
                target: .sim(udid: "udid-a"),
                displayName: "iPhone",
                family: "phone"
            )
        )
        var cancelled = 0
        pendingVC.onCancel = { cancelled += 1 }
        let mount = makeMounted(
            slots: [Self.terminalA, Self.pending],
            paneVCs: [Self.pending: pendingVC]
        )
        focus(Self.pending, in: mount)
        #expect(mount.controller.focusedSlot() == Self.pending)
        mount.controller.closeFocusedPaneOrTab(nil)
        #expect(cancelled == 1)
    }

    // MARK: - Focus survives the removal

    @Test
    func reconcileHandsFocusToTheNeighborOfAClosedPane() {
        // Every pane removal that leaves the tab open arrives at
        // `reconcile`, whether it started at ⌘W, a context menu, the
        // shutdown overlay's button, the placeholder's Close, or a shell
        // exiting on its own. Only this path sees all of them, and the
        // pane's view is torn down here before anything can ask what was
        // focused.
        let mount = makeMounted(slots: [Self.terminalA, Self.terminalB, Self.sim])
        focus(Self.terminalA, in: mount)
        mount.controller.reconcile(tree: tree(of: [Self.terminalB, Self.sim])) { _ in nil }
        #expect(mount.controller.focusedSlot() == Self.terminalB)
    }

    @Test
    func reconcileLeavesFocusOnAPaneThatSurvives() {
        // A rearrange rebuilds the same panes, and focus has to stay put
        // so the user can keep typing.
        let mount = makeMounted(slots: [Self.terminalA, Self.terminalB])
        focus(Self.terminalB, in: mount)
        mount.controller.reconcile(tree: tree(of: [Self.terminalB, Self.terminalA])) { _ in nil }
        #expect(mount.controller.focusedSlot() == Self.terminalB)
    }

    // MARK: - Harness

    /// One horizontal split holding `slots` in order, mounted and laid
    /// out. `paneVCs` overrides the stub for a slot that needs its real
    /// controller.
    private func makeMounted(
        slots: [PaneSlot],
        paneVCs: [PaneSlot: NSViewController] = [:]
    ) -> Mounted {
        let tree = tree(of: slots)
        var registry: [PaneSlot: NSViewController] = [:]
        for slot in slots {
            registry[slot] = paneVCs[slot] ?? StubCloseablePaneViewController()
        }
        let controller = PaneLayoutViewController(
            tabID: TabID(value: 1),
            router: nil,
            initialTree: tree,
            initialPaneVCs: registry
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
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return Mounted(controller: controller, window: window)
    }

    /// One horizontal split holding `slots` in display order.
    private func tree(of slots: [PaneSlot]) -> PaneNode {
        guard slots.count > 1 else { return .leaf(slots[0]) }
        return .split(
            axis: .horizontal,
            children: slots.map { PaneNode.leaf($0) },
            extents: slots.map { _ in 1 }
        )
    }

    private func focus(_ slot: PaneSlot, in mount: Mounted) {
        guard let paneVC = mount.controller.paneVCs[slot] else {
            Issue.record("no pane VC for \(slot)")
            return
        }
        _ = mount.window.makeFirstResponder(paneVC.view)
    }
}

/// Stands in for a real pane VC, with a root view that takes focus so
/// the controller can name it as the focused slot.
@MainActor
private final class StubCloseablePaneViewController: NSViewController {
    override func loadView() {
        view = FocusableCloseablePaneView()
    }
}

@MainActor
private final class FocusableCloseablePaneView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
