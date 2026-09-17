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
/// Travel is measured in detents of equal size rather than in the rungs' own
/// widths, which are uneven: the step onto the size-preset menu is a few
/// points where every step after it is a button plus a gap. Pacing the drag
/// by those widths would make the first detent almost free and the rest
/// deliberate.
///
/// What varies instead is how much a point of pointer movement counts for.
/// Moving slowly spends travel at face value, which keeps a careful drag
/// precise; moving fast multiplies it up to `maxSpeedGain`, so covering the
/// whole ladder does not take the full `detentTravel` per rung. The trade is
/// that the stop depends on how the pointer got somewhere and not only on
/// where it ended: a fast drag out and a slow drag back over the same
/// distance do not cancel. Callers therefore accumulate weighted travel
/// across the gesture rather than handing this a total translation.
///
/// There is no overshoot past either end. The ends are a wall, which both
/// reads as solid and keeps the ribbon from ever reaching a rung wider than
/// the row can hold.
enum PaneChromeRibbonDragMath {
    // MARK: - Feel constants

    /// Weighted travel one detent costs, the width of a button and its gap.
    /// Borrowed rather than chosen: a rung's worth of movement to advance a
    /// rung is the gearing a user already expects from the row itself. At
    /// `slowPointerSpeed` and below, weighted travel equals raw pointer
    /// movement, so this is also what a rung costs a careful hand.
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

    /// Pointer speed at release, in points per second, that carries one rung
    /// further, and the step between each further rung a faster release
    /// carries. A drag steered onto a rung decelerates well below this; a
    /// flick clears it easily.
    static let flingVelocity: CGFloat = 300

    /// Pointer speed, in points per second, at or below which movement counts
    /// at face value. Below this the control is deliberately ungeared, so a
    /// hand placing the ribbon on a particular rung gets the full
    /// `detentTravel` to do it in.
    static let slowPointerSpeed: CGFloat = 200

    /// Pointer speed, in points per second, at or above which movement counts
    /// for `maxSpeedGain`. Past here the gearing stops climbing, so a very
    /// fast flick is no harder to aim than a merely fast one.
    static let fastPointerSpeed: CGFloat = 1_600

    /// Most a point of pointer movement can count for. Three puts a rung at
    /// roughly a third of `detentTravel` at full speed, which covers the whole
    /// ladder in about one comfortable sweep.
    static let maxSpeedGain: CGFloat = 3

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

    // MARK: - Speed gearing

    /// How much a point of pointer movement counts for at `pointerSpeed`.
    ///
    /// One at `slowPointerSpeed` and below, `maxSpeedGain` at
    /// `fastPointerSpeed` and above, and a straight ramp between the two. A
    /// ramp rather than a curve because a user has to be able to predict it
    /// from two drags, and clamped at both ends so neither a stationary hand
    /// nor an implausible velocity spike changes the gearing.
    ///
    /// `pointerSpeed` is a magnitude; sign is the caller's business.
    static func speedGain(pointerSpeed: CGFloat) -> CGFloat {
        guard pointerSpeed.isFinite else { return 1 }
        let span = fastPointerSpeed - slowPointerSpeed
        guard span > 0 else { return pointerSpeed > slowPointerSpeed ? maxSpeedGain : 1 }
        let ramp = (abs(pointerSpeed) - slowPointerSpeed) / span
        return 1 + (maxSpeedGain - 1) * min(max(ramp, 0), 1)
    }

    /// Horizontal translation an arming update should count from, so the
    /// gesture consumes the activation distance and nothing beyond it.
    ///
    /// The update that clears `PaneChromeRibbonFit.dragActivationDistance` can
    /// report a translation far larger than the threshold, since pointer
    /// updates coalesce and a fast drag covers ground between them. Counting
    /// that whole update as spent would make the same physical drag land on
    /// different rungs depending on how the updates happened to arrive.
    ///
    /// Arming measures the radial distance, so the amount of *horizontal*
    /// travel that distance represents depends on the direction of the drag:
    /// all of it for a level drag, almost none of it for a near-vertical one.
    /// Projecting onto the update's own direction is what recovers the
    /// horizontal position the threshold was actually crossed at. Every sample
    /// along one straight drag projects to the same value, which is what makes
    /// the result independent of how the updates arrived.
    static func armingTranslation(translation: CGSize) -> CGFloat {
        let width = translation.width
        guard width.isFinite, translation.height.isFinite else { return 0 }
        let distance = (width * width + translation.height * translation.height)
            .squareRoot()
        let consumed = PaneChromeRibbonFit.dragActivationDistance
        // Short of the threshold nothing has been earned yet, so the whole
        // update is spent and this update contributes no travel.
        guard distance > consumed, distance > 0 else { return width }
        return width * (consumed / distance)
    }

    /// Weighted contribution of one raw pointer delta, geared by the speed it
    /// was moving at.
    ///
    /// Keeps the delta's sign, so a caller sums these into a running weighted
    /// translation carrying the same sign convention as the raw one.
    static func weightedDelta(rawDelta: CGFloat, pointerSpeed: CGFloat) -> CGFloat {
        guard rawDelta.isFinite else { return 0 }
        return rawDelta * speedGain(pointerSpeed: pointerSpeed)
    }

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
    /// `weightedTranslation` is the gesture's accumulated
    /// `weightedDelta(rawDelta:pointerSpeed:)`, carrying the same sign as raw
    /// pointer translation. The ribbon grows leftward from the trailing edge,
    /// so widening travel is negative. This is the only place that sign is
    /// applied. The result clamps to the offered range rather than running
    /// past it, so pulling beyond either end moves nothing at all.
    static func detentStop(
        originStop: Int,
        currentStop: Int,
        weightedTranslation: CGFloat,
        widestStop: Int
    ) -> Int {
        let highest = max(0, widestStop)
        guard detentTravel > 0, weightedTranslation.isFinite else {
            return min(max(currentStop, 0), highest)
        }
        let widening = -weightedTranslation
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

    /// Rung a release lands on: where the drag left the ribbon, carried
    /// further in the direction of travel by whatever momentum the pointer
    /// still had.
    ///
    /// One rung per `flingVelocity` of release speed, so a flick coasts
    /// several rungs and a drag steered to a halt coasts none. The range clamp
    /// is the only cap, which is why an implausible velocity lands at an end
    /// stop rather than needing its own ceiling.
    ///
    /// `pointerVelocity` is the raw pointer velocity in points per second,
    /// positive rightward; widening is negative, so the sign flips here.
    static func releaseStop(
        detentStop: Int,
        pointerVelocity: CGFloat,
        widestStop: Int
    ) -> Int {
        let highest = max(0, widestStop)
        let landed = min(max(detentStop, 0), highest)
        guard pointerVelocity.isFinite, flingVelocity > 0 else { return landed }
        let rungs = Int((abs(pointerVelocity) / flingVelocity).rounded(.down))
        guard rungs > 0 else { return landed }
        let carried = pointerVelocity < 0 ? landed + rungs : landed - rungs
        return min(max(carried, 0), highest)
    }
}
