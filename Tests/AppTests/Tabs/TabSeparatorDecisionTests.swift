// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabSeparatorDecisionTests: inactive-neighbor and hover suppression rules
// for the tab strip's decorative separators.

@testable import App
import Testing

struct TabSeparatorDecisionTests {
    @Test
    func emptyAndSingleTabStripsHaveNoSeparators() {
        #expect(TabSeparatorDecision.trailingVisibility(for: []).isEmpty)
        #expect(
            TabSeparatorDecision.trailingVisibility(
                for: [(isSelected: true, isHovered: false)]
            ) == [false]
        )
    }

    @Test
    func separatorAppearsOnlyBetweenInactiveNeighbors() {
        let states = [
            (isSelected: false, isHovered: false),
            (isSelected: true, isHovered: false),
            (isSelected: false, isHovered: false),
            (isSelected: false, isHovered: false)
        ]

        #expect(TabSeparatorDecision.trailingVisibility(for: states) == [false, false, true, false])
    }

    @Test
    func selectedEndLeavesSeparatorsOnlyWithinInactiveRun() {
        let selectedFirst = [
            (isSelected: true, isHovered: false),
            (isSelected: false, isHovered: false),
            (isSelected: false, isHovered: false)
        ]
        let selectedLast = [
            (isSelected: false, isHovered: false),
            (isSelected: false, isHovered: false),
            (isSelected: true, isHovered: false)
        ]

        #expect(TabSeparatorDecision.trailingVisibility(for: selectedFirst) == [false, true, false])
        #expect(TabSeparatorDecision.trailingVisibility(for: selectedLast) == [true, false, false])
    }

    @Test
    func hoverSuppressesBothTouchingSeparators() {
        let states = [
            (isSelected: false, isHovered: false),
            (isSelected: false, isHovered: true),
            (isSelected: false, isHovered: false),
            (isSelected: false, isHovered: false)
        ]

        #expect(TabSeparatorDecision.trailingVisibility(for: states) == [false, false, true, false])
    }

    @Test
    func visibilityFollowsVisualOrder() {
        let beforeMove = [
            (isSelected: false, isHovered: false),
            (isSelected: true, isHovered: false),
            (isSelected: false, isHovered: false)
        ]
        let afterMove = [beforeMove[1], beforeMove[0], beforeMove[2]]

        #expect(TabSeparatorDecision.trailingVisibility(for: beforeMove) == [false, false, false])
        #expect(TabSeparatorDecision.trailingVisibility(for: afterMove) == [false, true, false])
    }
}
