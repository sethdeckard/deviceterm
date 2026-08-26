// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import CoreGraphics
import Testing

/// TabDropMath: cursor→gap insertion index + live-reorder target slot.
struct TabDropMathTests {
    private let mids: [CGFloat] = [50, 150, 250]   // three pills, 100pt each
    // Three 100pt-wide pills at x = 0, 100, 200.
    private let frames: [CGRect] = [
        CGRect(x: 0, y: 0, width: 100, height: 30),
        CGRect(x: 100, y: 0, width: 100, height: 30),
        CGRect(x: 200, y: 0, width: 100, height: 30)
    ]

    @Test
    func beforeFirstPillIsGapZero() {
        #expect(TabDropMath.insertionIndex(forX: 10, cellMidXs: mids) == 0)
    }

    @Test
    func pastLastPillIsGapCount() {
        #expect(TabDropMath.insertionIndex(forX: 999, cellMidXs: mids) == 3)
    }

    @Test
    func betweenPillsPicksTheGap() {
        // Just right of pill 0's midpoint but left of pill 1's → gap 1.
        #expect(TabDropMath.insertionIndex(forX: 120, cellMidXs: mids) == 1)
        // Right of pill 1's midpoint → gap 2.
        #expect(TabDropMath.insertionIndex(forX: 200, cellMidXs: mids) == 2)
    }

    @Test
    func emptyStripIsAlwaysGapZero() {
        #expect(TabDropMath.insertionIndex(forX: 42, cellMidXs: []) == 0)
    }

    @Test
    func liveTargetStaysPutNearTheDraggedSlot() {
        // Cursor over the dragged pill's own cell → no move.
        #expect(TabDropMath.liveTargetIndex(draggedIndex: 0, cursorX: 20, cellFrames: frames) == 0)
    }

    @Test
    func liveTargetAdvancesEarlyIntoTheRightNeighbor() {
        // Dragging pill 0 right: crossing a third into pill 1 (x > 133)
        // already swaps, well before pill 1's far edge (200).
        #expect(TabDropMath.liveTargetIndex(draggedIndex: 0, cursorX: 140, cellFrames: frames) == 1)
        // Just inside pill 1 but before the third-threshold → not yet.
        #expect(TabDropMath.liveTargetIndex(draggedIndex: 0, cursorX: 110, cellFrames: frames) == 0)
        // Far right → last slot.
        #expect(TabDropMath.liveTargetIndex(draggedIndex: 0, cursorX: 260, cellFrames: frames) == 2)
    }

    @Test
    func liveTargetRetreatsEarlyIntoTheLeftNeighbor() {
        // Dragging pill 2 left: crossing a third into pill 1 from its
        // right edge (x < 166) swaps.
        #expect(TabDropMath.liveTargetIndex(draggedIndex: 2, cursorX: 160, cellFrames: frames) == 1)
        #expect(TabDropMath.liveTargetIndex(draggedIndex: 2, cursorX: 40, cellFrames: frames) == 0)
        // Just inside pill 1 from the right but before the threshold.
        #expect(TabDropMath.liveTargetIndex(draggedIndex: 2, cursorX: 190, cellFrames: frames) == 2)
    }
}
