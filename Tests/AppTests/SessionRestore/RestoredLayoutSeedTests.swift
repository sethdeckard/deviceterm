// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// A bare pane for the layout controller to place.
@MainActor
private final class StubSeedPaneViewController: NSViewController {
    override func loadView() { view = NSView() }
}

/// A restored tab's saved proportions, seeded into its layout controller
/// before the controller has ever reconciled.
@MainActor
struct RestoredLayoutSeedTests {
    private let slots: [PaneSlot] = [
        .terminal(TerminalPaneID(value: 1)),
        .terminal(TerminalPaneID(value: 2))
    ]

    private func controller() -> PaneLayoutViewController {
        PaneLayoutViewController(
            tabID: TabID(value: 1),
            router: nil,
            initialTree: .leaf(slots[0]),
            initialPaneVCs: [slots[0]: StubSeedPaneViewController()]
        )
    }

    @Test
    func aTabNeverShownReportsItsSavedProportions() {
        // A background tab's view never loads, so it never reconciles and its
        // tree is still the lone primary leaf. The snapshot must still record
        // what the tab will show.
        let layout = controller()
        layout.seedRestoredLayout(ratios: [[]: [0.3, 0.7]], fitPaths: [:])
        #expect(layout.currentRatios() == [[]: [0.3, 0.7]])
    }

    @Test
    func theFirstReconcileAppliesTheSeedOverTheNaturalSplit() throws {
        let layout = controller()
        layout.seedRestoredLayout(ratios: [[]: [0.3, 0.7]], fitPaths: [:])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = layout.view
        layout.reconcile(
            tree: .split(axis: .horizontal, children: slots.map(PaneNode.leaf), extents: [0.5, 0.5]),
            pendingTargets: [:]
        ) { _ in StubSeedPaneViewController() }
        layout.view.layoutSubtreeIfNeeded()
        let ratios = try #require(layout.currentRatios()[[]])
        #expect(ratios.count == 2)
        #expect(abs(ratios[0] - 0.3) < 0.01)
        #expect(abs(ratios[1] - 0.7) < 0.01)
    }
}
