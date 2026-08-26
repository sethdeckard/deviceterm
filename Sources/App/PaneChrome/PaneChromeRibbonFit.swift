// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The pane chrome's horizontal layout constants,
/// plus the math that predicts whether the expanded ribbon can share the
/// 28pt chrome row with an untruncated device name.
///
/// `PaneChromeOverlay` lays the row out with these same constants, so the
/// numbers that draw the ribbon and the numbers that predict its width
/// are one set. Splitting them (literals in the view, a copy here) is the
/// drift this file exists to prevent: a spacing tweak in the view would
/// silently teach the prediction to lie.
///
/// Why predict at all: the ribbon's contents are incompressible (fixed
/// 22pt buttons, a `.fixedSize()` size-preset menu), so SwiftUI layout
/// cannot report that the ribbon does not fit. It truncates the title out
/// of existence instead and lets the ribbon sit on top of it. Only the
/// title and the spacer between the two regions can give. The pane view
/// controller uses `fitsExpanded` once, when a pane's launch layout
/// settles, to decide whether that pane opens expanded.
enum PaneChromeRibbonFit {
    // MARK: - Shared layout constants

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

    /// Point size of the expand / collapse chevron glyph.
    static let chevronFontSize: CGFloat = 13

    /// The chevron is the one ribbon control with no explicit frame, so
    /// it lays out at the SF Symbol's own width. Measured, not guessed:
    /// `chevron.left` at `chevronFontSize` medium reports 10pt wide.
    /// Held as a constant rather than measured at call time so the math
    /// above stays pure and testable; `safetyMargin` covers the drift if
    /// a future SF Symbols revision reshapes the glyph.
    static let chevronWidth: CGFloat = 10

    /// Slack folded into the fit threshold, covering the chevron
    /// constant and SwiftUI's sub-point rounding. Deliberately biases a
    /// near-miss toward *collapsed*: covering the device name is worse
    /// than leaving the ribbon collapsed.
    static let safetyMargin: CGFloat = 4

    // MARK: - Fit math

    /// Width of the fully expanded ribbon capsule holding `actionCount`
    /// action buttons: capsule padding, the chevron, the action row plus
    /// the size-preset menu, and the trailing ⋯ overflow.
    ///
    /// The inner action row is `actionCount` buttons followed by the
    /// size-preset menu, so it has `actionCount` gaps, not one fewer.
    static func expandedRibbonWidth(actionCount: Int) -> CGFloat {
        let actions = max(0, actionCount)
        let contentWidth = CGFloat(actions) * controlButtonWidth
            + CGFloat(actions) * contentItemSpacing
            + sizePresetWidth
        return ribbonHorizontalPadding * 2
            + chevronWidth
            + ribbonItemSpacing * 2
            + contentWidth
            + controlButtonWidth
    }

    /// Narrowest pane that shows the expanded ribbon with the whole
    /// device name still visible: leading inset, drag grip, gap, badge,
    /// title, the minimum gap, then the ribbon itself.
    ///
    /// The grip shares the row rather than floating over it, so
    /// omitting its width and trailing gap would report a fit at widths
    /// where the title has to truncate.
    static func minimumPaneWidthForExpandedRibbon(
        titleWidth: CGFloat,
        actionCount: Int
    ) -> CGFloat {
        leadingPadding
            + handleWidth
            + handleTrailingGap
            + badgeSize
            + badgeTitleSpacing
            + max(0, titleWidth)
            + minimumTitleGap
            + expandedRibbonWidth(actionCount: actionCount)
            + safetyMargin
    }

    /// Whether a pane this wide can open with its ribbon expanded.
    static func fitsExpanded(
        paneWidth: CGFloat,
        titleWidth: CGFloat,
        actionCount: Int
    ) -> Bool {
        paneWidth >= minimumPaneWidthForExpandedRibbon(
            titleWidth: titleWidth,
            actionCount: actionCount
        )
    }

    /// Rendered width of a chrome title at the overlay's font.
    ///
    /// The AppKit arm of the math above, kept separate because it needs
    /// `NSFont` and so isn't pure. This is the only text measurement in
    /// the GUI: every other label sizes itself through Auto Layout
    /// hugging or SwiftUI's own layout, neither of which can answer
    /// "would this fit?" ahead of a layout pass. SwiftUI's
    /// `.font(.system(size:weight:))` resolves to the same
    /// `NSFont.systemFont`, so the measurement matches what gets drawn.
    static func titleWidth(_ title: String) -> CGFloat {
        guard !title.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: titleFontSize, weight: .medium)
        return (title as NSString)
            .size(withAttributes: [.font: font])
            .width
            .rounded(.up)
    }
}
