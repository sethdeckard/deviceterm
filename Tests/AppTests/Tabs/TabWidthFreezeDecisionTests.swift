// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// When the strip holds its widths, and what lets go.
///
/// A freeze that never ends is worse than none: the strip would stop tracking
/// its own contents. Most of these pin the release rather than the hold.
struct TabWidthFreezeDecisionTests {
    @Test
    func aCloseButtonClickUnderThePointerFreezes() {
        #expect(
            TabWidthFreezeDecision.shouldFreeze(
                origin: .closeButton,
                pointerIsOverStrip: true
            )
        )
    }

    /// ⌘W, the context menu, `deviceterm tab close`, and a shell exit all
    /// arrive with the pointer wherever it was, so there is no run of clicks
    /// to protect.
    @Test(arguments: [true, false])
    func closingFromElsewhereNeverFreezes(pointerIsOverStrip: Bool) {
        #expect(
            TabWidthFreezeDecision.shouldFreeze(
                origin: .elsewhere,
                pointerIsOverStrip: pointerIsOverStrip
            ) == false
        )
    }

    /// The ✕ can be activated through accessibility with the pointer nowhere
    /// near the strip, which is the case this guard exists for.
    @Test
    func aCloseButtonClickAwayFromTheStripDoesNotFreeze() {
        #expect(
            TabWidthFreezeDecision.shouldFreeze(
                origin: .closeButton,
                pointerIsOverStrip: false
            ) == false
        )
    }

    /// A shrinking strip is the run the freeze exists for, so it holds.
    @Test(arguments: [(6, 5), (5, 4), (2, 1)])
    func aClosedTabKeepsTheFreeze(previous: Int, current: Int) {
        #expect(
            TabWidthFreezeDecision.shouldThawOnTabCountChange(
                from: previous,
                to: current
            ) == false
        )
    }

    /// A tab opening, or one dropped in from another window, means the strip
    /// is no longer the shape the widths were measured against.
    @Test(arguments: [(5, 6), (1, 3), (0, 1)])
    func aNewTabThaws(previous: Int, current: Int) {
        #expect(
            TabWidthFreezeDecision.shouldThawOnTabCountChange(
                from: previous,
                to: current
            )
        )
    }

    /// A rebuild that leaves the count alone is a reorder or a replacement
    /// rather than a close, so it gets the normal re-flow too.
    @Test
    func anUnchangedCountThaws() {
        #expect(TabWidthFreezeDecision.shouldThawOnTabCountChange(from: 4, to: 4))
    }
}
