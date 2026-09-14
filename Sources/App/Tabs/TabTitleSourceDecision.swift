// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// Which panes a tab's label follows, resolved from the two focus memories
/// the tab keeps.
///
/// `lastFocusedPane` is deliberately never cleared when the pane it names goes
/// away, so it can be stale. `lastFocusedTerminal` is cleared on the one path
/// that removes a terminal. The caller supplies the tab's current leaves and
/// pending targets, which validate a remembered source before it is used: a
/// terminal that fails falls back to the primary, and a device that fails
/// resolves to none. Deciding that here rather than in the view controller
/// that applies it keeps the resolver total for either input.
///
/// The primary is not itself re-checked. `TabState` keeps `terminals`
/// non-empty and every terminal leafed, so it is live by construction.
///
/// The sibling that answers the focus-*restore* question is
/// `PaneFocusRestoreDecision`, which resolves the same remembered slot against
/// the panes that have a mounted controller. This one resolves against nav
/// state, because the title *source* has to be derivable from `TabState`
/// alone. The label's content does not: the OSC title and working directory
/// behind it live on the terminal view controllers.
enum TabTitleSourceDecision {
    /// The last-focused terminal when it is still a leaf, else the primary
    /// terminal; paired with the focused device pane when one is what the tab
    /// last focused.
    ///
    /// A focused device that is mid-re-attach has traded its leaf for a
    /// `.pending` one and lost its record, so `pendingTargets` is consulted
    /// before giving up on it. Without that the label would drop back to the
    /// terminal for the length of every re-attach and then return, which reads
    /// as a flicker rather than as the pane coming back.
    ///
    /// A `.pending` input resolves to no device because `PaneSlot.pending`
    /// carries only a `PendingPaneID` and no `PaneTarget`, leaving nothing here
    /// to name. `TabState.lastFocusedPane` never holds one anyway, having no
    /// wrapper to report focus from; this arm keeps the resolver total.
    static func source(
        lastFocusedPane: PaneSlot?,
        lastFocusedTerminal: TerminalPaneID?,
        primaryTerminal: TerminalPaneID,
        leaves: [PaneSlot],
        pendingTargets: [PaneTarget]
    ) -> TabTitleSource {
        let terminal: TerminalPaneID
        if let lastFocusedTerminal, leaves.contains(.terminal(lastFocusedTerminal)) {
            terminal = lastFocusedTerminal
        } else {
            terminal = primaryTerminal
        }
        let device = lastFocusedPane.flatMap { slot -> PaneTarget? in
            guard let target = slot.target else { return nil }
            return leaves.contains(slot) || pendingTargets.contains(target) ? target : nil
        }
        return TabTitleSource(terminal: terminal, device: device)
    }
}
