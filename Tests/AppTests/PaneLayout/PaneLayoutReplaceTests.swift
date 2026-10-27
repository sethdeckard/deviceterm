// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// A slot whose controller changes while its key stays in the tree.
///
/// A re-attach replaces the pane behind a sim's udid. Its placeholder swap
/// normally takes the slot out of the tree and back, but when both halves
/// land before one observation pass the layout sees the same tree with a
/// different controller behind a surviving slot. The layout must mount the
/// replacement controller even when the slot and tree are unchanged.
@MainActor
struct PaneLayoutReplaceTests {
    private static let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
    private static let sim = PaneSlot.sim(udid: "udid-a")
    private static let tree = PaneNode.split(
        axis: .horizontal,
        children: [.leaf(terminal), .leaf(sim)],
        extents: [1, 1]
    )

    @Test
    func aReplacedControllerIsMountedUnderAnUnchangedTree() {
        let shutDown = StubPaneViewController()
        let replacement = StubPaneViewController()
        let (controller, window) = makeMounted(simVC: shutDown)
        controller.reconcile(tree: Self.tree, pendingTargets: [:]) { slot in
            slot == Self.sim ? replacement : nil
        }
        #expect(controller.paneVCs[Self.sim] === replacement)
        #expect(controller.children.contains { $0 === replacement })
        #expect(!controller.children.contains { $0 === shutDown })
        #expect(replacement.view.isDescendant(of: controller.view))
        #expect(shutDown.view.superview == nil)
        _ = window
    }

    @Test
    func theSameControllerIsLeftInPlace() {
        // The factory is asked about every surviving slot on every pass, so
        // an unchanged answer must not churn the view hierarchy.
        let simVC = StubPaneViewController()
        let (controller, window) = makeMounted(simVC: simVC)
        let superviewBefore = simVC.view.superview
        controller.reconcile(tree: Self.tree, pendingTargets: [:]) { slot in
            slot == Self.sim ? simVC : nil
        }
        #expect(controller.paneVCs[Self.sim] === simVC)
        #expect(simVC.view.superview === superviewBefore)
        _ = window
    }

    @Test
    func aNilAnswerKeepsTheMountedController() {
        let simVC = StubPaneViewController()
        let (controller, window) = makeMounted(simVC: simVC)
        controller.reconcile(tree: Self.tree, pendingTargets: [:]) { _ in nil }
        #expect(controller.paneVCs[Self.sim] === simVC)
        #expect(simVC.view.isDescendant(of: controller.view))
        _ = window
    }

    // MARK: - Harness

    /// A terminal beside `simVC`, mounted in a window and laid out. The
    /// window is returned so the caller keeps it alive.
    private func makeMounted(
        simVC: NSViewController
    ) -> (PaneLayoutViewController, NSWindow) {
        let terminalVC = StubPaneViewController()
        let controller = PaneLayoutViewController(
            tabID: TabID(value: 1),
            router: nil,
            initialTree: .leaf(Self.terminal),
            initialPaneVCs: [Self.terminal: terminalVC]
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = controller.view
        controller.reconcile(tree: Self.tree, pendingTargets: [:]) { slot in
            slot == Self.sim ? simVC : nil
        }
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }
}

@MainActor
private final class StubPaneViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }
}
