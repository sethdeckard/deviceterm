// SPDX-License-Identifier: GPL-3.0-or-later

/// Which pane a tab should focus when its view tree comes back into a
/// window.
///
/// A tab remembers the pane it was last focused in, but that pane can be
/// gone by the time the tab is selected again: closed, detached, or
/// never mounted because its attach failed. The caller supplies the
/// remembered slot, the tab's primary terminal, and the set of panes
/// that actually have a mounted controller, so the fallback ladder is
/// decided here rather than in the view controller that applies it.
enum PaneFocusRestoreDecision {
    /// The remembered pane when it is still mounted; else the primary
    /// terminal when it is; else the first mounted leaf in display
    /// order; else nil, meaning "leave focus where it is".
    ///
    /// The third rung exists because a terminal's provisioning can
    /// throw, which leaves a tab whose primary terminal has no
    /// controller. Focusing some pane beats focusing none, and display
    /// order makes the choice the first mounted pane in tree order
    /// rather than whichever one `mounted` happens to iterate first.
    static func slot(
        remembered: PaneSlot?,
        primaryTerminal: TerminalPaneID?,
        mounted: Set<PaneSlot>,
        order: [PaneSlot]
    ) -> PaneSlot? {
        if let remembered, mounted.contains(remembered) {
            return remembered
        }
        if let primaryTerminal, mounted.contains(.terminal(primaryTerminal)) {
            return .terminal(primaryTerminal)
        }
        return order.first { mounted.contains($0) }
    }
}
