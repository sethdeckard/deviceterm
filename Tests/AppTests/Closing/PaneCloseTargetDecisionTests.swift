// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// The ⌘W resolution table. Every row exists because the two close
/// meanings are not interchangeable: one drops a pane, the other runs the
/// tab's detach-or-shut-down prompt over every sim the tab booted.
@MainActor
struct PaneCloseTargetDecisionTests {
    private static let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
    private static let sim = PaneSlot.sim(udid: "udid-a")
    private static let device = PaneSlot.device(deviceId: "dev-1")
    private static let pending = PaneSlot.pending(PendingPaneID(value: 1))

    @Test
    func focusOutsideTheTabClosesTheTab() {
        // With no pane focused there is nothing narrower to name, so ⌘W
        // falls back to the selected tab rather than doing nothing.
        #expect(PaneCloseTargetDecision.target(focused: nil, terminalCount: 3) == .tab)
    }

    @Test
    func aTerminalWithSiblingsClosesItself() {
        #expect(
            PaneCloseTargetDecision.target(focused: Self.terminal, terminalCount: 2)
                == .pane(Self.terminal)
        )
    }

    @Test
    func theLastTerminalClosesTheTab() {
        // A tab must keep at least one terminal, so dropping this one
        // alone is not a coherent operation. `Router.closeTerminalPane`
        // refuses it outright, which would make a pane resolution a
        // silent no-op.
        #expect(PaneCloseTargetDecision.target(focused: Self.terminal, terminalCount: 1) == .tab)
    }

    // Spelled out rather than read from the properties above, because
    // the argument list is evaluated off the main actor.
    @Test(arguments: [
        PaneSlot.sim(udid: "udid-a"),
        PaneSlot.device(deviceId: "dev-1"),
        PaneSlot.pending(PendingPaneID(value: 1))
    ])
    func aDeviceBackedPaneClosesItselfEvenBesideTheLastTerminal(slot: PaneSlot) {
        // The terminal count decides only what a focused *terminal*
        // means. A sim, a device, or a placeholder is always its own
        // pane, and closing it leaves the tab's session intact.
        #expect(PaneCloseTargetDecision.target(focused: slot, terminalCount: 1) == .pane(slot))
    }

    @Test
    func aTerminalCountOfZeroClosesTheTab() {
        // A tab always holds a terminal, so this is unreachable in the
        // app. The row keeps the function total for any caller.
        #expect(PaneCloseTargetDecision.target(focused: Self.terminal, terminalCount: 0) == .tab)
    }

    @Test
    func theTitleNamesTheResolution() {
        // The menu item is retitled from this, so the user reads the
        // consequence of ⌘W before pressing it.
        #expect(PaneCloseTargetDecision.menuTitle(for: .pane(Self.sim)) == "Close Pane")
        #expect(PaneCloseTargetDecision.menuTitle(for: .tab) == "Close Tab")
    }
}
