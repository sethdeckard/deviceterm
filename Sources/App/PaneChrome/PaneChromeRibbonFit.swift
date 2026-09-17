// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// The pane chrome's horizontal layout constants,
/// plus the math that predicts how much of the ribbon the 28pt chrome row
/// can hold.
///
/// `PaneChromeOverlay` lays the row out with these same constants, so the
/// numbers that draw the ribbon and the numbers that predict its width
/// are one set. Splitting them (literals in the view, a copy here) is the
/// drift this file exists to prevent: a spacing tweak in the view would
/// silently teach the prediction to lie.
///
/// Why predict at all: the ribbon's contents are incompressible (fixed
/// 22pt buttons, a `.fixedSize()` size-preset menu), so SwiftUI layout
/// cannot report that the ribbon does not fit. Handed a row narrower than
/// the ribbon's ideal width it overruns the chrome instead, pushing the
/// grip and badge past the leading edge. `widestFittingStop` is what keeps
/// the pane view controller from ever asking for a stop that wide; it runs
/// on every layout pass to cap what the ribbon draws.
///
/// The device name reserves nothing here. It is the region that yields:
/// the ribbon opens as wide as the pane allows and the name truncates
/// behind it, with the whole string still reachable on the tooltip. Only
/// the grip, the badge, and the gap before the ribbon are pinned.
enum PaneChromeRibbonFit {
    // MARK: - Shared layout constants

    /// Height of the chrome row, uniform across device families.
    ///
    /// Shared because three surfaces have to agree on it: the SwiftUI row
    /// draws it, the pane view controller reserves it with a constraint, and
    /// the resize handle's hit region spans it. The handle is why the last one
    /// matters, since a hit region shorter than the region AppKit reserves for
    /// it leaves a band that neither the gesture nor the pane drag will take.
    static let chromeRowHeight: CGFloat = 28

    /// Leading inset before the drag grip, which opens the row.
    static let leadingPadding: CGFloat = 8
    /// Thickness of the drag grip capsule.
    static let handleWidth: CGFloat = 3
    /// Length of the drag grip capsule. Chosen to read as a vertical
    /// grip rather than a horizontal seam.
    static let handleHeight: CGFloat = 14
    /// Gap between the drag grip and the status badge.
    static let handleTrailingGap: CGFloat = 8
    /// Status badge is a square; `StatusBadgeView` is framed to it.
    static let badgeSize: CGFloat = 12
    /// Gap between the badge and the title.
    static let badgeTitleSpacing: CGFloat = 6
    /// Title point size. Rendered `.medium` weight.
    static let titleFontSize: CGFloat = 12
    /// Smallest gap the spacer between title and ribbon will collapse
    /// to. Below this the two regions are touching, which is the
    /// condition "enough room" is defined against.
    static let minimumTitleGap: CGFloat = 8

    /// Inset on each end of the ribbon capsule.
    static let ribbonHorizontalPadding: CGFloat = 8
    /// Gap between the ribbon's three regions (chevron, contents, ⋯).
    static let ribbonItemSpacing: CGFloat = 6
    /// Gap between individual action buttons inside the ribbon.
    static let contentItemSpacing: CGFloat = 4
    /// Square frame every ribbon action button and the ⋯ overflow use.
    static let controlButtonWidth: CGFloat = 22
    /// The size-preset menu, wider than a plain button so the borderless
    /// menu's disclosure has room.
    static let sizePresetWidth: CGFloat = 28

    /// Point size of the chevron glyph on the ribbon's resize handle.
    static let chevronFontSize: CGFloat = 13

    /// The chevron is the one ribbon control with no explicit frame, so
    /// it lays out at the SF Symbol's own width. Measured, not guessed:
    /// `chevron.left` at `chevronFontSize` medium reports 10pt wide.
    /// Held as a constant rather than measured at call time so the math
    /// above stays pure and testable; `safetyMargin` covers the drift if
    /// a future SF Symbols revision reshapes the glyph.
    ///
    /// The resize handle widens the grabbable region by `chevronHitSlop`
    /// through an `.overlay`, which does not change the laid-out width,
    /// so this stays the number the row actually occupies. Widening the
    /// glyph's own frame instead would make it lie.
    static let chevronWidth: CGFloat = 10

    /// Hit and cursor slop on each side of the chevron glyph. The glyph is
    /// `chevronWidth` across, too thin to grab reliably, so the handle's
    /// grabbable region extends this far past each edge of it.
    static let chevronHitSlop: CGFloat = 6

    /// Pointer travel that separates a click from a drag, shared by the
    /// ribbon's resize handle and `PaneChromeDragHostView`'s
    /// pane-rearrange threshold so the two affordances arm at the same
    /// distance.
    static let dragActivationDistance: CGFloat = 4

    /// The handle's horizontal span, in the ribbon capsule's own coordinates:
    /// the chevron glyph, which starts after the capsule inset, widened by
    /// `chevronHitSlop` at each end.
    ///
    /// Three surfaces resolve the handle from this one range: the SwiftUI
    /// gesture target's width, the hover zone that picks the resize cursor, and
    /// the AppKit hit-test override that withholds the column from the
    /// pane-drag host. A range rather than a width because the override needs
    /// both edges: explicit edges keep the zone it withholds aligned with the
    /// gesture target, which sits centered on the glyph and so cannot cover a
    /// zone measured from the capsule's leading edge.
    static var chevronHandleZone: ClosedRange<CGFloat> {
        let start = ribbonHorizontalPadding - chevronHitSlop
        return start...(ribbonHorizontalPadding + chevronWidth + chevronHitSlop)
    }

    /// Width of the handle's gesture target, which is the glyph plus its slop
    /// at each end.
    static var chevronHandleWidth: CGFloat {
        chevronHandleZone.upperBound - chevronHandleZone.lowerBound
    }

    /// Slack folded into every reveal threshold, covering the chevron constant
    /// and SwiftUI's sub-point rounding. Deliberately biases a near miss toward
    /// the next narrower stop, which is preferable to overrunning the row.
    static let safetyMargin: CGFloat = 4

    /// Everything the row reserves ahead of the ribbon whatever the device
    /// name says: leading inset, drag grip and its gap, the badge and the gap
    /// after it, and the smallest gap before the ribbon starts.
    ///
    /// The name's own width is the one thing not in this sum, which is what
    /// lets a long one coexist with the full row: it truncates rather than
    /// pushing the ribbon narrower. Everything else here is fixed even when
    /// the name renders nothing at all, `badgeTitleSpacing` included, because
    /// an `HStack` spaces its children by position rather than by width and
    /// the title view is in the row whether or not it has glyphs to show.
    /// Omitting any of them would report a fit at widths where the ribbon
    /// overruns the grip and badge.
    static var pinnedLeadingWidth: CGFloat {
        leadingPadding
            + handleWidth
            + handleTrailingGap
            + badgeSize
            + badgeTitleSpacing
            + minimumTitleGap
    }

    // MARK: - Reveal ladder

    /// Highest reveal stop for a ribbon holding `actionCount` actions.
    ///
    /// One more than the action count, because the size-preset menu is the
    /// row's trailing item and so occupies a rung of its own. A ribbon with
    /// no actions at all still has two stops, which is what keeps its size
    /// menu reachable.
    static func widestStop(actionCount: Int) -> Int {
        max(0, actionCount) + 1
    }

    /// Width of the ribbon's inner content viewport at reveal `stop`.
    ///
    /// A stop counts how many trailing items of the row `[actions…,
    /// size-preset menu]` are revealed, so stop 1 is the menu on its own and
    /// stop k above that adds `k - 1` actions ahead of it. Stop 0 is outside
    /// the row entirely: it shows the hot action instead, or nothing at all on
    /// a pane with no action to offer.
    static func contentWidth(stop: Int) -> CGFloat {
        guard stop > 0 else { return controlButtonWidth }
        return CGFloat(stop - 1) * (controlButtonWidth + contentItemSpacing)
            + sizePresetWidth
    }

    /// Ribbon capsule width around a content viewport this wide: capsule
    /// padding, the chevron, the viewport, and the trailing ⋯ overflow.
    ///
    /// The SwiftUI layout and the AppKit hit-test override both locate
    /// the handle from this, so the two cannot disagree about where the
    /// ribbon starts.
    static func ribbonWidth(contentWidth: CGFloat) -> CGFloat {
        ribbonHorizontalPadding * 2
            + chevronWidth
            + ribbonItemSpacing * 2
            + contentWidth
            + controlButtonWidth
    }

    /// Ribbon capsule width at reveal `stop`.
    static func ribbonWidth(stop: Int) -> CGFloat {
        ribbonWidth(contentWidth: contentWidth(stop: stop))
    }

    /// How many of the row's actions reveal at `stop`.
    ///
    /// One fewer than the stop, because stop 1 is the size-preset menu on its
    /// own and stop 0 is outside the row entirely. Drives which buttons are
    /// on screen, and so which of them may be clicked.
    static func revealedActionCount(stop: Int) -> Int {
        max(0, stop - 1)
    }

    /// Narrowest pane that can draw reveal `stop` without the ribbon
    /// overrunning the pinned leading region.
    static func minimumPaneWidth(forStop stop: Int) -> CGFloat {
        pinnedLeadingWidth + ribbonWidth(stop: stop) + safetyMargin
    }

    /// Widest reveal stop a pane this wide can draw, or stop 0 when it fits
    /// none.
    ///
    /// Floors there rather than reporting "nothing fits", because stop 0 is
    /// the ribbon's minimum-width state and a pane narrower than that has no
    /// better answer to offer. Every family's minimum pane width clears
    /// several rungs, so the floor guards a width no layout produces rather
    /// than a case panes routinely land in.
    static func widestFittingStop(paneWidth: CGFloat, actionCount: Int) -> Int {
        let widest = widestStop(actionCount: actionCount)
        let fitting = (0...widest).last { paneWidth >= minimumPaneWidth(forStop: $0) }
        return fitting ?? 0
    }
}
