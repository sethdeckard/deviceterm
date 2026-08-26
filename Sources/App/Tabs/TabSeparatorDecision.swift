// SPDX-License-Identifier: GPL-3.0-or-later

/// Pure visibility rules for the decorative lines
/// between tab-strip cells.
enum TabSeparatorDecision {
    static func trailingVisibility(
        for tabs: [(isSelected: Bool, isHovered: Bool)]
    ) -> [Bool] {
        tabs.indices.map { index in
            guard index < tabs.index(before: tabs.endIndex) else { return false }
            let current = tabs[index]
            let next = tabs[tabs.index(after: index)]
            return !current.isSelected
                && !current.isHovered
                && !next.isSelected
                && !next.isHovered
        }
    }
}
