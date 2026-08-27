// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// Carries each split's divider proportions from one shape of the pane
/// tree onto the next. A split whose panes were reordered hands each its
/// own share; one that only changed around the edges keeps the
/// proportions it had; one that changed shape keeps nothing.
///
/// `PaneRatioStore` keys proportions by a split's path of child indices,
/// which is a statement about position rather than identity. Left alone
/// across a rearrange, the stored entry stays with the slot and the panes
/// trade extents: a sim at a quarter of the width, dragged to the other
/// side of its divider, arrives at three quarters. This maps the old
/// entries onto the new tree first, and the controller's seed pass fills
/// whatever the mapping leaves unclaimed.
///
/// Two rules, per split in the new tree, tried in order:
///
///   1. **Identity.** The split's leaves name exactly one split in the
///      old tree. When the axes and child counts agree and every new
///      child's leaves name exactly one old child, the old proportions
///      come across permuted into the new child order. This is what
///      makes a pane carry its width.
///   2. **Position.** Otherwise the old tree's split at the same path,
///      with the same axis and child count, hands its proportions over
///      unchanged. Replacing a leaf in place (a placeholder becoming
///      the pane it stood in for) and compacting a subtree both land
///      here, and both want the divider left where it is.
///
/// A split matching neither rule gets no entry, which is the answer for
/// a proportion that has stopped meaning anything: a share of width is
/// not a share of height, so flipping an axis reseeds.
///
/// Leaf sets identify splits unambiguously, given two assumptions about
/// the trees coming in: no leaf appears twice, and no split holds a
/// single child. Under those, a split's leaves strictly contain each
/// child's, so no two splits in one tree carry the same set, and sibling
/// sets are disjoint, so a child matches at most one old sibling and the
/// permutation needs no tiebreak.
///
/// Nothing enforces either assumption. `PaneNode` is a plain enum, and
/// of the mutations only `PaneTreeOps.replace` checks that the leaf it
/// introduces is absent. So the lookups below fall through on a repeated
/// key rather than trapping: a divider in the wrong place is a smaller
/// failure than a crash.
enum PaneRatioRemap {
    /// One split of the old tree, indexed by the leaves beneath it.
    private struct OldSplit {
        let path: [Int]
        let axis: SplitAxis
        let childLeaves: [Set<PaneSlot>]
    }

    /// The proportions of `ratios` carried onto `newTree`'s splits.
    ///
    /// The result is built fresh, so it holds entries for paths in
    /// `newTree` and nothing else; a path that stops naming a split
    /// drops rather than waiting to be misread by a later arrangement
    /// that happens to reach the same address.
    static func remapped(
        _ ratios: [[Int]: [CGFloat]],
        from oldTree: PaneNode,
        to newTree: PaneNode
    ) -> [[Int]: [CGFloat]] {
        let indexed = oldSplits(in: oldTree)
        var result: [[Int]: [CGFloat]] = [:]
        forEachSplit(in: newTree, path: []) { path, axis, children in
            let carried = carriedByIdentity(
                ratios: ratios,
                oldSplits: indexed,
                axis: axis,
                children: children
            ) ?? carriedByPosition(
                ratios: ratios,
                oldTree: oldTree,
                path: path,
                axis: axis,
                count: children.count
            )
            if let carried {
                result[path] = carried
            }
        }
        return result
    }

    /// Rule 1: the old proportions of the split holding these same
    /// leaves, permuted into the new child order.
    private static func carriedByIdentity(
        ratios: [[Int]: [CGFloat]],
        oldSplits: [Set<PaneSlot>: OldSplit],
        axis: SplitAxis,
        children: [PaneNode]
    ) -> [CGFloat]? {
        let leaves = children.map { Set(PaneTreeOps.leavesInOrder($0)) }
        guard let old = oldSplits[leaves.reduce(into: Set<PaneSlot>()) { $0.formUnion($1) }],
            old.axis == axis,
            old.childLeaves.count == children.count,
            let oldRatios = ratios[old.path],
            oldRatios.count == children.count else { return nil }
        // Every child has to find its old position. A subset that maps
        // is a partial permutation, which describes panes that crossed
        // between splits rather than reordered within one, and there is
        // no share to carry for the ones that didn't map.
        var permutation: [Int] = []
        permutation.reserveCapacity(children.count)
        for childLeaves in leaves {
            guard let index = old.childLeaves.firstIndex(of: childLeaves) else { return nil }
            permutation.append(index)
        }
        guard Set(permutation).count == permutation.count else { return nil }
        return permutation.map { oldRatios[$0] }
    }

    /// Rule 2: the old proportions of whatever split sat at this
    /// address, when it was the same shape.
    private static func carriedByPosition(
        ratios: [[Int]: [CGFloat]],
        oldTree: PaneNode,
        path: [Int],
        axis: SplitAxis,
        count: Int
    ) -> [CGFloat]? {
        guard case let .split(oldAxis, oldChildren, _)? = node(at: path, in: oldTree),
            oldAxis == axis,
            oldChildren.count == count,
            let oldRatios = ratios[path],
            oldRatios.count == count else { return nil }
        return oldRatios
    }

    /// Every split in `tree`, keyed by the leaves beneath it. A repeated
    /// key would mean the tree broke its own invariants; drop the later
    /// one rather than trap, since a divider landing in the wrong place
    /// is the smaller failure.
    private static func oldSplits(in tree: PaneNode) -> [Set<PaneSlot>: OldSplit] {
        var result: [Set<PaneSlot>: OldSplit] = [:]
        forEachSplit(in: tree, path: []) { path, axis, children in
            let childLeaves = children.map { Set(PaneTreeOps.leavesInOrder($0)) }
            let key = childLeaves.reduce(into: Set<PaneSlot>()) { $0.formUnion($1) }
            guard result[key] == nil else { return }
            result[key] = OldSplit(path: path, axis: axis, childLeaves: childLeaves)
        }
        return result
    }

    /// The node `path` addresses, or nil when the path runs off the
    /// tree.
    private static func node(at path: [Int], in tree: PaneNode) -> PaneNode? {
        guard let index = path.first else { return tree }
        guard case let .split(_, children, _) = tree,
            children.indices.contains(index) else { return nil }
        return node(at: Array(path.dropFirst()), in: children[index])
    }

    private static func forEachSplit(
        in tree: PaneNode,
        path: [Int],
        body: (_ path: [Int], _ axis: SplitAxis, _ children: [PaneNode]) -> Void
    ) {
        guard case let .split(axis, children, _) = tree else { return }
        body(path, axis, children)
        for (index, child) in children.enumerated() {
            forEachSplit(in: child, path: path + [index], body: body)
        }
    }
}
