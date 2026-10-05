// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

/// The width math behind "how much of this pane's
/// chrome ribbon fits". Four claims worth pinning:
///
///   1. Every family's minimum pane width draws a stop that fits. The
///      ribbon is incompressible, so a stop the row cannot hold does not
///      lay out narrower, it overruns the chrome and pushes the grip and
///      badge past the leading edge. This is the property the cap exists
///      for, and the 380pt phone floor and 220pt watch floor are where it
///      is closest to failing.
///   2. Fewer actions means a lower threshold. The action count is
///      family- and capability-driven, so a physical device (buttons,
///      App Switcher, and rotation) has to clear a lower bar than a phone
///      sim's full row. A threshold that ignored the count would be wrong
///      for one of them.
///   3. The device name costs nothing. It truncates behind the ribbon
///      rather than pushing it narrower, which is what lets a long name
///      coexist with the full row. The math has no way to express a title
///      at all, and these tests are what keep it that way.
///   4. The threshold reserves the drag grip. It includes the grip and
///      its gap so it does not report a fit at widths where the ribbon
///      would overrun them.
///
/// Plus the reveal ladder the drag settles onto:
///
///   5. The ladder's viewport widths strictly ascend. Stop 0 shows the hot
///      action, stop 1 replaces it with the size-preset menu, and every later
///      stop adds one button and one gap.
///   6. The widest rung uncovers every action plus the size-preset menu.
///      This is the anti-drift claim: the ladder would be wrong everywhere
///      if its top did not land on the whole row.
///   7. `widestFittingStop` climbs with pane width, is inclusive at each
///      threshold, and floors at stop 0 rather than refusing to answer.
@MainActor
struct PaneChromeRibbonFitTests {
    /// The full phone-sim row: home, App Switcher, screenshot, record,
    /// rotate left, rotate right, AX inspector, lock, side, Siri, Apple Pay.
    private let phoneActions = 11
    /// A physical device's row: rotate left/right plus home, App Switcher,
    /// lock, side, Siri.
    private let deviceActions = 7
    /// `PaneLayoutViewController.simMinThickness`'s non-watch minimum
    /// width, the narrowest a phone sim pane can be dragged to when
    /// panes sit side by side.
    private let minimumSimPaneWidth: CGFloat = 380
    /// The same floor for a watch pane, which is where the widest ribbon
    /// overshoots the pane by the largest margin.
    private let minimumWatchPaneWidth: CGFloat = 220
    /// A watch sim's row: side, AX inspector, record, screenshot, and the
    /// three Digital Crown controls.
    private let watchActions = 7

    @Test
    func expandedWidthGrowsWithActionCount() {
        let none = widestRibbonWidth(actionCount: 0)
        let device = widestRibbonWidth(actionCount: deviceActions)
        let phone = widestRibbonWidth(actionCount: phoneActions)
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
        #expect(widestRibbonWidth(actionCount: -3) == widestRibbonWidth(actionCount: 0))
    }

    // Narrow widths paired with the action count the family reports there.
    // 380 and 220 are `PaneLayoutViewController.simMinThickness`'s side-by-side
    // floors for phone/pad and watch, the narrowest a pane of each can be
    // dragged to. 280 and 200 are the same function's stacked-layout floors,
    // which bound height rather than width, sampled here as widths a stacked
    // pane can still reach. Spelled out rather than read from the properties
    // above because `arguments:` is an attribute and cannot reach them.
    @Test(
        "a narrow pane draws a stop that fits",
        arguments: [
            (380 as CGFloat, 11), (280 as CGFloat, 11),
            (220 as CGFloat, 7), (200 as CGFloat, 7)
        ]
    )
    func aNarrowPaneDrawsAStopThatFits(paneWidth: CGFloat, actionCount: Int) {
        // A stop wider than the row can hold does not compress, it overruns
        // the chrome, so the answer at each width has to be a stop that width
        // genuinely fits.
        let stop = PaneChromeRibbonFit.widestFittingStop(
            paneWidth: paneWidth,
            actionCount: actionCount
        )
        #expect(PaneChromeRibbonFit.minimumPaneWidth(forStop: stop) <= paneWidth)
        // And it must be a usable ribbon, not the stop-0 floor: every one of
        // these widths clears several rungs, including the size-preset menu's.
        #expect(stop >= 1)
    }

    @Test
    func theWidestRibbonOverrunsAMinimumWidthPane() {
        // The flip side of the claim above: these widths are narrow enough
        // that the cap has real work to do. If this ever computes as
        // fitting, the cap has become a no-op and the test above stops
        // proving anything.
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: minimumSimPaneWidth,
                actionCount: phoneActions
            ) < PaneChromeRibbonFit.widestStop(actionCount: phoneActions)
        )
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: minimumWatchPaneWidth,
                actionCount: watchActions
            ) < PaneChromeRibbonFit.widestStop(actionCount: watchActions)
        )
    }

    @Test
    func aWidePaneReachesTheWidestStop() {
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: 900,
                actionCount: phoneActions
            ) == PaneChromeRibbonFit.widestStop(actionCount: phoneActions)
        )
    }

    @Test
    func fewerActionsFitANarrowerPane() {
        let deviceThreshold = PaneChromeRibbonFit.minimumPaneWidth(
            forStop: PaneChromeRibbonFit.widestStop(actionCount: deviceActions)
        )
        // A pane sized exactly for the device row is too narrow for the
        // sim row, so the count is what decides, not a fixed constant.
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: deviceThreshold,
                actionCount: deviceActions
            ) == PaneChromeRibbonFit.widestStop(actionCount: deviceActions)
        )
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: deviceThreshold,
                actionCount: phoneActions
            ) < PaneChromeRibbonFit.widestStop(actionCount: phoneActions)
        )
    }

    @Test
    func thresholdReservesTheGripBadgeAndGap() {
        // Claims 3 and 4 together. These six terms stay in the row even when
        // the title renders nothing, `badgeTitleSpacing` included, since an
        // `HStack` spaces its children by position rather than by width. The
        // device name's own width is the one thing excluded, which is what
        // lets a long one coexist with the full row.
        #expect(
            PaneChromeRibbonFit.pinnedLeadingWidth
                == PaneChromeRibbonFit.leadingPadding
                + PaneChromeRibbonFit.handleWidth
                + PaneChromeRibbonFit.handleTrailingGap
                + PaneChromeRibbonFit.badgeSize
                + PaneChromeRibbonFit.badgeTitleSpacing
                + PaneChromeRibbonFit.minimumTitleGap
        )
        let stop = PaneChromeRibbonFit.widestStop(actionCount: phoneActions)
        #expect(
            PaneChromeRibbonFit.minimumPaneWidth(forStop: stop)
                == PaneChromeRibbonFit.pinnedLeadingWidth
                + PaneChromeRibbonFit.ribbonWidth(stop: stop)
                + PaneChromeRibbonFit.safetyMargin
        )
    }

    @Test("the threshold covers every fixed term the row draws", arguments: 0...11)
    func theThresholdCoversTheRowsOwnSum(stop: Int) {
        // Sum the row's fixed widths independently, grouped the way
        // `PaneChromeOverlay.body` nests them and with the title at the zero
        // width it truncates to, so a term the fit math omits shows up as a
        // threshold narrower than the row it has to hold.
        let grip = PaneChromeRibbonFit.leadingPadding + PaneChromeRibbonFit.handleWidth
        let badgeAndTitle = PaneChromeRibbonFit.handleTrailingGap
            + PaneChromeRibbonFit.badgeSize
            + PaneChromeRibbonFit.badgeTitleSpacing
        let ribbon = PaneChromeRibbonFit.ribbonHorizontalPadding * 2
            + PaneChromeRibbonFit.chevronWidth
            + PaneChromeRibbonFit.ribbonItemSpacing * 2
            + PaneChromeRibbonFit.contentWidth(stop: stop)
            + PaneChromeRibbonFit.controlButtonWidth
        let row = grip + badgeAndTitle + PaneChromeRibbonFit.minimumTitleGap + ribbon
        #expect(PaneChromeRibbonFit.minimumPaneWidth(forStop: stop) >= row)
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

    @Test("the widest stop uncovers the whole row", arguments: 0...12)
    func theWidestStopUncoversEveryAction(actionCount: Int) {
        // The anti-drift claim for the whole ladder: its top rung has to
        // uncover every action plus the size-preset menu, including on the
        // empty row. Written as the row's own sum rather than as another
        // ladder call, so the two expressions can disagree.
        let actions = CGFloat(max(0, actionCount))
        let step = PaneChromeRibbonFit.controlButtonWidth
            + PaneChromeRibbonFit.contentItemSpacing
        #expect(
            PaneChromeRibbonFit.contentWidth(
                stop: PaneChromeRibbonFit.widestStop(actionCount: actionCount)
            ) == actions * step + PaneChromeRibbonFit.sizePresetWidth
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
        var previous = -1
        for stop in 0...PaneChromeRibbonFit.widestStop(actionCount: phoneActions) {
            let width = PaneChromeRibbonFit.minimumPaneWidth(forStop: stop)
            let fitting = PaneChromeRibbonFit.widestFittingStop(
                paneWidth: width,
                actionCount: phoneActions
            )
            #expect(fitting == stop)
            #expect(fitting > previous)
            previous = fitting
        }
    }

    @Test("each stop's threshold is inclusive", arguments: 0...11)
    func widestFittingStopThresholdsAreInclusive(stop: Int) {
        let threshold = PaneChromeRibbonFit.minimumPaneWidth(forStop: stop)
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: threshold,
                actionCount: phoneActions
            ) == stop
        )
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: threshold - 1,
                actionCount: phoneActions
            ) == max(0, stop - 1)
        )
    }

    @Test
    func widestFittingStopFloorsAtTheHotAction() {
        #expect(
            PaneChromeRibbonFit.widestFittingStop(
                paneWidth: 1,
                actionCount: phoneActions
            ) == 0
        )
    }

    @Test
    func widestFittingStopNeverFallsAsThePaneWidens() {
        // Swept between the thresholds as well as at them, so a stop that
        // dips anywhere in the range is caught rather than only one that
        // dips where a rung changes.
        var previous = 0
        for paneWidth in stride(from: CGFloat(150), through: 900, by: 1) {
            let stop = PaneChromeRibbonFit.widestFittingStop(
                paneWidth: paneWidth,
                actionCount: phoneActions
            )
            #expect(stop >= previous, "fell at \(paneWidth)")
            previous = stop
        }
        #expect(previous == PaneChromeRibbonFit.widestStop(actionCount: phoneActions))
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
        #expect(PaneChromeRibbonFit.widestFittingStop(paneWidth: 900, actionCount: 0) == 1)
        #expect(PaneChromeRibbonFit.widestFittingStop(paneWidth: 1, actionCount: 0) == 0)
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

    /// Capsule width at the top of the ladder, which is the ribbon showing
    /// every one of `actionCount` actions plus the size-preset menu.
    private func widestRibbonWidth(actionCount: Int) -> CGFloat {
        PaneChromeRibbonFit.ribbonWidth(
            stop: PaneChromeRibbonFit.widestStop(actionCount: actionCount)
        )
    }
}
