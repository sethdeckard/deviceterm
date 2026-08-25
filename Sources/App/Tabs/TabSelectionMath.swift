// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabSelectionMath: index arithmetic for the menu items that act on the
// selected tab, kept pure so the edge cases are enumerable in tests rather
// than discovered by pressing keys.
//
// Handles numbered and relative selection plus selected-tab movement.
// Each helper returns an index into the window's tab array, or nil when
// the operation has no valid target; the arithmetic itself knows nothing
// about tabs.

enum TabSelectionMath {
    /// The tab a numbered menu item selects. `tag` is 1-based because
    /// `NSMenuItem.tag` mirrors the visible label ("Tab 3" carries 3),
    /// which keeps the catalog readable.
    ///
    /// Out of range is nil, not a clamp, so a shortcut for an unopened
    /// position does nothing. Clamping to the last tab would make a
    /// mistyped chord silently move the selection.
    static func index(forMenuTag tag: Int, tabCount: Int) -> Int? {
        guard tag >= 1, tag <= tabCount else { return nil }
        return tag - 1
    }

    /// The last tab, for ⌘9. Browsers bind 9 to "last" rather than to the
    /// ninth tab, so a three-tab window still answers it.
    static func lastIndex(tabCount: Int) -> Int? {
        tabCount > 0 ? tabCount - 1 : nil
    }

    /// The tab `delta` steps from `selectedIndex`, wrapping at both ends.
    ///
    /// Returns nil when there is no selection or no tab. A single tab
    /// resolves to itself, which is a no-op rather than a special case.
    static func wrappedIndex(from selectedIndex: Int?, delta: Int, tabCount: Int) -> Int? {
        guard tabCount > 0, let selectedIndex,
            selectedIndex >= 0, selectedIndex < tabCount else { return nil }
        // Swift's `%` keeps the dividend's sign, so -1 % 3 is -1 rather
        // than 2. Adding `tabCount` before the second modulo normalizes
        // the negative remainder so the leftward wrap lands on the last
        // tab.
        return ((selectedIndex + delta) % tabCount + tabCount) % tabCount
    }

    /// Where a tab at `currentIndex` lands when moved `delta` slots.
    ///
    /// Unlike selection this does **not** wrap, and it does not clamp
    /// either: a destination outside the strip is nil, which the caller
    /// treats as a no-op, so the tab keeps its place. A tab that jumped
    /// from one end to the far side would reorder the strip in a way
    /// nobody asked for.
    static func moveDestination(from currentIndex: Int?, delta: Int, tabCount: Int) -> Int? {
        guard tabCount > 0, let currentIndex,
            currentIndex >= 0, currentIndex < tabCount else { return nil }
        let target = currentIndex + delta
        guard target >= 0, target < tabCount else { return nil }
        return target
    }
}
