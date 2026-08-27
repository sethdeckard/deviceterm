// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Testing

@testable import App

/// The two rules `PaneRatioRemap` documents, and the boundary between
/// them: which rearrangements carry a divider and which reseed.
///
/// Shape alone doesn't decide the answer. A before-and-after pair with
/// the same topology can be panes that traded places or a leaf swapped
/// for another underneath a divider nobody touched, and the two want
/// opposite results; only the leaf identities separate them. So the
/// cases below assert the proportions that come out, and, where a split
/// is meant to lose its entry, that the path is gone.
struct PaneRatioRemapTests {
    private static let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
    private static let other = PaneSlot.terminal(TerminalPaneID(value: 2))
    private static let sim = PaneSlot.sim(udid: "udid-a")
    private static let second = PaneSlot.sim(udid: "udid-b")
    private static let pending = PaneSlot.pending(PendingPaneID(value: 7))

    private static func split(
        _ axis: SplitAxis,
        _ children: [PaneNode]
    ) -> PaneNode {
        .split(axis: axis, children: children, extents: Array(repeating: 1, count: children.count))
    }

    // MARK: - Rule 1: a pane carries its share

    @Test
    func swappingTwoLeavesCarriesEachPanesShareWithIt() {
        let before = Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)])
        let after = Self.split(.horizontal, [.leaf(Self.sim), .leaf(Self.terminal)])

        let result = PaneRatioRemap.remapped([[]: [0.71, 0.29]], from: before, to: after)

        // The sim held 0.29 on the right and holds it on the left.
        #expect(result[[]] == [0.29, 0.71])
    }

    @Test
    func aNestedReorderPermutesOnlyItsOwnSplit() {
        let before = Self.split(.vertical, [
            Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)]),
            .leaf(Self.other)
        ])
        let after = Self.split(.vertical, [
            Self.split(.horizontal, [.leaf(Self.sim), .leaf(Self.terminal)]),
            .leaf(Self.other)
        ])

        let result = PaneRatioRemap.remapped(
            [[]: [0.5, 0.5], [0]: [0.7, 0.3]],
            from: before,
            to: after
        )

        #expect(result[[]] == [0.5, 0.5])
        #expect(result[[0]] == [0.3, 0.7])
    }

    @Test
    func reorderingThreeSiblingsCarriesEveryShare() {
        let before = Self.split(.horizontal, [
            .leaf(Self.terminal), .leaf(Self.sim), .leaf(Self.second)
        ])
        let after = Self.split(.horizontal, [
            .leaf(Self.second), .leaf(Self.terminal), .leaf(Self.sim)
        ])

        let result = PaneRatioRemap.remapped([[]: [0.5, 0.3, 0.2]], from: before, to: after)

        #expect(result[[]] == [0.2, 0.5, 0.3])
    }

    @Test
    func collapsingTheRootToItsChildCarriesTheChildsOwnShare() {
        // Closing the outer pane promotes the inner split to the root.
        // Its own proportions travel up with it; the root's do not
        // survive a subtree that no longer exists.
        let before = Self.split(.horizontal, [
            .leaf(Self.terminal),
            Self.split(.vertical, [.leaf(Self.sim), .leaf(Self.second)])
        ])
        let after = Self.split(.vertical, [.leaf(Self.sim), .leaf(Self.second)])

        let result = PaneRatioRemap.remapped(
            [[]: [0.6, 0.4], [1]: [0.3, 0.7]],
            from: before,
            to: after
        )

        #expect(result[[]] == [0.3, 0.7])
        #expect(result[[1]] == nil)
    }

    // MARK: - Rule 2: the divider stays put

    @Test
    func renamingALeafInPlaceLeavesTheDividerWhereItWas() {
        // A placeholder becoming the pane it stood in for. The leaf set
        // changes, so only the positional rule can hold the divider,
        // which is the contract `PaneTreeOps.replace` is built on.
        let before = Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.pending)])
        let after = Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)])

        let result = PaneRatioRemap.remapped([[]: [0.71, 0.29]], from: before, to: after)

        #expect(result[[]] == [0.71, 0.29])
    }

    @Test
    func compactingASiblingSubtreeLeavesTheRootAlone() {
        let before = Self.split(.horizontal, [
            .leaf(Self.terminal),
            Self.split(.vertical, [.leaf(Self.sim), .leaf(Self.second)])
        ])
        let after = Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)])

        let result = PaneRatioRemap.remapped(
            [[]: [0.6, 0.4], [1]: [0.3, 0.7]],
            from: before,
            to: after
        )

        #expect(result[[]] == [0.6, 0.4])
        #expect(result[[1]] == nil)
    }

    @Test
    func wrappingALeafInANewSubSplitLeavesItsParentAlone() {
        let before = Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)])
        let after = Self.split(.horizontal, [
            .leaf(Self.terminal),
            Self.split(.vertical, [.leaf(Self.sim), .leaf(Self.second)])
        ])

        let result = PaneRatioRemap.remapped([[]: [0.71, 0.29]], from: before, to: after)

        #expect(result[[]] == [0.71, 0.29])
        #expect(result[[1]] == nil)
    }

    @Test
    func aReorderAcrossTwoSplitsFallsBackToPosition() {
        // The root's leaves are unchanged but its children are not a
        // permutation of the old ones: one pane crossed between splits.
        // A partial match would carry the wrong share, so both splits
        // keep their positional proportions.
        let before = Self.split(.vertical, [
            Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)]),
            .leaf(Self.other)
        ])
        let after = Self.split(.vertical, [
            Self.split(.horizontal, [.leaf(Self.other), .leaf(Self.sim)]),
            .leaf(Self.terminal)
        ])

        let result = PaneRatioRemap.remapped(
            [[]: [0.6, 0.4], [0]: [0.7, 0.3]],
            from: before,
            to: after
        )

        #expect(result[[]] == [0.6, 0.4])
        #expect(result[[0]] == [0.7, 0.3])
    }

    // MARK: - Neither rule: the seed pass takes over

    @Test
    func flippingTheRootAxisDropsTheShareSoTheSeedRuns() {
        // A share of width says nothing about a share of height.
        let before = Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)])
        let after = Self.split(.vertical, [.leaf(Self.terminal), .leaf(Self.sim)])

        let result = PaneRatioRemap.remapped([[]: [0.71, 0.29]], from: before, to: after)

        #expect(result[[]] == nil)
    }

    @Test
    func closingOneOfThreeSiblingsDropsTheShareSoTheSeedRuns() {
        let before = Self.split(.horizontal, [
            .leaf(Self.terminal), .leaf(Self.sim), .leaf(Self.second)
        ])
        let after = Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.second)])

        let result = PaneRatioRemap.remapped([[]: [0.5, 0.3, 0.2]], from: before, to: after)

        #expect(result[[]] == nil)
    }

    @Test
    func aStoredCountThatDisagreesWithTheSplitIsDropped() {
        let tree = Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)])

        let result = PaneRatioRemap.remapped([[]: [0.5, 0.3, 0.2]], from: tree, to: tree)

        #expect(result[[]] == nil)
    }

    // MARK: - Shape of the result

    @Test
    func everyPathInTheResultNamesASplitInTheNewTree() {
        let before = Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)])
        let after = Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)])

        let result = PaneRatioRemap.remapped(
            [[]: [0.71, 0.29], [9]: [0.5, 0.5], [0, 0]: [0.5, 0.5]],
            from: before,
            to: after
        )

        #expect(Set(result.keys) == [[]])
    }

    @Test
    func aTreeWithoutSplitsCarriesNothing() {
        let before = Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)])

        let result = PaneRatioRemap.remapped(
            [[]: [0.71, 0.29]],
            from: before,
            to: .leaf(Self.terminal)
        )

        #expect(result.isEmpty)
    }

    @Test
    func anUnchangedTreeCarriesEverySplitUntouched() {
        let tree = Self.split(.vertical, [
            Self.split(.horizontal, [.leaf(Self.terminal), .leaf(Self.sim)]),
            .leaf(Self.other)
        ])
        let ratios: [[Int]: [CGFloat]] = [[]: [0.6, 0.4], [0]: [0.7, 0.3]]

        #expect(PaneRatioRemap.remapped(ratios, from: tree, to: tree) == ratios)
    }
}
