// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import TerminalSurface

/// Pure row↔pixel math for the visible scroll
/// indicator. AppKit's coordinate system is +Y-up (origin bottom-
/// left); the terminal model is +Y-down (row 0 = top of history).
/// SurfaceScrollView calls into these helpers to keep the inversion
/// localised + unit-testable, away from the AppKit observation
/// plumbing where bugs would be hard to pin.
enum SurfaceScrollMath {
    /// Height the document view should take, given a scrollbar
    /// snapshot + the visible-rect height. The grid contributes
    /// `total × cellHeight`; the leftover (vertical) padding inside
    /// the visible rect (the strip that isn't covered by `len`
    /// rows) is preserved at the top of the document so the terminal
    /// grid stays vertically aligned with the surface view across
    /// row counts.
    static func documentHeight(
        scrollbar: ScrollbarState,
        cellHeight: CGFloat,
        visibleHeight: CGFloat
    ) -> CGFloat {
        guard cellHeight > 0 else { return visibleHeight }
        let gridHeight = CGFloat(scrollbar.total) * cellHeight
        let padding = visibleHeight - CGFloat(scrollbar.len) * cellHeight
        return gridHeight + padding
    }

    /// The clip-view origin Y that places the viewport at the row
    /// `scrollbar.offset` in the document view. AppKit measures from
    /// the bottom, so the formula is
    /// `(total - offset - len) × cellHeight`. Clamps to 0 when
    /// `offset + len` momentarily exceeds `total` during a resize
    /// race (the renderer can emit a SCROLLBAR mid-resize where the
    /// invariant doesn't hold; better to pin to the bottom than to
    /// emit a negative origin and confuse NSClipView).
    static func scrollOriginY(
        scrollbar: ScrollbarState,
        cellHeight: CGFloat
    ) -> CGFloat {
        guard cellHeight > 0 else { return 0 }
        let total = Int64(scrollbar.total)
        let offset = Int64(scrollbar.offset)
        let len = Int64(scrollbar.len)
        let invertedRows = max(0, total - offset - len)
        return CGFloat(invertedRows) * cellHeight
    }

    /// Inverse of `scrollOriginY`: given a clip-view origin (from a
    /// user-driven live scroll), the document height, the visible
    /// height, and the cell height, compute the row libghostty
    /// should scroll to. Negative results clamp to 0 (above-top
    /// rubber-banding); the row is unsigned in the engine.
    static func row(
        forScrollOriginY originY: CGFloat,
        documentHeight: CGFloat,
        visibleHeight: CGFloat,
        cellHeight: CGFloat
    ) -> Int {
        guard cellHeight > 0 else { return 0 }
        let bottomOffset = documentHeight - originY - visibleHeight
        let row = Int((bottomOffset / cellHeight).rounded())
        return max(0, row)
    }
}
