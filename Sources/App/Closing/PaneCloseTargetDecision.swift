// SPDX-License-Identifier: GPL-3.0-or-later

/// PaneCloseTargetDecision resolves ⌘W to either the focused pane or the
/// whole tab, and names the menu item after whichever it picked.
///
/// `terminalCount` is the deciding input, and the number of panes cannot
/// stand in for it. A tab must keep at least one terminal
/// (`TabState.init`'s precondition), so closing its last terminal is
/// closing the tab. `Router.closeTerminalPane` enforces the same rule by
/// refusing to drop the only remaining one, which a pane resolution there
/// would run into as a silent no-op. A tab holding one terminal beside
/// one sim has two panes, and ⌘W on that terminal still resolves to the
/// tab.
///
/// The zero case exists only to keep the function total; that same
/// invariant makes it unreachable.
enum PaneCloseTargetDecision {
    static func target(focused: PaneSlot?, terminalCount: Int) -> PaneCloseTarget {
        // Focus outside the tab's panes names nothing to close, so ⌘W
        // falls back to the selected tab.
        guard let focused else { return .tab }
        if case .terminal = focused, terminalCount <= 1 { return .tab }
        return .pane(focused)
    }

    static func menuTitle(for target: PaneCloseTarget) -> String {
        switch target {
        case .pane:
            return "Close Pane"

        case .tab:
            return "Close Tab"
        }
    }
}
