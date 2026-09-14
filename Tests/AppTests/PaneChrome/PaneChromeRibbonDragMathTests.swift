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
///   4. A flick carries exactly one rung further, and not past the end.
///   5. Every function answers for a degenerate ribbon, where the widest stop
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

    // MARK: - detentStop

    @Test
    func aLeftwardDragWidensTheRibbon() {
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 5,
                currentStop: 5,
                translation: -clearsOneDetent,
                widestStop: phoneWidestStop
            ) == 6
        )
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 5,
                currentStop: 5,
                translation: clearsOneDetent,
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
                translation: 0,
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
                translation: -(clearsOneDetent - 0.5),
                widestStop: phoneWidestStop
            ) == 3
        )
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 3,
                currentStop: 3,
                translation: -clearsOneDetent,
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
            translation: -clearsOneDetent,
            widestStop: phoneWidestStop
        )
        #expect(entered == 4)
        for jitter in stride(from: CGFloat(0), through: 5, by: 0.25) {
            #expect(
                PaneChromeRibbonDragMath.detentStop(
                    originStop: 3,
                    currentStop: entered,
                    translation: -(clearsOneDetent - jitter),
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
                translation: -(nearEdge + 0.5),
                widestStop: phoneWidestStop
            ) == 4
        )
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 3,
                currentStop: 4,
                translation: -nearEdge,
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
                    translation: -(nominal + offset),
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
                translation: -travel,
                widestStop: phoneWidestStop
            ) == steps
        )
        // A hair short of that travel stays on the previous rung.
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 0,
                currentStop: 0,
                translation: -(travel - 0.5),
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
                translation: -clearsOneDetent,
                widestStop: phoneWidestStop
            ) == 1
        )
        #expect(
            PaneChromeRibbonDragMath.detentStop(
                originStop: 7,
                currentStop: 7,
                translation: -clearsOneDetent,
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
                translation: -10_000,
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
                translation: 10_000,
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
                translation: -10_000,
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

    @Test
    func aFlickCarriesOneRungFurther() {
        // Leftward flick (negative pointer velocity) widens.
        #expect(
            PaneChromeRibbonDragMath.releaseStop(
                detentStop: 5,
                pointerVelocity: -900,
                widestStop: phoneWidestStop
            ) == 6
        )
    }

    @Test
    func aRightwardFlickNarrows() {
        #expect(
            PaneChromeRibbonDragMath.releaseStop(
                detentStop: 5,
                pointerVelocity: 900,
                widestStop: phoneWidestStop
            ) == 4
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
                translation: -10_000,
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
                translation: 0,
                widestStop: -2
            ) == 0
        )
    }
}
