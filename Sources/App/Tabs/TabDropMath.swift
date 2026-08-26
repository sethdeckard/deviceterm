// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// Pure cursor→insertion-gap geometry for tab-strip drag
/// reorder, mirroring `PaneDropZoneMath`'s role for panes. Kept separate
/// and dependency-free so the index arithmetic is unit-tested without an
/// AppKit strip. The tab-strip drag destination feeds it the pills'
/// horizontal midpoints and the cursor x; it returns the gap index.
enum TabDropMath {
    /// Fraction of a neighbour's width the cursor must cross (from the
    /// edge facing the dragged pill) before the pill slides past it. A
    /// third means the swap happens well before the cursor reaches the
    /// neighbour's far end, so the reorder feels responsive on wide tabs.
    static let liveSwapFraction: CGFloat = 0.33

    /// Gap index in `0...cellMidXs.count` where a tab dragged to `x`
    /// should be inserted, given each pill's horizontal midpoint in
    /// left-to-right order. The cursor sits before pill `i` when
    /// `x < midXs[i]`; the first such `i` is the gap. Past the last
    /// midpoint returns `count` (drop after the final pill).
    static func insertionIndex(forX x: CGFloat, cellMidXs: [CGFloat]) -> Int {
        for (index, mid) in cellMidXs.enumerated() where x < mid {
            return index
        }
        return cellMidXs.count
    }

    /// New slot for the pill at `draggedIndex` during a live reorder,
    /// given the current pill frames (in left-to-right arranged order,
    /// dragged pill included) and the cursor x. Direction-aware: dragging
    /// right advances past each later neighbour once the cursor crosses
    /// `liveSwapFraction` into it from its near (left) edge; dragging left
    /// is the mirror. The asymmetric near-edge thresholds give natural
    /// hysteresis, so a pill doesn't flicker between two slots when the
    /// cursor hovers a boundary.
    static func liveTargetIndex(
        draggedIndex: Int,
        cursorX: CGFloat,
        cellFrames: [CGRect]
    ) -> Int {
        guard cellFrames.indices.contains(draggedIndex) else { return draggedIndex }
        var target = draggedIndex
        var right = draggedIndex + 1
        while right < cellFrames.count {
            let frame = cellFrames[right]
            guard cursorX > frame.minX + frame.width * liveSwapFraction else { break }
            target = right
            right += 1
        }
        var left = draggedIndex - 1
        while left >= 0 {
            let frame = cellFrames[left]
            guard cursorX < frame.maxX - frame.width * liveSwapFraction else { break }
            target = left
            left -= 1
        }
        return target
    }
}
