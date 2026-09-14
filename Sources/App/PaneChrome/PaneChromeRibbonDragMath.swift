// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// How a chevron drag maps pointer travel onto the ribbon's reveal stops.
///
/// The ribbon steps from rung to rung rather than following the pointer
/// continuously, for two reasons:
///
///   1. A rung is a whole button, so a settled rung never leaves a control
///      partially cropped, looking pressable while it is not. The spring
///      between rungs does interpolate the width, so a control can be cropped
///      for the length of that animation.
///   2. The reveal width is a layout width, sitting in a row beside a
///      truncating device name and behind a material capsule. Continuous
///      pointer tracking would re-measure that row on every mouse event;
///      detents hold those layout changes to a dozen across the whole travel.
///
/// Travel is measured in uniform detents rather than in the rungs' own
/// widths, which are uneven: the step onto the size-preset menu is a few
/// points where every step after it is a button plus a gap. Pacing the drag
/// by those widths would make the first detent almost free and the rest
/// deliberate. A fixed distance per rung is what makes the control feel
/// evenly geared.
///
/// There is no overshoot past either end. The ends are a wall, which both
/// reads as solid and keeps the ribbon from ever eating the gap the device
/// name is holding.
enum PaneChromeRibbonDragMath {
    // MARK: - Feel constants

    /// Pointer travel one detent costs, the width of a button and its gap.
    /// Borrowed rather than chosen: a rung's worth of movement to advance a
    /// rung is the gearing a user already expects from the row itself.
    static let detentTravel: CGFloat = PaneChromeRibbonFit.controlButtonWidth
        + PaneChromeRibbonFit.contentItemSpacing

    /// Half-width of each rung's dead band, as a fraction of a detent's
    /// travel. A rung holds from `detentHysteresis` of a detent before its
    /// nominal position to the same distance past it, so leaving a rung costs
    /// more travel than returning to it.
    ///
    /// Above one half for two reasons. It is what makes the band a band at
    /// all: at exactly one half the entry and exit thresholds coincide, the
    /// dead zone closes, and pointer noise around the boundary flutters the
    /// ribbon between two rungs. And it is what guarantees a single pointer
    /// position cannot both advance and retreat, since the rung the drag just
    /// entered sits strictly inside the band it would have to leave.
    static let detentHysteresis: CGFloat = 0.6

    /// Pointer speed at release, in points per second, at or above which the
    /// ribbon carries one rung further. A drag steered onto a rung decelerates
    /// well below this; a flick clears it easily.
    static let flingVelocity: CGFloat = 300

    /// Slack, in points, folded into each threshold so travel landing exactly
    /// on one counts as having crossed it.
    ///
    /// Binary floating point cannot hold these thresholds exactly: a detent's
    /// hysteresis fraction times its travel is not the same number twice
    /// depending on how it was reached, so a boundary value otherwise falls to
    /// whichever side the rounding error lands on, and which rung a drag
    /// reaches becomes unpredictable at the edges. A millionth of a point is
    /// a few nanometres of pointer travel: it settles the tie and changes
    /// nothing a hand can produce.
    private static let boundaryEpsilon: CGFloat = 1e-6

    // MARK: - Stops

    /// Reveal stop a drag has reached, given where it began and which rung it
    /// is on now.
    ///
    /// Takes `currentStop` as well as the origin because a dead band is a
    /// property of the rung the ribbon occupies, not of the travel alone. A
    /// function of travel by itself has one boundary per rung, and a pointer
    /// resting on one crosses it back and forth with a fraction of a point of
    /// noise, however that boundary is positioned.
    ///
    /// Each rung instead holds from `detentHysteresis` of a detent before its
    /// nominal position to the same distance past it. Leaving the rung the
    /// drag just entered therefore needs real travel, and returning to it
    /// needs a little less, which is what a detent feels like in the hand.
    ///
    /// The ribbon grows leftward from the trailing edge, so widening travel is
    /// negative pointer translation. This is the only place that sign is
    /// applied. The result clamps to the offered range rather than running
    /// past it, so pulling beyond either end moves nothing at all.
    static func detentStop(
        originStop: Int,
        currentStop: Int,
        translation: CGFloat,
        widestStop: Int
    ) -> Int {
        let highest = max(0, widestStop)
        guard detentTravel > 0, translation.isFinite else {
            return min(max(currentStop, 0), highest)
        }
        let widening = -translation
        var offset = currentStop - originStop
        // The two loops cannot both run, because `detentHysteresis` exceeds
        // one half: a rung entered from either side sits strictly inside the
        // band it would have to leave.
        while widening >= (CGFloat(offset) + detentHysteresis) * detentTravel
            - boundaryEpsilon {
            offset += 1
        }
        while widening <= (CGFloat(offset) - detentHysteresis) * detentTravel
            + boundaryEpsilon {
            offset -= 1
        }
        return min(max(originStop + offset, 0), highest)
    }

    /// Rung a release lands on: where the drag left the ribbon, carried one
    /// further when the pointer was still moving fast enough to read as a
    /// flick.
    ///
    /// `pointerVelocity` is the raw pointer velocity in points per second,
    /// positive rightward; widening is negative, so the sign flips here.
    static func releaseStop(
        detentStop: Int,
        pointerVelocity: CGFloat,
        widestStop: Int
    ) -> Int {
        let highest = max(0, widestStop)
        guard abs(pointerVelocity) >= flingVelocity else {
            return min(max(detentStop, 0), highest)
        }
        let carried = pointerVelocity < 0 ? detentStop + 1 : detentStop - 1
        return min(max(carried, 0), highest)
    }
}
