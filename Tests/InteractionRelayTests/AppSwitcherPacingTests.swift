// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import InteractionRelay

// The App Switcher trajectory's geometry.
//
// These cover the points the relay walks, not the loop that sends them: driving
// `runAppSwitcher` needs a live `DeviceChannel`, a socket-backed actor with no
// seam to fake, so the anchor, the absolute sleeps, and the sends themselves go
// uncovered here.

@Test
func theTrajectoryHoldsAtTheGrabRampsAndHoldsAtTheDwell() {
    let grab: (x: UInt16, y: UInt16) = (0, 0)
    let dwell: (x: UInt16, y: UInt16) = (0, 100)
    let points = AppSwitcherTrajectory.points(
        grab: grab,
        dwell: dwell,
        grabFrames: 3,
        rampFrames: 8,
        holdFrames: 4
    )
    #expect(points.count == 15)
    #expect(points.prefix(3).allSatisfy { $0.y == 0 })
    // The ramp ends on the dwell point, so the hold that follows is stationary.
    #expect(points[10].y == 100)
    #expect(points.suffix(4).allSatisfy { $0.y == 100 })
}

@Test
func theTrajectoryRampsMonotonicallyTowardTheDwellPoint() {
    let points = AppSwitcherTrajectory.points(
        grab: (0, 0),
        dwell: (0, 100),
        grabFrames: 0,
        rampFrames: 8,
        holdFrames: 0
    )
    #expect(points.count == 8)
    #expect(points.map(\.y) == points.map(\.y).sorted())
    #expect(points.last?.y == 100)
}

@Test
func degenerateFrameCountsStillProduceAReachableTrajectory() {
    // Zero grab and hold frames leave the ramp, which floors at one frame, so
    // the trajectory always has a point to send and ends on the dwell.
    let points = AppSwitcherTrajectory.points(
        grab: (0, 0),
        dwell: (0, 100),
        grabFrames: 0,
        rampFrames: 0,
        holdFrames: 0
    )
    #expect(points.count == 1)
    #expect(points[0].y == 100)
}
