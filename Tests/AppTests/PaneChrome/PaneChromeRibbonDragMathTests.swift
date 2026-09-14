// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

/// The detent mapping behind a chevron drag. Claims worth holding:
///
///   1. A leftward drag widens the ribbon. The ribbon grows from the trailing
///      edge, so the pointer sign is inverted exactly once. Get it backwards
///      and the handle works in reverse, which no other test would catch.
///   2. Each rung holds a dead band around itself, so the travel that leaves a
///      rung is not the travel that returns to it. A single threshold, however
///      placed, is crossed back and forth by a fraction of a point of pointer
///      noise; only a band with two edges stops that.
///   3. The ends are a wall. No amount of further travel moves the ribbon
///      past either one, which is what keeps an overshoot from eating the gap
///      the device name holds.
///   4. A release carries one rung per `flingVelocity` of remaining speed, and
///      never past an end stop.
///   5. Speed gearing is clamped at both ends and a straight ramp between them,
///      so equal raw movement at the same speed contributes equal weighted
///      travel.
///   6. Every function answers for a degenerate ribbon, where the widest stop
///      is 0 and there is nowhere to drag to.
@MainActor
struct PaneChromeRibbonDragMathTests {
    /// Widest stop for the 10-action phone row: one rung per action, plus the
    /// size-preset menu's own rung.
    private let phoneWidestStop = PaneChromeRibbonFit.widestStop(actionCount: 10)

    /// Pointer travel at the inclusive first-detent boundary.
    private var clearsOneDetent: CGFloat {
        PaneChromeRibbonDragMath.detentTravel
            * PaneChromeRibbonDragMath.detentHysteresis
    }

    /// The projection math divides, so the arming expectations compare within a
    /// tolerance rather than exactly.
    private func approxEqual(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        tolerance: CGFloat = 0.0001
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    // MARK: - detentStop

    @Test
    func aLeftwardDragWidensTheRibbon() {
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 5,
                currentStop: 5,
                weightedTranslation: -clearsOneDetent,
                widestStop: phoneWidestStop
            ) == 6
        )
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 5,
                currentStop: 5,
                weightedTranslation: clearsOneDetent,
                widestStop: phoneWidestStop
            ) == 4
        )
    }

    @Test
    func aPressThatHasNotMovedHoldsItsRung() {
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 3,
                currentStop: 3,
                weightedTranslation: 0,
                widestStop: phoneWidestStop
            ) == 3
        )
    }

    @Test
    func leavingARungNeedsMostOfADetent() {
        // Just short of the threshold holds; at it, the ribbon steps.
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 3,
                currentStop: 3,
                weightedTranslation: -(clearsOneDetent - 0.5),
                widestStop: phoneWidestStop
            ) == 3
        )
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 3,
                currentStop: 3,
                weightedTranslation: -clearsOneDetent,
                widestStop: phoneWidestStop
            ) == 4
        )
        #expect(PaneChromeRibbonDragMath.detentHysteresis > 0.5)
    }

    @Test
    func aRungHoldsAgainstPointerNoise() {
        // The claim a single travel threshold cannot make. Having just stepped
        // onto rung 4 at `clearsOneDetent`, drifting a fraction of a point
        // back must not drop straight to rung 3: the rung the drag entered
        // holds until the pointer has retreated well inside it. Without a dead
        // band this is where a resting hand flutters between two stops.
        let entered = PaneChromeRibbonDragMath.detentStop(
            originStop: 3,
            currentStop: 3,
            weightedTranslation: -clearsOneDetent,
            widestStop: phoneWidestStop
        )
        #expect(entered == 4)
        for jitter in stride(from: CGFloat(0), through: 5, by: 0.25) {
            #expect(
                PaneChromeRibbonDragMath.detentStop(
                    originStop: 3,
                    currentStop: entered,
                    weightedTranslation: -(clearsOneDetent - jitter),
                    widestStop: phoneWidestStop
                ) == 4,
                "rung dropped after \(jitter)pt of backtrack"
            )
        }
    }

    @Test
    func retreatingFarEnoughStillLeavesTheRung() {
        // The band is not a trap: pull back past the rung's near edge and it
        // gives up the rung. That edge sits `detentHysteresis` of a detent
        // below the rung's nominal position.
        let nearEdge = PaneChromeRibbonDragMath.detentTravel
            * (1 - PaneChromeRibbonDragMath.detentHysteresis)
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 3,
                currentStop: 4,
                weightedTranslation: -(nearEdge + 0.5),
                widestStop: phoneWidestStop
            ) == 4
        )
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 3,
                currentStop: 4,
                weightedTranslation: -nearEdge,
                widestStop: phoneWidestStop
            ) == 3
        )
    }

    @Test
    func theDeadBandIsCenteredOnEachRung() {
        // Entry and exit sit the same distance either side of a rung's
        // nominal travel, so a rung feels the same to leave in either
        // direction once you are on it.
        let band = PaneChromeRibbonDragMath.detentTravel
            * PaneChromeRibbonDragMath.detentHysteresis
        let nominal = PaneChromeRibbonDragMath.detentTravel
        // Sitting exactly on rung 1's nominal travel, neither edge is reached.
        for offset in stride(from: -band + 0.5, through: band - 0.5, by: 1) {
            #expect(
                PaneChromeRibbonDragMath.detentStop(
                    originStop: 0,
                    currentStop: 1,
                    weightedTranslation: -(nominal + offset),
                    widestStop: phoneWidestStop
                ) == 1,
                "left rung 1 at offset \(offset)"
            )
        }
    }

    @Test("each further rung costs a full detent", arguments: 1...6)
    func laterRungsCostAFullDetent(steps: Int) {
        let travel = clearsOneDetent
            + PaneChromeRibbonDragMath.detentTravel * CGFloat(steps - 1)
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 0,
                currentStop: 0,
                weightedTranslation: -travel,
                widestStop: phoneWidestStop
            ) == steps
        )
        // A hair short of that travel stays on the previous rung.
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 0,
                currentStop: 0,
                weightedTranslation: -(travel - 0.5),
                widestStop: phoneWidestStop
            ) == steps - 1
        )
    }

    @Test
    func theDetentSpacingIsUniform() {
        // Deliberately not paced by the rungs' own widths, which are uneven:
        // the step onto the size-preset menu is a few points where every step
        // after it is a button plus a gap. Pacing by those would make the
        // first detent nearly free.
        let first = PaneChromeRibbonFit.contentWidth(stop: 1)
            - PaneChromeRibbonFit.contentWidth(stop: 0)
        let later = PaneChromeRibbonFit.contentWidth(stop: 3)
            - PaneChromeRibbonFit.contentWidth(stop: 2)
        #expect(first != later)
        // Same travel moves one rung at either end of the ladder regardless.
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 0,
                currentStop: 0,
                weightedTranslation: -clearsOneDetent,
                widestStop: phoneWidestStop
            ) == 1
        )
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 7,
                currentStop: 7,
                weightedTranslation: -clearsOneDetent,
                widestStop: phoneWidestStop
            ) == 8
        )
    }

    // MARK: - The ends are a wall

    @Test
    func draggingPastTheWidestRungMovesNothing() {
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: phoneWidestStop,
                currentStop: phoneWidestStop,
                weightedTranslation: -10_000,
                widestStop: phoneWidestStop
            ) == phoneWidestStop
        )
    }

    @Test
    func draggingPastTheNarrowestRungMovesNothing() {
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 0,
                currentStop: 0,
                weightedTranslation: 10_000,
                widestStop: phoneWidestStop
            ) == 0
        )
    }

    @Test
    func theWallIsTheFitCapNotTheOfferedRow() {
        // The caller passes the pane's reachable stop, so a narrow pane stops
        // the drag early rather than letting it cover the device name.
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 0,
                currentStop: 0,
                weightedTranslation: -10_000,
                widestStop: 4
            ) == 4
        )
    }

    // MARK: - releaseStop

    @Test
    func aSlowReleaseStaysWhereTheDragLeftIt() {
        #expect(
            PaneChromeRibbonDragMath.releaseStop(
                detentStop: 5,
                pointerVelocity: 0,
                widestStop: phoneWidestStop
            ) == 5
        )
    }

    @Test("a release carries one rung per fling unit", arguments: [
        (300, 1), (700, 2), (1_200, 4), (2_000, 6)
    ])
    func aReleaseCarriesByMomentum(speed: CGFloat, rungs: Int) {
        // Leftward release (negative pointer velocity) widens.
        #expect(
            PaneChromeRibbonDragMath.releaseStop(
                detentStop: 3,
                pointerVelocity: -speed,
                widestStop: 40
            ) == 3 + rungs
        )
    }

    @Test
    func aRightwardReleaseCarriesTheOtherWay() {
        #expect(
            PaneChromeRibbonDragMath.releaseStop(
                detentStop: 9,
                pointerVelocity: 900,
                widestStop: phoneWidestStop
            ) == 6
        )
    }

    @Test
    func aFlickBelowTheThresholdDoesNotCarry() {
        #expect(
            PaneChromeRibbonDragMath.releaseStop(
                detentStop: 5,
                pointerVelocity: -(PaneChromeRibbonDragMath.flingVelocity - 1),
                widestStop: phoneWidestStop
            ) == 5
        )
        // At the threshold it does carry: the comparison is inclusive.
        #expect(
            PaneChromeRibbonDragMath.releaseStop(
                detentStop: 5,
                pointerVelocity: -PaneChromeRibbonDragMath.flingVelocity,
                widestStop: phoneWidestStop
            ) == 6
        )
    }

    @Test
    func aFlickAtAnEndRungDoesNotCarryPastIt() {
        #expect(
            PaneChromeRibbonDragMath.releaseStop(
                detentStop: phoneWidestStop,
                pointerVelocity: -5_000,
                widestStop: phoneWidestStop
            ) == phoneWidestStop
        )
        #expect(
            PaneChromeRibbonDragMath.releaseStop(
                detentStop: 0,
                pointerVelocity: 5_000,
                widestStop: phoneWidestStop
            ) == 0
        )
    }

    // MARK: - Speed gearing

    @Test
    func slowMovementCountsAtFaceValue() {
        // Below the slow threshold the control is ungeared, so a careful hand
        // gets the full detent travel to place a rung with.
        #expect(PaneChromeRibbonDragMath.speedGain(pointerSpeed: 0) == 1)
        #expect(
            PaneChromeRibbonDragMath.speedGain(
                pointerSpeed: PaneChromeRibbonDragMath.slowPointerSpeed
            ) == 1
        )
    }

    @Test
    func fastMovementSaturatesAtTheMaximumGain() {
        // Clamped above, so a velocity spike cannot gear the control past what
        // a merely fast drag already reaches.
        #expect(
            PaneChromeRibbonDragMath.speedGain(
                pointerSpeed: PaneChromeRibbonDragMath.fastPointerSpeed
            ) == PaneChromeRibbonDragMath.maxSpeedGain
        )
        #expect(
            PaneChromeRibbonDragMath.speedGain(pointerSpeed: 50_000)
                == PaneChromeRibbonDragMath.maxSpeedGain
        )
    }

    @Test
    func theGainRampsMonotonicallyBetweenTheThresholds() {
        var previous: CGFloat = 0
        for speed in stride(
            from: PaneChromeRibbonDragMath.slowPointerSpeed,
            through: PaneChromeRibbonDragMath.fastPointerSpeed,
            by: 50
        ) {
            let gain = PaneChromeRibbonDragMath.speedGain(pointerSpeed: speed)
            #expect(gain >= previous, "gain fell back at \(speed)")
            #expect(gain >= 1)
            #expect(gain <= PaneChromeRibbonDragMath.maxSpeedGain)
            previous = gain
        }
    }

    @Test
    func theGainReadsSpeedAsAMagnitude() {
        // The caller passes a magnitude, and a signed value must not fold back
        // to the ungeared end of the ramp.
        let fast = PaneChromeRibbonDragMath.fastPointerSpeed
        #expect(
            PaneChromeRibbonDragMath.speedGain(pointerSpeed: -fast)
                == PaneChromeRibbonDragMath.speedGain(pointerSpeed: fast)
        )
    }

    @Test
    func aWeightedDeltaKeepsItsSignAndScalesWithSpeed() {
        let slow = PaneChromeRibbonDragMath.weightedDelta(
            rawDelta: -10,
            pointerSpeed: 0
        )
        let fast = PaneChromeRibbonDragMath.weightedDelta(
            rawDelta: -10,
            pointerSpeed: PaneChromeRibbonDragMath.fastPointerSpeed
        )
        #expect(slow == -10)
        #expect(fast < slow)
        #expect(fast == -10 * PaneChromeRibbonDragMath.maxSpeedGain)
    }

    @Test
    func aFastDragReachesAFurtherRungThanASlowOne() {
        // The point of the gearing: the same raw distance covers more ladder
        // when the pointer was moving fast.
        let raw: CGFloat = -120
        let slowTravel = PaneChromeRibbonDragMath.weightedDelta(
            rawDelta: raw,
            pointerSpeed: 0
        )
        let fastTravel = PaneChromeRibbonDragMath.weightedDelta(
            rawDelta: raw,
            pointerSpeed: PaneChromeRibbonDragMath.fastPointerSpeed
        )
        let slowStop = PaneChromeRibbonDragMath.detentStop(
            originStop: 0,
            currentStop: 0,
            weightedTranslation: slowTravel,
            widestStop: 40
        )
        let fastStop = PaneChromeRibbonDragMath.detentStop(
            originStop: 0,
            currentStop: 0,
            weightedTranslation: fastTravel,
            widestStop: 40
        )
        #expect(fastStop > slowStop)
    }

    @Test
    func aNonFiniteSpeedLeavesTheGearingAlone() {
        #expect(PaneChromeRibbonDragMath.speedGain(pointerSpeed: .nan) == 1)
        #expect(PaneChromeRibbonDragMath.speedGain(pointerSpeed: .infinity) == 1)
        #expect(PaneChromeRibbonDragMath.weightedDelta(rawDelta: .nan, pointerSpeed: 0) == 0)
    }

    // MARK: - Arming

    @Test
    func armingSpendsTheActivationDistanceAlongTheDrag() {
        let activation = PaneChromeRibbonFit.dragActivationDistance
        // A level drag spends the whole activation distance horizontally,
        // however far past the threshold the update reports.
        #expect(
            approxEqual(
                PaneChromeRibbonDragMath.armingTranslation(
                    translation: CGSize(width: -40, height: 0)
                ),
                -activation
            )
        )
        // A diagonal drag spends only the horizontal share of it, because the
        // threshold is radial.
        #expect(
            approxEqual(
                PaneChromeRibbonDragMath.armingTranslation(
                    translation: CGSize(width: -40, height: -40)
                ),
                -activation / CGFloat(2).squareRoot()
            )
        )
        // A near-vertical drag has barely crossed horizontally at all, so
        // almost nothing is spent.
        let steep = PaneChromeRibbonDragMath.armingTranslation(
            translation: CGSize(width: -2, height: -40)
        )
        #expect(steep < 0)
        #expect(abs(steep) < 0.3)
    }

    @Test
    func armingNeverSpendsMoreThanTheDragCovered() {
        // Short of the threshold the whole update is spent, so it contributes
        // no travel at all.
        #expect(
            PaneChromeRibbonDragMath.armingTranslation(
                translation: CGSize(width: -2, height: 0)
            ) == -2
        )
        #expect(
            PaneChromeRibbonDragMath.armingTranslation(
                translation: .zero
            ) == 0
        )
        #expect(
            PaneChromeRibbonDragMath.armingTranslation(
                translation: CGSize(width: CGFloat.nan, height: 0)
            ) == 0
        )
        #expect(
            PaneChromeRibbonDragMath.armingTranslation(
                translation: CGSize(width: -40, height: CGFloat.nan)
            ) == 0
        )
    }

    @Test("every sample along one straight drag projects alike", arguments: [
        CGSize(width: -1, height: 0),
        CGSize(width: -1, height: -1),
        CGSize(width: -1, height: -8),
        CGSize(width: 3, height: -2)
    ])
    func armingIsIndependentOfWhereTheUpdateLanded(direction: CGSize) {
        // The property the projection exists for. Pointer updates coalesce
        // unpredictably, so which sample along a drag happens to be the arming
        // one must not change how much travel it spends.
        let unit = (direction.width * direction.width
            + direction.height * direction.height).squareRoot()
        let reference = PaneChromeRibbonDragMath.armingTranslation(
            translation: CGSize(
                width: direction.width / unit * 10,
                height: direction.height / unit * 10
            )
        )
        for scale in stride(from: CGFloat(5), through: 400, by: 5) {
            let sample = CGSize(
                width: direction.width / unit * scale,
                height: direction.height / unit * scale
            )
            #expect(
                approxEqual(
                    PaneChromeRibbonDragMath.armingTranslation(translation: sample),
                    reference
                ),
                "diverged at \(scale)pt along the ray"
            )
        }
    }

    @Test
    func callbackCadenceDoesNotChangeAccumulatedTravel() {
        // The same consequence one level up: a straight drag accumulates the
        // same horizontal travel whether it arrives in one update or many.
        // Speed gearing is held at face value here to isolate the arming
        // arithmetic.
        func accumulate(_ samples: [CGSize]) -> CGFloat {
            guard let first = samples.first else { return 0 }
            var last = PaneChromeRibbonDragMath.armingTranslation(translation: first)
            var travel: CGFloat = 0
            for sample in samples {
                travel += PaneChromeRibbonDragMath.weightedDelta(
                    rawDelta: sample.width - last,
                    pointerSpeed: 0
                )
                last = sample.width
            }
            return travel
        }
        // A level drag, a diagonal one, and a near-vertical one.
        for slope in [CGFloat(0), 1, 20] {
            let coarse = accumulate([CGSize(width: -120, height: -120 * slope)])
            let fine = accumulate([-6, -20, -55, -90, -120].map {
                CGSize(width: $0, height: $0 * slope)
            })
            let finer = accumulate(
                Array(stride(from: CGFloat(-5), through: -120, by: -5)).map {
                    CGSize(width: $0, height: $0 * slope)
                }
            )
            #expect(approxEqual(coarse, fine), "coarse vs fine at slope \(slope)")
            #expect(approxEqual(coarse, finer), "coarse vs finer at slope \(slope)")
        }
    }

    // MARK: - Degenerate ribbon

    @Test
    func aRibbonWithNowhereToGoAnswersSafely() {
        // `widestStop` is never below 1 for a real pane, since the size-preset
        // menu always has a rung. Pinned anyway, because both functions clamp
        // against it and a zero would otherwise invert the range.
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 0,
                currentStop: 0,
                weightedTranslation: -10_000,
                widestStop: 0
            ) == 0
        )
        #expect(
            PaneChromeRibbonDragMath.releaseStop(
                detentStop: 0,
                pointerVelocity: -5_000,
                widestStop: 0
            ) == 0
        )
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 3,
                currentStop: 3,
                weightedTranslation: 0,
                widestStop: -2
            ) == 0
        )
    }
}
