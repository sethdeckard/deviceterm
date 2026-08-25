// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneFocusOrderMath: the linear walk behind Next Pane / Previous Pane.
//
// Display order is what the tree already gives us, so this is a wrap at
// both ends over an ordered list. Kept pure and separate from the
// spatial walk in `PaneDirectionalFocusMath` because the two answer
// different questions: this one cycles every pane in a fixed sequence,
// which is what makes repeated presses reach all of them.

enum PaneFocusOrderMath {
    /// The pane `delta` steps from `focused` in display order, wrapping
    /// at both ends.
    ///
    /// With no focused pane the walk starts at an end rather than
    /// refusing: forward lands on the first pane, backward on the last.
    /// That makes the first press after focus lands outside the tab
    /// (a sheet, the tab strip) do something predictable.
    ///
    /// Returns nil when the tab holds one pane or none, so a solo pane
    /// is a no-op instead of a cycle back onto itself.
    static func nextSlot(
        from focused: PaneSlot?,
        delta: Int,
        order: [PaneSlot]
    ) -> PaneSlot? {
        guard order.count > 1 else { return nil }
        guard let focused, let here = order.firstIndex(of: focused) else {
            return delta >= 0 ? order.first : order.last
        }
        let count = order.count
        // Swift's `%` keeps the dividend's sign, so the second modulo
        // normalizes a negative remainder into the array's range.
        return order[((here + delta) % count + count) % count]
    }

    /// Where focus belongs once `order` loses panes, leaving only
    /// `surviving`.
    ///
    /// A focused pane that survives keeps focus. One that does not hands
    /// off to the next survivor in display order, wrapping. Nil when
    /// nothing was focused or nothing survives, both of which mean there
    /// is no pane to name.
    ///
    /// This runs on every layout reconcile rather than at each close, so
    /// it covers the close paths that never touch a menu: the context
    /// menus, the shutdown overlay's button, the placeholder's Cancel,
    /// and a shell exiting on its own.
    static func survivor(
        of focused: PaneSlot?,
        order: [PaneSlot],
        surviving: Set<PaneSlot>
    ) -> PaneSlot? {
        guard let focused else { return nil }
        if surviving.contains(focused) { return focused }
        guard let here = order.firstIndex(of: focused) else { return nil }
        for step in 1..<max(order.count, 1) {
            let candidate = order[(here + step) % order.count]
            if surviving.contains(candidate) { return candidate }
        }
        return nil
    }
}
