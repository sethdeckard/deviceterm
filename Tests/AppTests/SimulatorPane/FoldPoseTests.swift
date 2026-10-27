// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

/// The posed fold: the symmetric crease as the equal-turns case, the closed device
/// landing where the fixed half lies, and which half stays put.
struct FoldPoseTests {
    @Test("equal turns bend exactly as the symmetric crease does", arguments: [30.0, 90.0, 150.0])
    func equalTurnsMatchTheCrease(degrees: Double) throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: degrees))
        for side in [-1.0, 1.0] {
            let outer = FoldPose.project(distance: 1, along: 1, side: side, turn: crease.turn)
            #expect(abs(outer.across - side * crease.outerAcross) < 1e-12)
            #expect(abs(outer.along - crease.outerAlong) < 1e-12)
        }
        let onCrease = FoldPose.project(distance: 0, along: 1, side: 1, turn: crease.turn)
        #expect(abs(onCrease.across) < 1e-12)
        #expect(abs(onCrease.along - 1) < 1e-12)
        #expect(abs(onCrease.divisor - 1) < 1e-12)
    }

    @Test("closed, the swinging half lies flat over the fixed half", arguments: [-1.0, 1.0])
    func closedLandsOnTheFixedHalf(fixedSide: Double) {
        for distance in [0.0, 0.5, 0.98] {
            let point = FoldPose.project(
                distance: distance,
                along: 0.7,
                side: -fixedSide,
                turn: FoldPose.closed.swingTurn
            )
            #expect(abs(point.across - fixedSide * distance) < 1e-12)
            #expect(abs(point.along - 0.7) < 1e-12)
            #expect(abs(point.divisor - 1) < 1e-12)
        }
    }

    @Test("the cover shows once the swinging half passes edge-on")
    func showsTheCoverPastAQuarterTurn() {
        #expect(!FoldPose(fixedTurn: 0, swingTurn: .pi / 2 - 0.01).showsCover)
        #expect(FoldPose(fixedTurn: 0, swingTurn: .pi / 2 + 0.01).showsCover)
    }

    @Test("the fixed half is on the right with the device upright")
    func fixedHalfMatchesTheMeasuredCase() {
        // Device portrait draws the inner picture landscapeRight.
        let drawn = FoldablePanelOrientation.display(forDevice: .portrait, onInnerPanel: true)
        #expect(FoldPose.fixedSide(innerDrawnIn: drawn) == 1)
    }

    @Test("turning the device half round puts the fixed half on the other side", arguments: [
        (Orientation.landscapeRight, Orientation.landscapeLeft),
        (.portrait, .portraitUpsideDown)
    ])
    func fixedHalfTurnsWithTheDevice(one: Orientation, other: Orientation) {
        #expect(FoldPose.fixedSide(innerDrawnIn: one) == -FoldPose.fixedSide(innerDrawnIn: other))
    }
}

/// The turnover's timeline, fitted to Device Hub.
struct FoldTurnoverTests {
    private let openTurn = 71.5 * Double.pi / 180

    @Test("the hinge decides the side shown while a fold is under way", arguments: [
        // (was closed, degrees, cover lit, shown closed)
        (true, 54.0, true, true),
        (true, 55.0, true, false),
        (false, 45.0, false, false),
        (false, 44.0, false, true),
        // Between the two, the side shown holds whichever panel is lit.
        (true, 50.0, false, true),
        (false, 50.0, true, false),
        // iOS lit the cover early; the device stays open until the hinge closes it.
        (false, 87.0, true, false)
    ])
    func theHingeTurnsTheDeviceOver(wasClosed: Bool, degrees: Double, coverLit: Bool, closed: Bool) {
        #expect(FoldTurnover.showsClosed(wasClosed: wasClosed, hinge: degrees, coverLit: coverLit) == closed)
    }

    @Test
    func withoutAHingeReadingTheLitPanelDecides() {
        #expect(FoldTurnover.showsClosed(wasClosed: false, hinge: nil, coverLit: true))
        #expect(!FoldTurnover.showsClosed(wasClosed: true, hinge: nil, coverLit: false))
        #expect(FoldTurnover.showsClosed(wasClosed: nil, hinge: 120, coverLit: true))
    }

    @Test
    func closingRunsFromTheOpenFoldToClosed() {
        let start = FoldTurnover.pose(direction: .closing, elapsed: 0, openTurn: openTurn)
        let end = FoldTurnover.pose(direction: .closing, elapsed: FoldTurnover.duration, openTurn: openTurn)
        #expect(start == FoldPose.open(turn: openTurn))
        #expect(abs(end.swingTurn - FoldPose.closed.swingTurn) < 1e-12)
        #expect(end.fixedTurn == 0)
    }

    @Test
    func openingRunsTheSameMotionBackwards() {
        for elapsed in stride(from: 0.0, through: FoldTurnover.duration, by: 0.05) {
            let opening = FoldTurnover.pose(direction: .opening, elapsed: elapsed, openTurn: openTurn)
            let closing = FoldTurnover.pose(
                direction: .closing,
                elapsed: FoldTurnover.duration - elapsed,
                openTurn: openTurn
            )
            #expect(abs(opening.swingTurn - closing.swingTurn) < 1e-9)
            #expect(abs(opening.fixedTurn - closing.fixedTurn) < 1e-9)
        }
    }

    @Test
    func theSwingNeverStepsBackWhileClosing() {
        var previous = -Double.infinity
        for step in 0...100 {
            let pose = FoldTurnover.closingPose(progress: Double(step) / 100, openTurn: openTurn)
            #expect(pose.swingTurn >= previous - 1e-12)
            previous = pose.swingTurn
        }
    }

    @Test
    func theYawTurnsTheFoldAsOnePiece() {
        for step in 0...10 {
            let progress = FoldTurnover.yawShare * Double(step) / 10
            let pose = FoldTurnover.closingPose(progress: progress, openTurn: openTurn)
            #expect(abs(pose.fixedTurn + pose.swingTurn - 2 * openTurn) < 1e-12)
        }
    }

    @Test("the fit runs from the open fold's to the resting cover's", arguments: [0.8, 1.0])
    func theScaleMeetsTheSteadyDrawingAtBothEnds(openScale: Double) {
        let end = FoldTurnover.duration
        #expect(FoldTurnover.scale(openScale: openScale, direction: .closing, elapsed: 0) == openScale)
        #expect(FoldTurnover.scale(openScale: openScale, direction: .closing, elapsed: end) == 1)
        #expect(FoldTurnover.scale(openScale: openScale, direction: .opening, elapsed: 0) == 1)
        #expect(FoldTurnover.scale(openScale: openScale, direction: .opening, elapsed: end) == openScale)
    }

    @Test
    func finishesAtItsDuration() {
        #expect(!FoldTurnover.isFinished(elapsed: FoldTurnover.duration - 0.01))
        #expect(FoldTurnover.isFinished(elapsed: FoldTurnover.duration))
    }
}
