// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import LibghosttyBridge
import TerminalSurface
import Testing

// SurfaceScrollMath is the row↔pixel math behind the visible
// scroll indicator. It lives as a pure namespace because the
// AppKit observation plumbing in `SurfaceScrollView` is hard to
// drive in a unit test (live-scroll notifications, NSClipView
// state) but the math is where bugs land: Y inversion is easy
// to get wrong, resize races can produce out-of-range scrollbar
// snapshots, and the inverse function has to round consistently
// with the forward function or live-scroll feels jittery.

// MARK: - documentHeight

@Test
func documentHeightCoversFullScrollbackPlusPadding() {
    // 1000 rows of history, 24-row viewport, 16pt cell height, 400pt
    // visible height. Grid is 16_000pt; padding is the strip the
    // viewport doesn't cover (400 - 24×16 = 16pt, typically the
    // sub-cell remainder when the window doesn't snap to whole rows).
    let state = ScrollbarState(total: 1_000, offset: 0, len: 24)
    let height = SurfaceScrollMath.documentHeight(
        scrollbar: state,
        cellHeight: 16,
        visibleHeight: 400
    )
    #expect(height == 16_016)
}

@Test
func documentHeightWithoutScrollbackEqualsVisibleHeight() {
    // No history yet, so scrollback exactly equals viewport. Grid
    // height = padding = visible height; doc height = visible
    // height. The scroller is invisible (nothing to scroll).
    let state = ScrollbarState(total: 24, offset: 0, len: 24)
    let height = SurfaceScrollMath.documentHeight(
        scrollbar: state,
        cellHeight: 16,
        visibleHeight: 384
    )
    #expect(height == 384)
}

@Test
func documentHeightFallsBackToVisibleHeightWhenCellSizeUnknown() {
    // Before `attach` succeeds, GhosttyTerminalSurface.cellSize is
    // .zero, so the math helper must not divide-by-zero or report a
    // bogus geometry. Falling back to visible height makes the
    // scroller invisible until cell metrics arrive.
    let state = ScrollbarState(total: 100, offset: 10, len: 24)
    let height = SurfaceScrollMath.documentHeight(
        scrollbar: state,
        cellHeight: 0,
        visibleHeight: 400
    )
    #expect(height == 400)
}

// MARK: - scrollOriginY (terminal → AppKit)

@Test
func scrollOriginYAtBottomOfScrollbackIsZero() {
    // Viewport pinned at "live" end: offset = total - len. AppKit Y
    // origin = 0 (clip view at bottom of doc view = no scrolling).
    let state = ScrollbarState(total: 1_000, offset: 976, len: 24)
    let origin = SurfaceScrollMath.scrollOriginY(
        scrollbar: state,
        cellHeight: 16
    )
    #expect(origin == 0)
}

@Test
func scrollOriginYAtTopOfScrollbackIsMaxOffset() {
    // Viewport at top of history: offset = 0. Origin = full
    // scrollback minus the viewport's rows = (1000 - 0 - 24) × 16
    // = 15_616pt.
    let state = ScrollbarState(total: 1_000, offset: 0, len: 24)
    let origin = SurfaceScrollMath.scrollOriginY(
        scrollbar: state,
        cellHeight: 16
    )
    #expect(origin == 15_616)
}

@Test
func scrollOriginYClampsToZeroWhenOffsetPlusLenExceedsTotal() {
    // Resize race: the renderer momentarily reports a viewport
    // that overshoots `total`. The math must not produce a negative
    // origin (NSClipView would either clamp silently or render
    // garbled bounds). Clamp to 0 = pin to the bottom.
    let state = ScrollbarState(total: 100, offset: 99, len: 40)
    let origin = SurfaceScrollMath.scrollOriginY(
        scrollbar: state,
        cellHeight: 16
    )
    #expect(origin == 0)
}

// MARK: - row (AppKit → terminal)

@Test
func rowAtBottomOfDocumentIsZero() {
    // Document height matches grid + padding; viewport sits at the
    // bottom. The bottom 24 rows correspond to row 0 in the
    // "scroll from the live end backwards" convention libghostty
    // uses. Note that libghostty's `offset` is 0-from-top-of-history,
    // not 0-from-bottom; verify with the inverse of
    // scrollOriginYAtTopOfScrollbackIsMaxOffset above.
    //
    // Doc height 16_016 (from the first test); viewport at origin
    // y=0, height 400 = at the bottom of the doc view. AppKit
    // bottomOffset = 16_016 - 0 - 400 = 15_616 = 976 rows × 16pt.
    // libghostty row = 976 (top of viewport is row 976 in a 1000-
    // row scrollback with 24-row viewport → "live end").
    let row = SurfaceScrollMath.row(
        forScrollOriginY: 0,
        documentHeight: 16_016,
        visibleHeight: 400,
        cellHeight: 16
    )
    #expect(row == 976)
}

@Test
func rowAtTopOfDocumentIsZero() {
    // Viewport at top of document: origin y = 15_616. bottomOffset
    // = 16_016 - 15_616 - 400 = 0. Row 0 = top of scrollback.
    let row = SurfaceScrollMath.row(
        forScrollOriginY: 15_616,
        documentHeight: 16_016,
        visibleHeight: 400,
        cellHeight: 16
    )
    #expect(row == 0)
}

@Test
func rowClampsToZeroWhenScrolledAboveTop() {
    // Rubber-band: clip view origin briefly exceeds document height
    // minus visible height (overscroll past row 0). Engine row is
    // unsigned; clamp to 0 to avoid an underflow + bogus dispatch.
    let row = SurfaceScrollMath.row(
        forScrollOriginY: 20_000,
        documentHeight: 16_016,
        visibleHeight: 400,
        cellHeight: 16
    )
    #expect(row == 0)
}

@Test
func rowRoundsToNearestForLiveScrollStability() {
    // Sub-cell precision: a user drag lands the clip view 9pt away
    // from a row boundary (cellHeight 16, so 9pt > halfway). The
    // forward and inverse functions must round consistently or the
    // `lastSentRow` guard ping-pongs and emits scroll_to_row spam.
    // We round to nearest so a drag past the halfway point counts
    // as the next row.
    let row = SurfaceScrollMath.row(
        forScrollOriginY: 16_016 - 400 - (10 * 16 + 9),
        documentHeight: 16_016,
        visibleHeight: 400,
        cellHeight: 16
    )
    #expect(row == 11)
}

// MARK: - roundTrip

@Test
func forwardAndInverseRoundTripAtRowBoundaries() {
    // The forward map (offset → originY) and the inverse
    // (originY → row) round-trip cleanly when the origin lands on
    // an exact row boundary. This is what the post-SCROLLBAR
    // programmatic seek path relies on for `lastSentRow` to match
    // the next engine emission.
    let state = ScrollbarState(total: 1_000, offset: 500, len: 24)
    let cellHeight: CGFloat = 16
    let visibleHeight: CGFloat = 400
    let docHeight = SurfaceScrollMath.documentHeight(
        scrollbar: state,
        cellHeight: cellHeight,
        visibleHeight: visibleHeight
    )
    let originY = SurfaceScrollMath.scrollOriginY(
        scrollbar: state,
        cellHeight: cellHeight
    )
    let row = SurfaceScrollMath.row(
        forScrollOriginY: originY,
        documentHeight: docHeight,
        visibleHeight: visibleHeight,
        cellHeight: cellHeight
    )
    #expect(row == 500)
}
