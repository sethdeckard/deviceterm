// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

/// The width math behind "open this pane's
/// chrome ribbon expanded". Three claims worth pinning:
///
///   1. A wide expanded ribbon genuinely does not fit a minimum-width
///      pane. If this ever computes as fitting, panes at the 380pt
///      floor open with the ribbon painted across the device name,
///      which is the exact defect the fit check exists to prevent.
///   2. Fewer actions means a lower threshold. The action count is
///      family- and capability-driven, so a physical device (buttons +
///      rotation only) has to clear a lower bar than a phone sim's
///      full row. A threshold that ignored the count would be wrong
///      for one of them.
///   3. The threshold moves with the title. The device name is the
///      thing being protected, so a longer name has to demand a wider
///      pane.
@MainActor
struct PaneChromeRibbonFitTests {
    /// The full phone-sim row: home, screenshot, record, rotate left,
    /// rotate right, AX inspector, lock, side, Siri, Apple Pay.
    private let phoneActions = 10
    /// A physical device's row: rotate left/right plus home, lock,
    /// side, Siri.
    private let deviceActions = 6
    /// `PaneLayoutViewController.simMinThickness`'s non-watch minimum
    /// width, the narrowest a phone sim pane can be dragged to when
    /// panes sit side by side.
    private let minimumSimPaneWidth: CGFloat = 380

    @Test
    func expandedWidthGrowsWithActionCount() {
        let none = PaneChromeRibbonFit.expandedRibbonWidth(actionCount: 0)
        let device = PaneChromeRibbonFit.expandedRibbonWidth(actionCount: deviceActions)
        let phone = PaneChromeRibbonFit.expandedRibbonWidth(actionCount: phoneActions)
        #expect(none < device)
        #expect(device < phone)
        // Each added action costs exactly one button plus one gap.
        let step = PaneChromeRibbonFit.controlButtonWidth
            + PaneChromeRibbonFit.contentItemSpacing
        #expect(phone - device == step * CGFloat(phoneActions - deviceActions))
    }

    @Test
    func negativeActionCountClampsToEmptyRow() {
        // Defensive: a count can only come from `ribbonActions.count`,
        // but the math must not produce a nonsense narrow threshold if
        // it ever sees garbage.
        #expect(
            PaneChromeRibbonFit.expandedRibbonWidth(actionCount: -3)
                == PaneChromeRibbonFit.expandedRibbonWidth(actionCount: 0)
        )
    }

    @Test
    func phoneRibbonDoesNotFitAMinimumWidthPane() {
        let title = PaneChromeRibbonFit.titleWidth("iPhone 17 Pro")
        #expect(
            PaneChromeRibbonFit.fitsExpanded(
                paneWidth: minimumSimPaneWidth,
                titleWidth: title,
                actionCount: phoneActions
            ) == false
        )
    }

    @Test
    func phoneRibbonFitsAWidePane() {
        let title = PaneChromeRibbonFit.titleWidth("iPhone 17 Pro")
        #expect(
            PaneChromeRibbonFit.fitsExpanded(
                paneWidth: 900,
                titleWidth: title,
                actionCount: phoneActions
            )
        )
    }

    @Test
    func fewerActionsFitANarrowerPane() {
        let title = PaneChromeRibbonFit.titleWidth("iPhone 17 Pro")
        let deviceThreshold = PaneChromeRibbonFit.minimumPaneWidthForExpandedRibbon(
            titleWidth: title,
            actionCount: deviceActions
        )
        // A pane sized exactly for the device row is too narrow for the
        // sim row, so the count is what decides, not a fixed constant.
        #expect(
            PaneChromeRibbonFit.fitsExpanded(
                paneWidth: deviceThreshold,
                titleWidth: title,
                actionCount: deviceActions
            )
        )
        #expect(
            PaneChromeRibbonFit.fitsExpanded(
                paneWidth: deviceThreshold,
                titleWidth: title,
                actionCount: phoneActions
            ) == false
        )
    }

    @Test
    func longerTitleRaisesTheThreshold() {
        let short = PaneChromeRibbonFit.minimumPaneWidthForExpandedRibbon(
            titleWidth: PaneChromeRibbonFit.titleWidth("Apple TV"),
            actionCount: phoneActions
        )
        let long = PaneChromeRibbonFit.minimumPaneWidthForExpandedRibbon(
            titleWidth: PaneChromeRibbonFit.titleWidth("Apple Watch Series 11 (46mm)"),
            actionCount: phoneActions
        )
        #expect(short < long)
    }

    @Test
    func emptyTitleMeasuresZero() {
        #expect(PaneChromeRibbonFit.titleWidth("") == 0)
        #expect(PaneChromeRibbonFit.titleWidth("iPhone 17 Pro") > 0)
    }

    @Test
    func thresholdIsInclusiveAndOnePointNarrowerFails() {
        let title = PaneChromeRibbonFit.titleWidth("iPhone 17 Pro")
        let threshold = PaneChromeRibbonFit.minimumPaneWidthForExpandedRibbon(
            titleWidth: title,
            actionCount: phoneActions
        )
        #expect(
            PaneChromeRibbonFit.fitsExpanded(
                paneWidth: threshold,
                titleWidth: title,
                actionCount: phoneActions
            )
        )
        #expect(
            PaneChromeRibbonFit.fitsExpanded(
                paneWidth: threshold - 1,
                titleWidth: title,
                actionCount: phoneActions
            ) == false
        )
    }
}
