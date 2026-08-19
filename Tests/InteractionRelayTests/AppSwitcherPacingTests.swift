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

// MARK: - Cancellation

@Test
func aCancellationTokenIsObservedFromWhereverItIsSet() {
    let cancellation = InteractionCancellation()
    #expect(!cancellation.isCancelled)
    cancellation.cancel()
    #expect(cancellation.isCancelled)
    // Idempotent: transfer and teardown can both signal the same request.
    cancellation.cancel()
    #expect(cancellation.isCancelled)
}

@Test
func aCancellationRidesTheTouchInputWithoutChangingItsIdentity() {
    let point = DevicePoint(x: 0.5, y: 0.5)
    let plain = TouchInput(point: point, phase: .contact, kind: .appSwitcher(.bottom))
    let tokened = TouchInput(
        point: point,
        phase: .contact,
        kind: .appSwitcher(.bottom),
        cancellation: InteractionCancellation()
    )
    // Cancellation is control-plane state and does not affect touch-value
    // equality: two inputs describing the same touch compare equal whichever
    // token they carry.
    #expect(plain == tokened)
    #expect(plain.cancellation == nil)
    #expect(tokened.cancellation != nil)
}
