// SPDX-License-Identifier: GPL-3.0-or-later
//
// Spatial neighbor resolution for the ⌥⌘ arrows. Frames are in the
// layout controller's own coordinate space, which is AppKit's default
// orientation, so a larger y is higher on screen.
//
// Every layout here is written as explicit rectangles rather than built
// from a `PaneNode`, because the whole point of the snapshot input is
// that the tree's `extents` do not track a dragged divider.

@testable import App
import CoreGraphics
import Testing

@MainActor
struct PaneDirectionalFocusMathTests {
    private static let left = PaneSlot.terminal(TerminalPaneID(value: 1))
    private static let topRight = PaneSlot.terminal(TerminalPaneID(value: 2))
    private static let bottomRight = PaneSlot.sim(udid: "udid-br")

    // MARK: - Two panes side by side

    @Test
    func resolvesTheObviousNeighborInEachDirection() {
        let frames: [PaneSlot: CGRect] = [
            Self.left: CGRect(x: 0, y: 0, width: 100, height: 100),
            Self.topRight: CGRect(x: 101, y: 0, width: 100, height: 100)
        ]
        #expect(neighbor(of: Self.left, .right, frames) == Self.topRight)
        #expect(neighbor(of: Self.topRight, .left, frames) == Self.left)
    }

    @Test
    func stopsAtTheEdgeInsteadOfWrapping() {
        // Wrapping would send "look left" to the far right of the tab,
        // which reads as a jump rather than a move.
        let frames: [PaneSlot: CGRect] = [
            Self.left: CGRect(x: 0, y: 0, width: 100, height: 100),
            Self.topRight: CGRect(x: 101, y: 0, width: 100, height: 100)
        ]
        #expect(neighbor(of: Self.left, .left, frames) == nil)
        #expect(neighbor(of: Self.topRight, .right, frames) == nil)
        #expect(neighbor(of: Self.left, .above, frames) == nil)
        #expect(neighbor(of: Self.left, .below, frames) == nil)
    }

    @Test
    func stackedPanesResolveVertically() {
        // y grows upward, so the pane with the larger origin is above.
        let lower = CGRect(x: 0, y: 0, width: 100, height: 100)
        let upper = CGRect(x: 0, y: 101, width: 100, height: 100)
        let frames: [PaneSlot: CGRect] = [Self.left: lower, Self.topRight: upper]
        #expect(neighbor(of: Self.left, .above, frames) == Self.topRight)
        #expect(neighbor(of: Self.topRight, .below, frames) == Self.left)
    }

    // MARK: - A dragged divider, where the tree's extents would lie

    @Test
    func picksTheCandidateNearestTheOriginsCenterAfterADividerDrag() {
        // `[A | [B / C]]` with the right column's divider dragged so B
        // takes most of the height. Seeded extents in the tree are still
        // [1, 1], so anything reading them would answer differently.
        let frames: [PaneSlot: CGRect] = [
            Self.left: CGRect(x: 0, y: 0, width: 100, height: 200),
            Self.topRight: CGRect(x: 101, y: 81, width: 100, height: 119),
            Self.bottomRight: CGRect(x: 101, y: 0, width: 100, height: 80)
        ]
        // A's vertical center is 100, inside B, which is the pane the
        // eye is already level with.
        #expect(neighbor(of: Self.left, .right, frames) == Self.topRight)
    }

    @Test
    func aSymmetricSplitBreaksItsTieTowardTheLowerPane() {
        // Two equally-good candidates: same gap, same center distance.
        // The answer has to be stable, since the frames arrive in a
        // dictionary whose order varies run to run.
        let frames: [PaneSlot: CGRect] = [
            Self.left: CGRect(x: 0, y: 0, width: 100, height: 200),
            Self.topRight: CGRect(x: 101, y: 101, width: 100, height: 99),
            Self.bottomRight: CGRect(x: 101, y: 0, width: 100, height: 99)
        ]
        for _ in 0..<20 {
            #expect(neighbor(of: Self.left, .right, frames) == Self.bottomRight)
        }
    }

    // MARK: - Overlap vs distance

    @Test
    func prefersAnOverlappingPaneOverACloserDiagonalOne() {
        // The diagonal pane is nearer along x, but the arrow meant
        // "the pane beside this one", not "the nearest pane that way".
        let frames: [PaneSlot: CGRect] = [
            Self.left: CGRect(x: 0, y: 0, width: 100, height: 100),
            Self.topRight: CGRect(x: 101, y: 200, width: 50, height: 50),
            Self.bottomRight: CGRect(x: 300, y: 0, width: 50, height: 100)
        ]
        #expect(neighbor(of: Self.left, .right, frames) == Self.bottomRight)
    }

    @Test
    func fallsBackToTheDiagonalWhenNothingOverlaps() {
        // Returning nil here would strand the user in an L-shaped
        // layout with a direction that visibly has a pane in it.
        let frames: [PaneSlot: CGRect] = [
            Self.left: CGRect(x: 0, y: 100, width: 100, height: 100),
            Self.topRight: CGRect(x: 101, y: 0, width: 100, height: 100)
        ]
        #expect(neighbor(of: Self.left, .right, frames) == Self.topRight)
    }

    @Test
    func aPaneStraddlingTheOriginsEdgeIsNotACandidate() {
        // Only panes wholly beyond the edge count, so an overlapping
        // frame (which a mid-layout snapshot can produce) never reads as
        // a neighbor.
        let frames: [PaneSlot: CGRect] = [
            Self.left: CGRect(x: 0, y: 0, width: 100, height: 100),
            Self.topRight: CGRect(x: 90, y: 0, width: 100, height: 100)
        ]
        #expect(neighbor(of: Self.left, .right, frames) == nil)
    }

    // MARK: - Degenerate inputs

    @Test
    func aSolePaneAndAnAbsentOriginBothResolveToNothing() {
        let solo: [PaneSlot: CGRect] = [Self.left: CGRect(x: 0, y: 0, width: 100, height: 100)]
        #expect(neighbor(of: Self.left, .right, solo) == nil)
        #expect(neighbor(of: Self.topRight, .right, solo) == nil)
        #expect(neighbor(of: Self.left, .right, [:]) == nil)
    }

    @Test
    func aLetterboxedDevicePaneIsAimedAtByItsSlotNotItsContent() {
        // A device pane letterboxes a portrait screen inside a wide
        // slot. The snapshot keys on the slot, which is the region the
        // user is pointing at; keying on rendered content would leave
        // the empty margins unreachable.
        let deviceSlot = CGRect(x: 101, y: 0, width: 300, height: 200)
        let frames: [PaneSlot: CGRect] = [
            Self.left: CGRect(x: 0, y: 0, width: 100, height: 200),
            Self.bottomRight: deviceSlot,
            // Sits beyond the device's *content* (a narrow centered
            // strip) but inside its slot, so it must not win.
            Self.topRight: CGRect(x: 401, y: 0, width: 100, height: 200)
        ]
        #expect(neighbor(of: Self.left, .right, frames) == Self.bottomRight)
    }

    private func neighbor(
        of origin: PaneSlot,
        _ direction: PaneFocusDirection,
        _ frames: [PaneSlot: CGRect]
    ) -> PaneSlot? {
        PaneDirectionalFocusMath.neighbor(of: origin, direction: direction, frames: frames)
    }
}
