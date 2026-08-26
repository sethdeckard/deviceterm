// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// Which pane sits above / below / left / right
/// of the focused one, resolved from a frame snapshot.
///
/// The layout tree cannot answer this. `PaneNode.split` carries
/// `extents`, but those are seeds written at insert time and never
/// updated when a divider is dragged, so a tree-only walk would resolve
/// neighbors against proportions the user cannot see. The input is
/// therefore an explicit snapshot of every leaf's frame in one
/// coordinate space, taken at the moment the key is pressed.
///
/// Coordinates follow AppKit's default orientation, y growing upward, so
/// "above" means a larger y. The layout controller's root view is not
/// flipped, which is where the snapshot comes from.
///
/// Directional focus deliberately does not wrap. Cycling off one edge
/// and reappearing at the opposite one is disorienting when the gesture
/// is "look that way"; Next / Previous Pane is the cycling walk.
enum PaneDirectionalFocusMath {
    /// One candidate reduced to the numbers the ordering reads.
    private struct Ranked {
        let slot: PaneSlot
        /// Distance from the origin's edge to this pane's near edge,
        /// along the direction of travel. Never negative: a pane behind
        /// or straddling that edge is not a candidate at all.
        let gapAhead: CGFloat
        /// Distance between the two panes' centers on the perpendicular
        /// axis.
        let perpendicularCenterDistance: CGFloat
        /// The pane's low edge on the perpendicular axis, the final
        /// tiebreak.
        let perpendicularMin: CGFloat
        /// Whether the two panes' perpendicular spans intersect.
        let overlapsPerpendicular: Bool

        /// Which of two candidates is the better answer.
        ///
        /// `preferNearestAhead` swaps the first two keys: among panes
        /// beside the origin, distance along the direction of travel
        /// decides, while among diagonal panes the sideways offset is
        /// what makes one feel closer.
        func precedes(_ other: Ranked, preferNearestAhead: Bool) -> Bool {
            let mineFirst = preferNearestAhead ? gapAhead : perpendicularCenterDistance
            let theirsFirst = preferNearestAhead
                ? other.gapAhead
                : other.perpendicularCenterDistance
            if mineFirst != theirsFirst { return mineFirst < theirsFirst }
            let mineSecond = preferNearestAhead ? perpendicularCenterDistance : gapAhead
            let theirsSecond = preferNearestAhead
                ? other.perpendicularCenterDistance
                : other.gapAhead
            if mineSecond != theirsSecond { return mineSecond < theirsSecond }
            return perpendicularMin < other.perpendicularMin
        }
    }

    /// The pane to `direction` of `origin`, or nil at the edge.
    ///
    /// Resolution, in order:
    ///
    ///   1. Candidates are panes lying wholly beyond the origin's edge
    ///      on that side. A pane merely overlapping the origin is not a
    ///      neighbor in that direction.
    ///   2. Panes whose perpendicular span overlaps the origin's are
    ///      preferred over panes that only sit diagonally, since a
    ///      diagonal jump is rarely what the arrow meant.
    ///   3. Within the preferred group the nearest along the direction
    ///      of travel wins; in the diagonal fallback the nearest
    ///      perpendicular center wins, because there the sideways
    ///      distance is what makes one candidate feel closer.
    ///   4. Remaining ties break toward the pane whose perpendicular
    ///      center is nearest the origin's, then toward the lower
    ///      perpendicular coordinate. Two leaves of a split cannot share
    ///      a frame, so that is a total order in practice.
    static func neighbor(
        of origin: PaneSlot,
        direction: PaneFocusDirection,
        frames: [PaneSlot: CGRect]
    ) -> PaneSlot? {
        guard let originFrame = frames[origin] else { return nil }
        let ranked = frames.compactMap { slot, frame -> Ranked? in
            guard slot != origin else { return nil }
            return rank(slot: slot, frame: frame, from: originFrame, direction: direction)
        }
        guard !ranked.isEmpty else { return nil }
        let overlapping = ranked.filter(\.overlapsPerpendicular)
        let pool = overlapping.isEmpty ? ranked : overlapping
        let preferNearestAhead = !overlapping.isEmpty
        return pool.min { lhs, rhs in
            lhs.precedes(rhs, preferNearestAhead: preferNearestAhead)
        }?.slot
    }

    private static func rank(
        slot: PaneSlot,
        frame: CGRect,
        from origin: CGRect,
        direction: PaneFocusDirection
    ) -> Ranked? {
        let gapAhead: CGFloat
        let span: (min: CGFloat, max: CGFloat)
        let originSpan: (min: CGFloat, max: CGFloat)
        switch direction {
        case .left:
            gapAhead = origin.minX - frame.maxX
            span = (frame.minY, frame.maxY)
            originSpan = (origin.minY, origin.maxY)

        case .right:
            gapAhead = frame.minX - origin.maxX
            span = (frame.minY, frame.maxY)
            originSpan = (origin.minY, origin.maxY)

        case .above:
            gapAhead = frame.minY - origin.maxY
            span = (frame.minX, frame.maxX)
            originSpan = (origin.minX, origin.maxX)

        case .below:
            gapAhead = origin.minY - frame.maxY
            span = (frame.minX, frame.maxX)
            originSpan = (origin.minX, origin.maxX)
        }
        guard gapAhead >= 0 else { return nil }
        let center = (span.min + span.max) / 2
        let originCenter = (originSpan.min + originSpan.max) / 2
        return Ranked(
            slot: slot,
            gapAhead: gapAhead,
            perpendicularCenterDistance: abs(center - originCenter),
            perpendicularMin: span.min,
            overlapsPerpendicular: span.max > originSpan.min && originSpan.max > span.min
        )
    }
}
