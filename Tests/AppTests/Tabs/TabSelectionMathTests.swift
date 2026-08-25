// SPDX-License-Identifier: GPL-3.0-or-later
//
// Index arithmetic for the Window menu's tab-selection items. These pure
// tests enumerate wrapping, missing positions, and empty or single-tab
// windows.

@testable import App
import Testing

@Suite
struct TabSelectionMathTests {
    // MARK: - Numbered items

    @Test("menu tag resolves to a zero-based index", arguments: [
        (1, 0),
        (3, 2),
        (8, 7)
    ])
    func resolvesMenuTagToIndex(tag: Int, expected: Int) {
        #expect(TabSelectionMath.index(forMenuTag: tag, tabCount: 8) == expected)
    }

    @Test("a tag past the open tabs selects nothing", arguments: [4, 9, 100])
    func rejectsOutOfRangeTag(tag: Int) {
        // Deliberately nil rather than clamped: ⌘5 in a three-tab window
        // should do nothing, not move the selection.
        #expect(TabSelectionMath.index(forMenuTag: tag, tabCount: 3) == nil)
    }

    @Test
    func rejectsANonPositiveTag() {
        // Tags are 1-based to mirror the visible label. A zero tag is the
        // AppKit default for an item nobody set, so it must not resolve to
        // the first tab by accident.
        #expect(TabSelectionMath.index(forMenuTag: 0, tabCount: 3) == nil)
        #expect(TabSelectionMath.index(forMenuTag: -1, tabCount: 3) == nil)
    }

    @Test
    func resolvesNothingInAnEmptyWindow() {
        #expect(TabSelectionMath.index(forMenuTag: 1, tabCount: 0) == nil)
    }

    // MARK: - Last tab

    @Test("⌘9 addresses the end of the strip, not the ninth tab", arguments: [
        (1, 0),
        (3, 2),
        (12, 11)
    ])
    func resolvesLastIndex(tabCount: Int, expected: Int) {
        #expect(TabSelectionMath.lastIndex(tabCount: tabCount) == expected)
    }

    @Test
    func hasNoLastTabWithNoTabs() {
        #expect(TabSelectionMath.lastIndex(tabCount: 0) == nil)
    }

    // MARK: - Wrapping

    @Test("next and previous wrap at both ends", arguments: [
        (0, 1, 3, 1),
        (1, 1, 3, 2),
        (2, 1, 3, 0),
        (2, -1, 3, 1),
        (1, -1, 3, 0),
        (0, -1, 3, 2)
    ])
    func wrapsInBothDirections(selected: Int, delta: Int, count: Int, expected: Int) {
        // The leftward wrap is the one worth pinning: Swift's `%` keeps the
        // dividend's sign, so a naive (selected + delta) % count yields -1
        // instead of the last valid index.
        #expect(
            TabSelectionMath.wrappedIndex(
                from: selected,
                delta: delta,
                tabCount: count
            ) == expected
        )
    }

    @Test
    func aSingleTabWrapsToItself() {
        #expect(TabSelectionMath.wrappedIndex(from: 0, delta: 1, tabCount: 1) == 0)
        #expect(TabSelectionMath.wrappedIndex(from: 0, delta: -1, tabCount: 1) == 0)
    }

    @Test
    func wrapsNowhereWithoutASelection() {
        #expect(TabSelectionMath.wrappedIndex(from: nil, delta: 1, tabCount: 3) == nil)
    }

    @Test
    func wrapsNowhereWithNoTabs() {
        #expect(TabSelectionMath.wrappedIndex(from: 0, delta: 1, tabCount: 0) == nil)
    }

    // MARK: - Move destination

    @Test("moving the selected tab shifts one slot", arguments: [
        (0, 1, 1),
        (1, 1, 2),
        (2, -1, 1),
        (1, -1, 0)
    ])
    func resolvesMoveDestination(selected: Int, delta: Int, expected: Int) {
        #expect(
            TabSelectionMath.moveDestination(
                from: selected,
                delta: delta,
                tabCount: 3
            ) == expected
        )
    }

    @Test("a tab at either end stays put", arguments: [(0, -1), (2, 1)])
    func refusesToMovePastAnEnd(selected: Int, delta: Int) {
        // Deliberately not the wrapping behavior selection uses. A tab that
        // jumped from one end of the strip to the other would reorder it in
        // a way nobody asked for.
        #expect(
            TabSelectionMath.moveDestination(
                from: selected,
                delta: delta,
                tabCount: 3
            ) == nil
        )
    }

    @Test
    func movesNowhereWithoutASelection() {
        #expect(TabSelectionMath.moveDestination(from: nil, delta: 1, tabCount: 3) == nil)
        #expect(TabSelectionMath.moveDestination(from: 0, delta: 1, tabCount: 0) == nil)
        #expect(TabSelectionMath.moveDestination(from: 5, delta: -1, tabCount: 3) == nil)
    }

    // MARK: - Stale selection

    @Test
    func rejectsASelectionOutsideTheTabs() {
        // A stale selected index would otherwise resolve to a real tab and
        // move the user somewhere they didn't ask for.
        #expect(TabSelectionMath.wrappedIndex(from: 5, delta: 1, tabCount: 3) == nil)
        #expect(TabSelectionMath.wrappedIndex(from: -1, delta: 1, tabCount: 3) == nil)
    }
}
