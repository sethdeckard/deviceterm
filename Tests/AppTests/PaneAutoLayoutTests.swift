// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneAutoLayout: pin the per-split extent math. Each test
// constructs synthetic `PaneSlotMetrics` and asserts the chosen
// extents fit the documented algorithm: under-capacity distributes
// remainder to flexibles; over-capacity shrinks proportionally
// clamped at minimums.

@testable import App
import CoreGraphics
import Testing

struct PaneAutoLayoutTests {
    private let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
    private let sim = PaneSlot.sim(udid: "sim-1")

    @Test
    func emptyChildrenReturnsEmpty() {
        #expect(PaneAutoLayout.extents(children: [], availableExtent: 800).isEmpty)
    }

    @Test
    func underCapacityHonorsNaturalsAndDistributesRemainder() {
        let children = [
            PaneSlotMetrics(slot: terminal, naturalExtent: 200, minimumExtent: 100, isFlexible: true),
            PaneSlotMetrics(slot: sim, naturalExtent: 380, minimumExtent: 380, isFlexible: false)
        ]
        let result = PaneAutoLayout.extents(children: children, availableExtent: 800)
        // Total natural = 580; available = 800; remainder 220.
        // Only the terminal is flexible, so it absorbs the remainder.
        #expect(result[0] == 420)
        #expect(result[1] == 380)
    }

    @Test
    func underCapacityNoFlexibleSplitsRemainderEvenly() {
        let children = [
            PaneSlotMetrics(slot: sim, naturalExtent: 200, minimumExtent: 100, isFlexible: false),
            PaneSlotMetrics(slot: sim, naturalExtent: 200, minimumExtent: 100, isFlexible: false)
        ]
        let result = PaneAutoLayout.extents(children: children, availableExtent: 600)
        // Surplus 200; split evenly across the two non-flex children.
        #expect(result[0] == 300)
        #expect(result[1] == 300)
    }

    @Test
    func overCapacityShrinksProportionally() {
        let children = [
            PaneSlotMetrics(slot: terminal, naturalExtent: 400, minimumExtent: 100, isFlexible: true),
            PaneSlotMetrics(slot: sim, naturalExtent: 400, minimumExtent: 100, isFlexible: false)
        ]
        let result = PaneAutoLayout.extents(children: children, availableExtent: 400)
        // Scale 0.5; both clamp above their minimums; total exactly 400.
        #expect(result[0] == 200)
        #expect(result[1] == 200)
    }

    @Test
    func minimumExtentClampedOnShrink() {
        let children = [
            PaneSlotMetrics(slot: terminal, naturalExtent: 400, minimumExtent: 250, isFlexible: true),
            PaneSlotMetrics(slot: sim, naturalExtent: 400, minimumExtent: 100, isFlexible: false)
        ]
        let result = PaneAutoLayout.extents(children: children, availableExtent: 400)
        // 0.5 scale would put both at 200; sim is non-flexible so it
        // gives up its surplus first when shrinking below natural.
        // Terminal stays ≥ its minimum of 250; sim trims to absorb.
        #expect(result[0] >= 250)
        #expect(result[0] + result[1] <= 400.001)
    }

    @Test
    func zeroAvailableExtentReturnsMinimums() {
        let children = [
            PaneSlotMetrics(slot: terminal, naturalExtent: 400, minimumExtent: 100, isFlexible: true),
            PaneSlotMetrics(slot: sim, naturalExtent: 400, minimumExtent: 220, isFlexible: false)
        ]
        let result = PaneAutoLayout.extents(children: children, availableExtent: 0)
        #expect(result == [100, 220])
    }

    @Test
    func singleChildGetsFullExtent() {
        let children = [
            PaneSlotMetrics(slot: terminal, naturalExtent: 200, minimumExtent: 100, isFlexible: true)
        ]
        let result = PaneAutoLayout.extents(children: children, availableExtent: 600)
        #expect(result == [600])
    }
}
