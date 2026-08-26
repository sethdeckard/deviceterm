// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// The linear pane walk behind Next Pane / Previous Pane. Wrapping and
/// the no-focus start are the two cases a user hits first, so both are
/// pinned rather than left to the arrow keys to discover.
@MainActor
struct PaneFocusOrderMathTests {
    private let first = PaneSlot.terminal(TerminalPaneID(value: 1))
    private let middle = PaneSlot.sim(udid: "udid-b")
    private let last = PaneSlot.terminal(TerminalPaneID(value: 3))

    private var order: [PaneSlot] { [first, middle, last] }

    @Test
    func stepsForwardAndBackward() {
        #expect(PaneFocusOrderMath.nextSlot(from: first, delta: 1, order: order) == middle)
        #expect(PaneFocusOrderMath.nextSlot(from: middle, delta: 1, order: order) == last)
        #expect(PaneFocusOrderMath.nextSlot(from: last, delta: -1, order: order) == middle)
    }

    @Test
    func wrapsAtBothEnds() {
        #expect(PaneFocusOrderMath.nextSlot(from: last, delta: 1, order: order) == first)
        #expect(PaneFocusOrderMath.nextSlot(from: first, delta: -1, order: order) == last)
    }

    @Test
    func startsAtAnEndWhenNothingIsFocused() {
        // Focus can sit outside the tab entirely (a sheet, the tab
        // strip), and the first press should still land somewhere
        // predictable rather than doing nothing.
        #expect(PaneFocusOrderMath.nextSlot(from: nil, delta: 1, order: order) == first)
        #expect(PaneFocusOrderMath.nextSlot(from: nil, delta: -1, order: order) == last)
    }

    @Test
    func startsAtAnEndWhenTheFocusedSlotIsAbsent() {
        // A focused slot missing from `order` reads as no focus.
        // Production derives both values in one synchronous read, so
        // this input does not arise there; the guard is what keeps the
        // function total for any caller.
        let stale = PaneSlot.terminal(TerminalPaneID(value: 99))
        #expect(PaneFocusOrderMath.nextSlot(from: stale, delta: 1, order: order) == first)
    }

    @Test
    func aSolePaneIsANoOp() {
        // Cycling one pane back onto itself would steal focus from a
        // descendant (a sheet's text field) for no benefit.
        #expect(PaneFocusOrderMath.nextSlot(from: first, delta: 1, order: [first]) == nil)
        #expect(PaneFocusOrderMath.nextSlot(from: nil, delta: 1, order: [first]) == nil)
        #expect(PaneFocusOrderMath.nextSlot(from: nil, delta: 1, order: []) == nil)
    }

    @Test
    func aDeltaLargerThanTheOrderStillLands() {
        #expect(PaneFocusOrderMath.nextSlot(from: first, delta: 4, order: order) == middle)
        #expect(PaneFocusOrderMath.nextSlot(from: first, delta: -4, order: order) == last)
    }

    // MARK: - Handing focus off when panes go away

    @Test
    func aSurvivingFocusedPaneKeepsFocus() {
        #expect(
            PaneFocusOrderMath.survivor(of: middle, order: order, surviving: [first, middle])
                == middle
        )
    }

    @Test
    func aClosedPaneHandsOffForward() {
        #expect(
            PaneFocusOrderMath.survivor(of: first, order: order, surviving: [middle, last])
                == middle
        )
    }

    @Test
    func theHandoffWrapsPastTheEnd() {
        #expect(
            PaneFocusOrderMath.survivor(of: last, order: order, surviving: [first, middle])
                == first
        )
    }

    @Test
    func theHandoffSkipsPanesThatAlsoWentAway() {
        // The survivor set may omit consecutive panes, so the walk has to
        // keep going rather than stop at the first name it reads.
        #expect(
            PaneFocusOrderMath.survivor(of: first, order: order, surviving: [last])
                == last
        )
    }

    @Test
    func nothingToHandOffToNamesNoPane() {
        #expect(PaneFocusOrderMath.survivor(of: nil, order: order, surviving: [first]) == nil)
        #expect(PaneFocusOrderMath.survivor(of: first, order: order, surviving: []) == nil)
        #expect(PaneFocusOrderMath.survivor(of: first, order: [first], surviving: []) == nil)
    }

    @Test
    func aFocusedSlotOutsideTheOrderNamesNoPane() {
        // Focus sitting outside the tab has no position to walk from.
        let stale = PaneSlot.terminal(TerminalPaneID(value: 99))
        #expect(PaneFocusOrderMath.survivor(of: stale, order: order, surviving: [first]) == nil)
    }
}
