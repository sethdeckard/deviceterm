// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

enum PaneTreeOps {
    /// Walk leaves in display order: left-to-right under horizontal
    /// splits, top-to-bottom under vertical splits, recursing into
    /// nested splits as their parent slot demands.
    static func leavesInOrder(_ tree: PaneNode) -> [PaneSlot] {
        switch tree {
        case let .leaf(slot):
            return [slot]

        case let .split(_, children, _):
            return children.flatMap(leavesInOrder)
        }
    }

    /// Return the sequence of child indices to reach the leaf matching
    /// `slot`, or nil if absent. Useful for the keyboard swap (find,
    /// then mutate the parent split) and for round-trip sanity checks
    /// in tests.
    static func path(to slot: PaneSlot, in tree: PaneNode) -> [Int]? {
        switch tree {
        case let .leaf(here):
            return here == slot ? [] : nil

        case let .split(_, children, _):
            for (index, child) in children.enumerated() {
                if let sub = path(to: slot, in: child) {
                    return [index] + sub
                }
            }
            return nil
        }
    }

    /// Flip the axis of the split that **directly contains** `slot`,
    /// leaving every other split, and every sibling outside that split,
    /// untouched. This is the ⌃⇧D "Toggle Split Direction" primitive:
    /// in `[[A / C] | B]` with `C` focused, flipping `C`'s parent
    /// (`[A / C]`) yields `[[A | C] | B]`; `B` never moves.
    ///
    /// No-op (returns the tree unchanged) when `slot` is absent or is
    /// the whole tree's sole leaf, since a single-pane tab has no split to
    /// flip.
    static func flippingParentAxis(of slot: PaneSlot, in tree: PaneNode) -> PaneNode {
        flipParentWalk(of: slot, in: tree).node
    }

    /// Returns the rewritten subtree plus whether `slot` was found
    /// inside it, so the caller one level up knows whether *it* is the
    /// containing split (child found directly as a leaf) versus a
    /// deeper ancestor (found in a descendant split).
    private static func flipParentWalk(
        of slot: PaneSlot,
        in tree: PaneNode
    ) -> (node: PaneNode, found: Bool) {
        switch tree {
        case let .leaf(here):
            return (tree, here == slot)

        case let .split(axis, children, extents):
            // Direct child leaf match → this split is the parent; flip it.
            if children.contains(where: { node in
                if case let .leaf(here) = node { return here == slot }
                return false
            }) {
                let flipped: SplitAxis = axis == .horizontal ? .vertical : .horizontal
                return (.split(axis: flipped, children: children, extents: extents), true)
            }
            // Otherwise recurse; rebuild the branch that contains `slot`.
            for (index, child) in children.enumerated() {
                let result = flipParentWalk(of: slot, in: child)
                if result.found {
                    var newChildren = children
                    newChildren[index] = result.node
                    return (.split(axis: axis, children: newChildren, extents: extents), true)
                }
            }
            return (tree, false)
        }
    }

    /// Append `leaf` at the root level. If the root is already a
    /// `.split` matching `axis`, the leaf joins as the last child; if
    /// the root is a `.split` on the opposite axis, the leaf is wrapped
    /// with the root in a new split of `axis`; if the root is a leaf,
    /// both leaves become children of a fresh split of `axis`.
    ///
    /// The new child's extent is half the existing tail extent so the
    /// auto-rebalance pass picks up a sensible starting ratio before
    /// recomputing.
    static func append(leaf: PaneSlot, axis: SplitAxis, in tree: PaneNode) -> PaneNode {
        switch tree {
        case .leaf:
            return .split(
                axis: axis,
                children: [tree, .leaf(leaf)],
                extents: [1, 1]
            )

        case let .split(existingAxis, children, extents):
            if existingAxis == axis {
                let newExtent = (extents.last ?? 1)
                return .split(
                    axis: axis,
                    children: children + [.leaf(leaf)],
                    extents: extents + [newExtent]
                )
            }
            return .split(
                axis: axis,
                children: [tree, .leaf(leaf)],
                extents: [1, 1]
            )
        }
    }

    /// Insert `leaf` adjacent to the leaf matching `target` along the
    /// requested `axis`. When `target`'s parent split's axis matches,
    /// the leaf becomes a sibling; otherwise the target leaf is wrapped
    /// in a fresh sub-split of the requested axis with the two leaves
    /// as children, in the order implied by `side`.
    ///
    /// `naturalExtent` seeds the new leaf's slot in its parent's
    /// extents list. Auto-rebalance recomputes off pane metrics
    /// afterward; this just keeps the tree consistent in the meantime.
    static func insert(
        leaf newLeaf: PaneSlot,
        adjacent target: PaneSlot,
        axis: SplitAxis,
        side: AdjacentSide,
        in tree: PaneNode,
        naturalExtent: CGFloat = 1
    ) -> PaneNode {
        let extentSeed = max(naturalExtent, 1)
        return insertWalk(
            newLeaf: newLeaf,
            target: target,
            axis: axis,
            side: side,
            in: tree,
            naturalExtent: extentSeed
        ) ?? tree
    }

    /// Remove the leaf matching `slot`. If its parent split is left with
    /// a single child, the parent compacts to that child (recursively, up
    /// the tree).
    static func remove(slot: PaneSlot, from tree: PaneNode) -> PaneNode {
        removeWalk(slot: slot, from: tree) ?? tree
    }

    /// Move `slot` to land at `target` per `zone`.
    ///
    /// `.center` swaps the two leaves' positions in the tree.
    /// `.leftHalf` / `.rightHalf` insert `slot` immediately
    /// before/after `target` along the horizontal axis. `.topHalf` /
    /// `.bottomHalf` insert along the vertical axis. The same insert
    /// rules as `insert(leaf:adjacent:axis:side:…)` apply: matching
    /// axis = sibling, opposite axis = new sub-split.
    static func move(
        slot: PaneSlot,
        to target: PaneSlot,
        zone: DropZone,
        in tree: PaneNode
    ) -> PaneNode {
        guard slot != target else { return tree }
        if case .center = zone {
            return swap(slot, with: target, in: tree)
        }
        let (axis, side) = zoneToInsertion(zone)
        // Pull `slot` out of the tree first; that's the natural extent
        // we'd want to preserve when reinserting. Then insert next to
        // `target` in the trimmed tree.
        let trimmed = remove(slot: slot, from: tree)
        return insert(
            leaf: slot,
            adjacent: target,
            axis: axis,
            side: side,
            in: trimmed
        )
    }

    /// Swap `slot` and `target`'s positions in the tree. Used by the
    /// center drop zone and as a primitive for the keyboard swap.
    static func swap(_ lhs: PaneSlot, with rhs: PaneSlot, in tree: PaneNode) -> PaneNode {
        guard lhs != rhs else { return tree }
        return swapWalk(lhs: lhs, rhs: rhs, in: tree)
    }

    /// Replace the leaf matching `old` with a leaf for `new`, in place:
    /// the enclosing split node, its child order, and its `extents` are
    /// preserved byte-for-byte; only the leaf's slot identity changes.
    /// The pending→real pane swap uses this so a freshly-attached pane
    /// lands at the exact position and divider proportions its
    /// placeholder held (remove+reinsert would compact a 2-child split
    /// and lose the proportions).
    ///
    /// No-op when `old` is absent, or when `new` already appears in the
    /// tree (guards the leaf-uniqueness invariant).
    static func replace(slot old: PaneSlot, with new: PaneSlot, in tree: PaneNode) -> PaneNode {
        guard path(to: old, in: tree) != nil else { return tree }
        guard path(to: new, in: tree) == nil else { return tree }
        return replaceWalk(old: old, new: new, in: tree)
    }

    /// Swap the leaf at `slot` with its in-display-order neighbor in
    /// the requested direction. Returns the same tree (a no-op) when
    /// the slot is at the corresponding edge of the display order.
    /// Used by the ⌘⇧← / ⌘⇧→ keyboard rearrange so the same input now
    /// crosses what used to be the terminal/sim block boundary.
    static func swapAdjacent(slot: PaneSlot, direction: Int, in tree: PaneNode) -> PaneNode {
        let order = leavesInOrder(tree)
        guard let here = order.firstIndex(of: slot) else { return tree }
        let target = here + direction
        guard target >= 0, target < order.count else { return tree }
        return swap(slot, with: order[target], in: tree)
    }

    // MARK: - Internals

    private static func zoneToInsertion(_ zone: DropZone) -> (SplitAxis, AdjacentSide) {
        switch zone {
        case .leftHalf:
            return (.horizontal, .before)

        case .rightHalf:
            return (.horizontal, .after)

        case .topHalf:
            return (.vertical, .before)

        case .bottomHalf:
            return (.vertical, .after)

        case .center:
            // Caller routes `.center` through `swap`; this branch
            // shouldn't be reached, but pick a safe default rather
            // than asserting and tripping a release build.
            return (.horizontal, .after)
        }
    }

    private static func insertWalk(
        newLeaf: PaneSlot,
        target: PaneSlot,
        axis: SplitAxis,
        side: AdjacentSide,
        in tree: PaneNode,
        naturalExtent: CGFloat
    ) -> PaneNode? {
        switch tree {
        case let .leaf(here):
            guard here == target else { return nil }
            let leaves: [PaneNode] = side == .before
                ? [.leaf(newLeaf), .leaf(here)]
                : [.leaf(here), .leaf(newLeaf)]
            let existing: CGFloat = 1
            let extents: [CGFloat] = side == .before
                ? [naturalExtent, existing]
                : [existing, naturalExtent]
            return .split(axis: axis, children: leaves, extents: extents)

        case let .split(existingAxis, children, extents):
            // If the target sits directly as a child of this split,
            // we either extend siblings (axis matches) or wrap the
            // target child in a fresh sub-split (axis differs).
            for (index, child) in children.enumerated() {
                guard case let .leaf(slot) = child, slot == target else { continue }
                if existingAxis == axis {
                    var newChildren = children
                    var newExtents = extents
                    let insertAt = side == .before ? index : index + 1
                    newChildren.insert(.leaf(newLeaf), at: insertAt)
                    newExtents.insert(naturalExtent, at: insertAt)
                    return .split(
                        axis: existingAxis,
                        children: newChildren,
                        extents: newExtents
                    )
                }
                let wrapped: PaneNode = .split(
                    axis: axis,
                    children: side == .before
                        ? [.leaf(newLeaf), child]
                        : [child, .leaf(newLeaf)],
                    extents: side == .before
                        ? [naturalExtent, 1]
                        : [1, naturalExtent]
                )
                var newChildren = children
                newChildren[index] = wrapped
                return .split(
                    axis: existingAxis,
                    children: newChildren,
                    extents: extents
                )
            }
            // Otherwise recurse into the split node that contains the
            // target.
            for (index, child) in children.enumerated() {
                guard let mutated = insertWalk(
                    newLeaf: newLeaf,
                    target: target,
                    axis: axis,
                    side: side,
                    in: child,
                    naturalExtent: naturalExtent
                ) else { continue }
                var newChildren = children
                newChildren[index] = mutated
                return .split(
                    axis: existingAxis,
                    children: newChildren,
                    extents: extents
                )
            }
            return nil
        }
    }

    private static func removeWalk(slot: PaneSlot, from tree: PaneNode) -> PaneNode? {
        switch tree {
        case let .leaf(here):
            return here == slot ? nil : tree

        case let .split(axis, children, extents):
            var newChildren: [PaneNode] = []
            var newExtents: [CGFloat] = []
            for (index, child) in children.enumerated() {
                if let kept = removeWalk(slot: slot, from: child) {
                    newChildren.append(kept)
                    newExtents.append(extents[index])
                }
            }
            switch newChildren.count {
            case 0:
                return nil

            case 1:
                return newChildren[0]

            default:
                return .split(axis: axis, children: newChildren, extents: newExtents)
            }
        }
    }

    private static func replaceWalk(old: PaneSlot, new: PaneSlot, in tree: PaneNode) -> PaneNode {
        switch tree {
        case let .leaf(here):
            return here == old ? .leaf(new) : tree

        case let .split(axis, children, extents):
            let mapped = children.map { replaceWalk(old: old, new: new, in: $0) }
            return .split(axis: axis, children: mapped, extents: extents)
        }
    }

    private static func swapWalk(lhs: PaneSlot, rhs: PaneSlot, in tree: PaneNode) -> PaneNode {
        switch tree {
        case let .leaf(here):
            if here == lhs { return .leaf(rhs) }
            if here == rhs { return .leaf(lhs) }
            return tree

        case let .split(axis, children, extents):
            let swapped = children.map { swapWalk(lhs: lhs, rhs: rhs, in: $0) }
            return .split(axis: axis, children: swapped, extents: extents)
        }
    }
}
