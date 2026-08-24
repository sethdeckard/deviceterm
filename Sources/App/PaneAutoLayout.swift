// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneAutoLayout: pure layout math for a single `.split` node in
// the `PaneNode` tree. The layout controller calls `extents` whenever
// the tree mutates (add / remove / move) or the user picks "Reset
// Pane Layout" so every pane lands at a sensible size without
// relying on `NSSplitView.adjustSubviews`'s opaque proportional
// shrink.
//
// The algorithm is intentionally simple: each child has a natural
// extent (point-accurate width for a sim pane along the divider
// axis; a configurable default for a terminal) and a minimum extent.
// If the children's naturals fit the available extent, terminals
// absorb the leftover space (text reflows; sim panes aspect-fit so
// extra room is wasted). If they don't fit, each child scales down
// proportionally, clamped to its minimum.
//
// Auto-rebalance runs per-split, not whole-tree. Children of a
// horizontal split don't compete for space with children of a
// vertical sibling split; each split is its own budget.

import CoreGraphics
import Foundation

enum PaneAutoLayout {
    /// Compute the extent of each child along the parent split's
    /// divider axis given `availableExtent` (split bounds minus
    /// dividers). Returns one CGFloat per child, in the same order
    /// `children` was passed.
    ///
    /// Algorithm:
    ///
    /// 1. Sum every child's natural extent.
    /// 2. If sum ≤ available: each child gets its natural. The
    ///    remainder distributes to `isFlexible` children proportionally
    ///    to their natural extent; if none are flexible, the remainder
    ///    distributes evenly to everyone.
    /// 3. If sum > available: scale each child proportionally to fit,
    ///    clamped to `minimumExtent`. If clamping leaves the total
    ///    above available, reduce the surplus from the largest
    ///    non-flexible child(ren) first: sim panes give up the
    ///    extra extent before terminals do, because terminals are
    ///    where the user is interacting.
    ///
    /// Empty `children` produces an empty result. A negative or
    /// zero `availableExtent` falls back to each child's minimum
    /// rather than dividing by zero.
    static func extents(
        children: [PaneSlotMetrics],
        availableExtent: CGFloat
    ) -> [CGFloat] {
        guard !children.isEmpty else { return [] }
        let available = max(availableExtent, 0)
        if available <= 0 {
            return children.map(\.minimumExtent)
        }
        let naturals = children.map(\.naturalExtent)
        let totalNatural = naturals.reduce(0, +)
        if totalNatural <= available {
            return distributeRemainder(
                base: naturals,
                surplus: available - totalNatural,
                isFlexible: children.map(\.isFlexible)
            )
        }
        return shrinkProportional(
            naturals: naturals,
            minimums: children.map(\.minimumExtent),
            isFlexible: children.map(\.isFlexible),
            available: available
        )
    }

    private static func distributeRemainder(
        base: [CGFloat],
        surplus: CGFloat,
        isFlexible: [Bool]
    ) -> [CGFloat] {
        guard surplus > 0 else { return base }
        let flexibleIndices = isFlexible.enumerated()
            .compactMap { $0.element ? $0.offset : nil }
        if flexibleIndices.isEmpty {
            let share = surplus / CGFloat(base.count)
            return base.map { $0 + share }
        }
        let flexibleTotal = flexibleIndices.reduce(CGFloat(0)) { $0 + base[$1] }
        var result = base
        if flexibleTotal > 0 {
            for index in flexibleIndices {
                let weight = base[index] / flexibleTotal
                result[index] += surplus * weight
            }
        } else {
            let share = surplus / CGFloat(flexibleIndices.count)
            for index in flexibleIndices {
                result[index] += share
            }
        }
        return result
    }

    private static func shrinkProportional(
        naturals: [CGFloat],
        minimums: [CGFloat],
        isFlexible: [Bool],
        available: CGFloat
    ) -> [CGFloat] {
        let totalNatural = naturals.reduce(0, +)
        let scale = totalNatural > 0 ? available / totalNatural : 1
        var scaled = naturals.map { max($0 * scale, 0) }
        for index in scaled.indices {
            scaled[index] = max(scaled[index], minimums[index])
        }
        var total = scaled.reduce(0, +)
        guard total > available else { return scaled }
        // Surplus over budget, so pull it from the children that have
        // room above their minimum, sim panes first (non-flexible).
        let order = scaled.indices.sorted { lhs, rhs in
            if isFlexible[lhs] != isFlexible[rhs] {
                return !isFlexible[lhs]
            }
            return scaled[lhs] > scaled[rhs]
        }
        for index in order {
            let headroom = scaled[index] - minimums[index]
            if headroom <= 0 { continue }
            let trim = min(headroom, total - available)
            scaled[index] -= trim
            total -= trim
            if total <= available { break }
        }
        return scaled
    }
}
