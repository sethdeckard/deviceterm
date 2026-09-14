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
///   4. The threshold reserves the drag grip. It includes the grip and
///      its gap so it does not report a fit at widths where the title
///      would truncate.
///
/// Plus the reveal ladder the drag settles onto:
///
///   5. The ladder's viewport widths strictly ascend. Stop 0 shows the hot
///      action, stop 1 replaces it with the size-preset menu, and every later
///      stop adds one button and one gap.
///   6. The widest rung equals the expanded ribbon. This is the anti-drift
///      claim: the two are separate expressions, and the ladder would be
///      wrong everywhere if its top did not land on the width the ribbon
///      already used.
///   7. `widestFittingStop` climbs with pane width, is inclusive at each
///      threshold, and floors at stop 0 rather than refusing to answer.
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

    @Test
    func thresholdReservesTheDragGrip() {
        let title = PaneChromeRibbonFit.titleWidth("iPhone 17 Pro")
        let threshold = PaneChromeRibbonFit.minimumPaneWidthForExpandedRibbon(
            titleWidth: title,
            actionCount: phoneActions
        )
        // The same sum with the grip's leading region removed. The
        // difference must equal the grip width plus its trailing gap.
        let withoutGrip = PaneChromeRibbonFit.leadingPadding
            + PaneChromeRibbonFit.badgeSize
            + PaneChromeRibbonFit.badgeTitleSpacing
            + title
            + PaneChromeRibbonFit.minimumTitleGap
            + PaneChromeRibbonFit.expandedRibbonWidth(actionCount: phoneActions)
            + PaneChromeRibbonFit.safetyMargin
        #expect(
            threshold - withoutGrip
                == PaneChromeRibbonFit.handleWidth + PaneChromeRibbonFit.handleTrailingGap
        )
    }

    // MARK: - Reveal ladder

    @Test
    func theLadderAscends() {
        let widest = PaneChromeRibbonFit.widestStop(actionCount: phoneActions)
        // One rung per action, plus the size-preset menu's own rung.
        #expect(widest == phoneActions + 1)
        let ladder = (0...widest).map { PaneChromeRibbonFit.contentWidth(stop: $0) }
        #expect(ladder == ladder.sorted())
        #expect(Set(ladder).count == ladder.count)
    }

    @Test
    func theNarrowestStopIsASingleButton() {
        #expect(
            PaneChromeRibbonFit.contentWidth(stop: 0)
                == PaneChromeRibbonFit.controlButtonWidth
        )
        // A negative stop can only arrive from arithmetic on a clamped
        // value, but it must not widen the viewport if it ever does.
        #expect(
            PaneChromeRibbonFit.contentWidth(stop: -4)
                == PaneChromeRibbonFit.contentWidth(stop: 0)
        )
    }

    @Test
    func theFirstRevealStopIsTheSizePresetMenuAlone() {
        // The menu is the row's trailing item, so it is what a drag uncovers
        // first. An actionless pane has only this rung above the hot action,
        // and it is the whole reason that rung exists.
        #expect(
            PaneChromeRibbonFit.contentWidth(stop: 1)
                == PaneChromeRibbonFit.sizePresetWidth
        )
    }

    @Test("every stop above the first costs one button and one gap", arguments: 1...11)
    func laterStopsCostOneButton(stop: Int) {
        let step = PaneChromeRibbonFit.contentWidth(stop: stop + 1)
            - PaneChromeRibbonFit.contentWidth(stop: stop)
        #expect(
            step == PaneChromeRibbonFit.controlButtonWidth
                + PaneChromeRibbonFit.contentItemSpacing
        )
    }

    @Test("the widest stop matches the expanded ribbon", arguments: 0...12)
    func theWidestStopMatchesTodaysExpandedRibbon(actionCount: Int) {
        // The anti-drift claim for the whole ladder: two separate expressions
        // that must land on the same width, including the empty row.
        #expect(
            PaneChromeRibbonFit.ribbonWidth(
                stop: PaneChromeRibbonFit.widestStop(actionCount: actionCount)
            ) == PaneChromeRibbonFit.expandedRibbonWidth(actionCount: actionCount)
        )
    }

    @Test
    func theNarrowestStopSitsOutsideTheRow() {
        // Stop 0 shows the hot action rather than any part of the row, so it
        // is the one rung the row's arithmetic does not describe.
        #expect(
            PaneChromeRibbonFit.contentWidth(stop: 0)
                == PaneChromeRibbonFit.controlButtonWidth
        )
        let step = PaneChromeRibbonFit.contentWidth(stop: 1)
            - PaneChromeRibbonFit.contentWidth(stop: 0)
        #expect(
            step == PaneChromeRibbonFit.sizePresetWidth
                - PaneChromeRibbonFit.controlButtonWidth
        )
    }

    @Test
    func ribbonWidthFollowsTheContentViewport() {
        // Affine with slope 1: the AppKit hit-test override locates the
        // handle by subtracting this from the pane width, which is only
        // correct while a point of viewport costs a point of capsule.
        let base = PaneChromeRibbonFit.ribbonWidth(contentWidth: 0)
        #expect(PaneChromeRibbonFit.ribbonWidth(contentWidth: 40) == base + 40)
        #expect(PaneChromeRibbonFit.ribbonWidth(contentWidth: 137.5) == base + 137.5)
    }

    @Test
    func widestFittingStopClimbsWithPaneWidth() {
        let title = PaneChromeRibbonFit.titleWidth("iPhone 17 Pro")
        var previous = -1
        for stop in 0...PaneChromeRibbonFit.widestStop(actionCount: phoneActions) {
            let width = PaneChromeRibbonFit.minimumPaneWidth(
                forStop: stop,
                titleWidth: title
            )
            let fitting = PaneChromeRibbonFit.widestFittingStop(
                paneWidth: width,
                titleWidth: title,
                actionCount: phoneActions
            )
            #expect(fitting == stop)
            #expect(fitting > previous)
            previous = fitting
        }
    }

    @Test("each stop's threshold is inclusive", arguments: 0...11)
    func widestFittingStopThresholdsAreInclusive(stop: Int) {
        let title = PaneChromeRibbonFit.titleWidth("iPhone 17 Pro")
        let threshold = PaneChromeRibbonFit.minimumPaneWidth(
            forStop: stop,
            titleWidth: title
        )
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: threshold,
                titleWidth: title,
                actionCount: phoneActions
            ) == stop
        )
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: threshold - 1,
                titleWidth: title,
                actionCount: phoneActions
            ) == max(0, stop - 1)
        )
    }

    @Test
    func widestFittingStopFloorsAtTheHotAction() {
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: 1,
                titleWidth: PaneChromeRibbonFit.titleWidth("iPhone 17 Pro"),
                actionCount: phoneActions
            ) == 0
        )
    }

    @Test
    func widestFittingStopAgreesWithFitsExpandedAtTheTop() {
        let title = PaneChromeRibbonFit.titleWidth("iPhone 17 Pro")
        for paneWidth in stride(from: CGFloat(150), through: 900, by: 7) {
            let reachesTop = PaneChromeRibbonFit.widestFittingStop(
                paneWidth: paneWidth,
                titleWidth: title,
                actionCount: phoneActions
            ) == PaneChromeRibbonFit.widestStop(actionCount: phoneActions)
            let fits = PaneChromeRibbonFit.fitsExpanded(
                paneWidth: paneWidth,
                titleWidth: title,
                actionCount: phoneActions
            )
            #expect(reachesTop == fits, "disagreed at \(paneWidth)")
        }
    }

    @Test
    func anActionlessRibbonKeepsTheSizeMenuRung() {
        // A capability-stripped pane reports no actions, and still needs the
        // rung its size-preset menu sits on. Collapsing such a ribbon to one
        // rung would strand the menu behind a stop nothing can reach.
        #expect(PaneChromeRibbonFit.widestStop(actionCount: 0) == 1)
        #expect(PaneChromeRibbonFit.widestStop(actionCount: -2) == 1)
        let ladder = (0...PaneChromeRibbonFit.widestStop(actionCount: 0))
            .map { PaneChromeRibbonFit.contentWidth(stop: $0) }
        #expect(ladder == [
            PaneChromeRibbonFit.controlButtonWidth,
            PaneChromeRibbonFit.sizePresetWidth
        ])
        // A wide pane reaches that rung; only a cramped one falls back to the
        // hot action alone.
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: 900,
                titleWidth: 80,
                actionCount: 0
            ) == 1
        )
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: 1,
                titleWidth: 80,
                actionCount: 0
            ) == 0
        )
    }

    @Test
    func theHandleZoneCoversTheGlyphPlusSlop() {
        let zone = PaneChromeRibbonFit.chevronHandleZone
        let glyphStart = PaneChromeRibbonFit.ribbonHorizontalPadding
        let glyphEnd = glyphStart + PaneChromeRibbonFit.chevronWidth
        #expect(zone.lowerBound == glyphStart - PaneChromeRibbonFit.chevronHitSlop)
        #expect(zone.upperBound == glyphEnd + PaneChromeRibbonFit.chevronHitSlop)
        #expect(zone.contains(glyphStart))
        #expect(zone.contains(glyphEnd))
        // Inside the capsule: a zone reaching past its leading edge would claim
        // points the gesture target cannot be positioned to cover.
        #expect(zone.lowerBound >= 0)
    }

    @Test
    func theHandleWidthIsTheZoneItIsMeantToCover() {
        // The gesture target is sized from this while the hover zone and the
        // AppKit hit-test override test the range. A width that did not equal
        // the range's span would leave a band where the cursor promises a
        // resize the gesture never receives.
        #expect(
            PaneChromeRibbonFit.chevronHandleWidth
                == PaneChromeRibbonFit.chevronHandleZone.upperBound
                - PaneChromeRibbonFit.chevronHandleZone.lowerBound
        )
        #expect(
            PaneChromeRibbonFit.chevronHandleWidth
                == PaneChromeRibbonFit.chevronWidth
                + PaneChromeRibbonFit.chevronHitSlop * 2
        )
    }

    @Test
    func theHandleHysteresisMatchesThePaneDragThreshold() {
        // `PaneChromeDragHostView.mouseDragged` reads this same constant,
        // so a change here moves both affordances together.
        #expect(PaneChromeRibbonFit.dragActivationDistance == 4)
    }

    @Test
    func gripConstantsAreNonZero() {
        // Zero width or height erases the grip; a zero trailing gap
        // removes its separation from the badge. None of the three
        // fails anything else: the row still lays out and the fit math
        // still answers.
        #expect(PaneChromeRibbonFit.handleWidth > 0)
        #expect(PaneChromeRibbonFit.handleHeight > 0)
        #expect(PaneChromeRibbonFit.handleTrailingGap > 0)
    }
}
