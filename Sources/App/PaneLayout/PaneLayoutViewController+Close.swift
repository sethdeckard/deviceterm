// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneLayoutViewController+Close: the ⌘W responder-chain action, an
// extension file for the same reason `+PaneNavigation` and `+Split`
// are, keeping a set of menu forwarders out of the controller's own
// file.
//
// The selector deliberately does not carry a pane VC's name. Split
// Right forwards to `TerminalPaneViewController`'s own selector because
// a focused terminal must claim it first; ⌘W is the opposite, since the
// decision of what to close needs the whole tab in view and only this
// controller has it. So the chain resolves here for every pane kind,
// and this file dispatches to the pane afterwards.
//
// Each pane kind is closed through the affordance it already has:
// terminal and mirrored panes reuse their context-menu actions, and a
// placeholder reuses its Close button. So there is one close path per
// kind rather than a keyboard-only variant that can drift from it.
//
// The tab case re-enters the responder chain rather than calling
// through, because closing a tab is `TabStripViewController`'s
// decision: it owns the close prompts and the dispatch. The terminal's
// own explicit-close path lands in the same prompts for a last
// terminal (`onTerminalCloseRequested`), so the two routes agree.

import AppKit

extension PaneLayoutViewController {
    @objc
    func closeFocusedPaneOrTab(_ sender: Any?) {
        switch closeTarget() {
        case let .pane(slot):
            close(slot, sender: sender)

        case .tab:
            NSApp.sendAction(
                #selector(TabStripViewController.closeTab(_:)),
                to: nil,
                from: sender
            )
        }
    }

    /// What ⌘W would close right now.
    ///
    /// `internal` (not `private`): `validateUserInterfaceItem` reads it
    /// to title the menu item, so the item names the same thing the
    /// keystroke does.
    func closeTarget() -> PaneCloseTarget {
        let terminals = PaneTreeOps.leavesInOrder(tree).filter { slot in
            if case .terminal = slot { return true }
            return false
        }
        return PaneCloseTargetDecision.target(
            focused: focusedSlot(),
            terminalCount: terminals.count
        )
    }

    private func close(_ slot: PaneSlot, sender: Any?) {
        // Nothing here hands focus off. `reconcile` resolves that for
        // every close, so this path stays identical to the context-menu
        // and overlay ones instead of being the only one that leaves the
        // tab focused.
        switch slot {
        case .terminal:
            // The terminal's own close path asks the tab strip to pick
            // between dropping the pane and closing the tab, using the
            // navigation state's terminal count. `closeTarget` reached
            // here from the layout tree's count, which reconcile keeps
            // equal to it, so both agree on the pane branch.
            (paneVCs[slot] as? TerminalPaneViewController)?
                .closeTerminalPaneViaMenu(sender)

        case .sim, .device:
            (paneVCs[slot] as? SimulatorPaneViewController)?.closePane(sender)

        case .pending:
            (paneVCs[slot] as? PendingPaneViewController)?.cancelAttach()
        }
    }
}
