// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import CoreGraphics
import Testing

/// PaneTreeOps: pin the insert / remove / move / swap semantics
/// of the recursive `PaneNode` tree. Every test is structural (no
/// view hierarchy, no @MainActor required), so a regression in the
/// pure layer surfaces without needing a window-attached split view.
struct PaneTreeOpsTests {
    private let alpha = PaneSlot.terminal(TerminalPaneID(value: 1))
    private let beta = PaneSlot.terminal(TerminalPaneID(value: 2))
    private let gamma = PaneSlot.terminal(TerminalPaneID(value: 3))
    private let sim = PaneSlot.sim(udid: "udid-1")
    private let pending = PaneSlot.pending(PendingPaneID(value: 9))

    // MARK: - leavesInOrder

    @Test
    func leavesInOrderForLeafReturnsSingleSlot() {
        let tree = PaneNode.leaf(alpha)
        #expect(PaneTreeOps.leavesInOrder(tree) == [alpha])
    }

    @Test
    func leavesInOrderWalksSplitChildren() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta), .leaf(gamma)],
            extents: [1, 1, 1]
        )
        #expect(PaneTreeOps.leavesInOrder(tree) == [alpha, beta, gamma])
    }

    @Test
    func leavesInOrderRecursesIntoNestedSplits() {
        let nested = PaneNode.split(
            axis: .vertical,
            children: [.leaf(beta), .leaf(gamma)],
            extents: [1, 1]
        )
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), nested],
            extents: [1, 1]
        )
        #expect(PaneTreeOps.leavesInOrder(tree) == [alpha, beta, gamma])
    }

    // MARK: - insert

    @Test
    func insertAfterSingleLeafCreatesSiblingsOnAxis() {
        let tree = PaneNode.leaf(alpha)
        let after = PaneTreeOps.insert(
            leaf: beta,
            adjacent: alpha,
            axis: .horizontal,
            side: .after,
            in: tree
        )
        if case let .split(axis, children, _) = after {
            #expect(axis == .horizontal)
            #expect(children == [.leaf(alpha), .leaf(beta)])
        } else {
            Issue.record("expected split node")
        }
    }

    @Test
    func insertBeforeSingleLeafPlacesNewFirst() {
        let tree = PaneNode.leaf(alpha)
        let after = PaneTreeOps.insert(
            leaf: beta,
            adjacent: alpha,
            axis: .horizontal,
            side: .before,
            in: tree
        )
        if case let .split(_, children, _) = after {
            #expect(children == [.leaf(beta), .leaf(alpha)])
        } else {
            Issue.record("expected split node")
        }
    }

    @Test
    func insertOnMatchingAxisGrowsSiblings() {
        // Existing split: [alpha, beta] horizontal. Insert gamma after
        // beta on horizontal → siblings of the same split.
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta)],
            extents: [1, 1]
        )
        let after = PaneTreeOps.insert(
            leaf: gamma,
            adjacent: beta,
            axis: .horizontal,
            side: .after,
            in: tree
        )
        if case let .split(_, children, extents) = after {
            #expect(children == [.leaf(alpha), .leaf(beta), .leaf(gamma)])
            #expect(extents.count == 3)
        } else {
            Issue.record("expected split node")
        }
    }

    @Test
    func insertOnOppositeAxisWrapsTargetInSubsplit() {
        // Existing split: [alpha, beta] horizontal. Insert gamma BELOW
        // beta (vertical axis) → beta gets wrapped in a vertical
        // sub-split with gamma as second child.
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta)],
            extents: [1, 1]
        )
        let after = PaneTreeOps.insert(
            leaf: gamma,
            adjacent: beta,
            axis: .vertical,
            side: .after,
            in: tree
        )
        if case let .split(_, children, _) = after,
            children.count == 2,
            case .leaf(alpha) = children[0],
            case let .split(innerAxis, innerChildren, _) = children[1] {
            #expect(innerAxis == .vertical)
            #expect(innerChildren == [.leaf(beta), .leaf(gamma)])
        } else {
            Issue.record("expected wrapped sub-split with target + new leaf")
        }
    }

    @Test
    func insertNoOpsWhenTargetMissing() {
        let tree = PaneNode.leaf(alpha)
        let after = PaneTreeOps.insert(
            leaf: gamma,
            adjacent: beta,
            axis: .horizontal,
            side: .after,
            in: tree
        )
        #expect(after == tree)
    }

    // MARK: - remove + compaction

    @Test
    func removeSingleLeafReturnsRoot() {
        // Removing the only leaf is technically undefined, so the helper
        // returns the original tree as a no-op so callers can't blow
        // away their only pane through a stray call.
        let tree = PaneNode.leaf(alpha)
        let after = PaneTreeOps.remove(slot: alpha, from: tree)
        #expect(after == tree)
    }

    @Test
    func removeFromTwoLeafSplitCompactsToSurvivor() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta)],
            extents: [1, 1]
        )
        let after = PaneTreeOps.remove(slot: alpha, from: tree)
        #expect(after == .leaf(beta))
    }

    @Test
    func removeFromThreeLeafSplitKeepsSplit() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta), .leaf(gamma)],
            extents: [1, 1, 1]
        )
        let after = PaneTreeOps.remove(slot: beta, from: tree)
        if case let .split(_, children, extents) = after {
            #expect(children == [.leaf(alpha), .leaf(gamma)])
            #expect(extents.count == 2)
        } else {
            Issue.record("expected split node")
        }
    }

    @Test
    func removeNestedCompactsBothLevels() {
        // Outer split with two children: leaf(alpha) and inner
        // [beta, gamma] vertical. Removing gamma leaves the inner
        // split with only beta, which compacts to .leaf(beta); the
        // outer then has [.leaf(alpha), .leaf(beta)] which remains a
        // valid 2-child split.
        let inner = PaneNode.split(
            axis: .vertical,
            children: [.leaf(beta), .leaf(gamma)],
            extents: [1, 1]
        )
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), inner],
            extents: [1, 1]
        )
        let after = PaneTreeOps.remove(slot: gamma, from: tree)
        if case let .split(_, children, _) = after {
            #expect(children == [.leaf(alpha), .leaf(beta)])
        } else {
            Issue.record("expected outer split to stay valid")
        }
    }

    // MARK: - swap + move + swapAdjacent

    @Test
    func swapExchangesTwoLeavesAcrossSubsplits() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [
            .leaf(alpha),
            .split(
                axis: .vertical,
                children: [.leaf(beta), .leaf(gamma)],
                extents: [1, 1]
            )
            ],
            extents: [1, 1]
        )
        let after = PaneTreeOps.swap(alpha, with: gamma, in: tree)
        #expect(PaneTreeOps.leavesInOrder(after) == [gamma, beta, alpha])
    }

    @Test
    func moveCenterIsSwap() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta)],
            extents: [1, 1]
        )
        let after = PaneTreeOps.move(slot: alpha, to: beta, zone: .center, in: tree)
        #expect(PaneTreeOps.leavesInOrder(after) == [beta, alpha])
    }

    @Test
    func moveRightHalfReordersWithinSplit() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta), .leaf(gamma)],
            extents: [1, 1, 1]
        )
        // Move alpha to the right half of gamma → alpha lands AFTER gamma.
        let after = PaneTreeOps.move(slot: alpha, to: gamma, zone: .rightHalf, in: tree)
        #expect(PaneTreeOps.leavesInOrder(after) == [beta, gamma, alpha])
    }

    @Test
    func moveBottomHalfCreatesVerticalSubSplit() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta)],
            extents: [1, 1]
        )
        // Move alpha to bottom half of beta → wrap beta vertically
        // with alpha BELOW it. Result tree: just .split(vertical,
        // [beta, alpha]). The outer horizontal compacts because
        // removing alpha leaves it with one child.
        let after = PaneTreeOps.move(slot: alpha, to: beta, zone: .bottomHalf, in: tree)
        if case let .split(axis, children, _) = after {
            #expect(axis == .vertical)
            #expect(children == [.leaf(beta), .leaf(alpha)])
        } else {
            Issue.record("expected vertical sub-split")
        }
    }

    @Test
    func swapAdjacentMovesAcrossInOrderNeighbors() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta), .leaf(gamma)],
            extents: [1, 1, 1]
        )
        let after = PaneTreeOps.swapAdjacent(slot: beta, direction: +1, in: tree)
        #expect(PaneTreeOps.leavesInOrder(after) == [alpha, gamma, beta])
    }

    @Test
    func swapAdjacentNoOpAtEdge() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta)],
            extents: [1, 1]
        )
        let after = PaneTreeOps.swapAdjacent(slot: alpha, direction: -1, in: tree)
        #expect(after == tree)
    }

    @Test
    func swapAdjacentCrossesFormerBlockBoundary() {
        // Terminal next to sim in the same horizontal split. The
        // former same-block restriction is gone; the swap
        // should succeed.
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(sim)],
            extents: [1, 1]
        )
        let after = PaneTreeOps.swapAdjacent(slot: alpha, direction: +1, in: tree)
        #expect(PaneTreeOps.leavesInOrder(after) == [sim, alpha])
    }

    // MARK: - path

    @Test
    func pathToRootLeafIsEmpty() {
        let tree = PaneNode.leaf(alpha)
        #expect(PaneTreeOps.path(to: alpha, in: tree)?.isEmpty == true)
    }

    @Test
    func pathToNestedLeafReturnsChildIndices() {
        let inner = PaneNode.split(
            axis: .vertical,
            children: [.leaf(beta), .leaf(gamma)],
            extents: [1, 1]
        )
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), inner],
            extents: [1, 1]
        )
        #expect(PaneTreeOps.path(to: alpha, in: tree) == [0])
        #expect(PaneTreeOps.path(to: gamma, in: tree) == [1, 1])
    }

    @Test
    func pathReturnsNilForMissingSlot() {
        let tree = PaneNode.leaf(alpha)
        #expect(PaneTreeOps.path(to: beta, in: tree) == nil)
    }

    // MARK: - replace

    @Test
    func replaceSwapsLeafIdentityPreservingPositionAndExtents() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(sim), .leaf(beta)],
            extents: [1, 2, 3]
        )
        let replaced = PaneTreeOps.replace(slot: sim, with: pending, in: tree)
        #expect(PaneTreeOps.leavesInOrder(replaced) == [alpha, pending, beta])
        guard case let .split(axis, _, extents) = replaced else {
            Issue.record("expected a split node")
            return
        }
        #expect(axis == .horizontal)
        #expect(extents == [1, 2, 3])   // divider proportions intact
    }

    @Test
    func replacePreservesNestedSplitExtents() {
        let nested = PaneNode.split(
            axis: .vertical,
            children: [.leaf(beta), .leaf(sim)],
            extents: [4, 5]
        )
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), nested],
            extents: [1, 2]
        )
        let replaced = PaneTreeOps.replace(slot: sim, with: pending, in: tree)
        #expect(PaneTreeOps.leavesInOrder(replaced) == [alpha, beta, pending])
        guard case let .split(_, children, _) = replaced,
            case let .split(_, _, nestedExtents) = children[1] else {
            Issue.record("expected a nested split")
            return
        }
        #expect(nestedExtents == [4, 5])
    }

    @Test
    func replaceIsNoOpWhenOldSlotAbsent() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta)],
            extents: [1, 1]
        )
        #expect(PaneTreeOps.replace(slot: gamma, with: pending, in: tree) == tree)
    }

    @Test
    func replaceIsNoOpWhenNewSlotAlreadyPresent() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta)],
            extents: [1, 1]
        )
        // Replacing alpha with beta would duplicate beta → rejected.
        #expect(PaneTreeOps.replace(slot: alpha, with: beta, in: tree) == tree)
    }

    // MARK: - Split Right then Split Down (the reported bug)

    @Test
    func splitRightThenSplitDownOnLeftPaneNestsUnderLeft() {
        // Reproduces the exact user flow: blank tab (alpha) → Split
        // Right on alpha (horizontal, add beta) → Split Down on alpha
        // (vertical, add gamma). Expected `[[alpha / gamma] | beta]`,
        // NOT three stacked full-width panes. `addTerminal`'s anchored
        // insert is exactly `PaneTreeOps.insert`, so pin it here.
        let afterRight = PaneTreeOps.insert(
            leaf: beta,
            adjacent: alpha,
            axis: .horizontal,
            side: .after,
            in: .leaf(alpha)
        )
        let afterDown = PaneTreeOps.insert(
            leaf: gamma,
            adjacent: alpha,
            axis: .vertical,
            side: .after,
            in: afterRight
        )
        // Top-level split stays horizontal with two children.
        guard case let .split(rootAxis, rootChildren, _) = afterDown else {
            Issue.record("expected a split root")
            return
        }
        #expect(rootAxis == .horizontal)
        #expect(rootChildren.count == 2)
        // Left child is a vertical sub-split of [alpha, gamma];
        // right child is beta, untouched.
        #expect(rootChildren[0] == .split(
            axis: .vertical,
            children: [.leaf(alpha), .leaf(gamma)],
            extents: [1, 1]
        ))
        #expect(rootChildren[1] == .leaf(beta))
        #expect(PaneTreeOps.leavesInOrder(afterDown) == [alpha, gamma, beta])
    }

    // MARK: - flippingParentAxis (⌃⇧D)

    @Test
    func flipParentAxisOnSingleLeafIsNoOp() {
        let tree = PaneNode.leaf(alpha)
        #expect(PaneTreeOps.flippingParentAxis(of: alpha, in: tree) == tree)
    }

    @Test
    func flipParentAxisOnAbsentSlotIsNoOp() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta)],
            extents: [1, 1]
        )
        #expect(PaneTreeOps.flippingParentAxis(of: gamma, in: tree) == tree)
    }

    @Test
    func flipParentAxisFlipsRootSplit() {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(alpha), .leaf(beta)],
            extents: [3, 5]
        )
        let flipped = PaneTreeOps.flippingParentAxis(of: alpha, in: tree)
        // Axis flips; children and extents are preserved.
        #expect(flipped == .split(
            axis: .vertical,
            children: [.leaf(alpha), .leaf(beta)],
            extents: [3, 5]
        ))
    }

    @Test
    func flipParentAxisFlipsOnlyFocusedPanesParent() {
        // `[[alpha / gamma] | beta]`, focus gamma. ⌃⇧D flips gamma's
        // parent (the vertical sub-split) to horizontal; beta and the
        // root split never move.
        let inner = PaneNode.split(
            axis: .vertical,
            children: [.leaf(alpha), .leaf(gamma)],
            extents: [1, 1]
        )
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [inner, .leaf(beta)],
            extents: [1, 1]
        )
        let flipped = PaneTreeOps.flippingParentAxis(of: gamma, in: tree)
        #expect(flipped == .split(
            axis: .horizontal,
            children: [
                .split(axis: .horizontal, children: [.leaf(alpha), .leaf(gamma)], extents: [1, 1]),
                .leaf(beta)
            ],
            extents: [1, 1]
        ))
    }
}
