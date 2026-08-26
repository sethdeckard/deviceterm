// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// Pure proportion / divider-position arithmetic for the
/// split-view ratio engine in `PaneLayoutViewController`. The controller owns
/// the `NSSplitView` walking and the `ratiosByPath` store; the numeric
/// work (normalizing extents to proportions, reserving divider thickness,
/// and turning proportions back into cumulative `setPosition` values)
/// lives here so it can be unit-tested without any AppKit views.
///
/// A "ratio" is a proportion in `0...1`; the ratios for one split sum to
/// 1. Divider positions are the cumulative point offsets passed to
/// `NSSplitView.setPosition(_:ofDividerAt:)`, one per interior divider.
enum PaneRatioMath {
    /// Even proportions across `count` children (each `1 / count`).
    /// Returns an empty array for a non-positive count.
    static func evenSplit(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        return Array(repeating: 1.0 / CGFloat(count), count: count)
    }

    /// Normalize non-negative `extents` to proportions summing to 1, or
    /// nil when the total is not positive (the caller keeps its prior
    /// ratios rather than dividing by zero).
    static func normalize(_ extents: [CGFloat]) -> [CGFloat]? {
        let total = extents.reduce(0, +)
        guard total > 0 else { return nil }
        return extents.map { $0 / total }
    }

    /// Proportions from natural extents: the normalized extents, or an
    /// even split when the total is not positive.
    static func proportions(naturalExtents: [CGFloat]) -> [CGFloat] {
        normalize(naturalExtents) ?? evenSplit(count: naturalExtents.count)
    }

    /// Usable extent along the split axis after reserving `dividerThickness`
    /// between each of `count` children. Never negative.
    static func usableExtent(
        axisExtent: CGFloat,
        dividerThickness: CGFloat,
        count: Int
    ) -> CGFloat {
        let dividers = CGFloat(max(0, count - 1)) * dividerThickness
        return max(0, axisExtent - dividers)
    }

    /// Cumulative divider positions for `ratios` laid out across
    /// `usableExtent`, stepping over `dividerThickness` between panes.
    /// Returns `ratios.count - 1` entries, the argument for each
    /// interior `setPosition(_:ofDividerAt:)` call, in divider order.
    static func dividerPositions(
        ratios: [CGFloat],
        usableExtent: CGFloat,
        dividerThickness: CGFloat
    ) -> [CGFloat] {
        guard ratios.count >= 2 else { return [] }
        var positions: [CGFloat] = []
        positions.reserveCapacity(ratios.count - 1)
        var cumulative: CGFloat = 0
        for index in 0..<(ratios.count - 1) {
            cumulative += ratios[index] * usableExtent
            positions.append(cumulative)
            cumulative += dividerThickness
        }
        return positions
    }
}
