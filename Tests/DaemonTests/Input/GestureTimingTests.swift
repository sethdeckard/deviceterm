// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// Pin the math because every gesture path uses it.

@Test
func gestureTimingClampsNegativeDurationToZero() {
    let timing = GestureTiming(durationMs: -100, maxMs: 60_000)
    #expect(timing.totalMs == 0)
    // Steps floor at 1 so a zero-duration gesture still emits one frame.
    #expect(timing.steps == 1)
}

@Test
func gestureTimingClampsAboveMax() {
    let timing = GestureTiming(durationMs: 999_999, maxMs: 60_000)
    #expect(timing.totalMs == 60_000)
    #expect(timing.steps == 60_000 / GestureTiming.frameMs)
}

@Test
func gestureTimingTypicalSwipe() {
    let timing = GestureTiming(durationMs: 250, maxMs: 60_000)
    // 250ms / 16ms ≈ 15 frames.
    #expect(timing.totalMs == 250)
    #expect(timing.steps == 15)
}

@Test
func gestureTimingShorterThanOneFrame() {
    // Sub-frame durations still get one step rather than zero.
    let timing = GestureTiming(durationMs: 8, maxMs: 60_000)
    #expect(timing.steps == 1)
}

// The absolute schedule. Steps are 1-based to match the gesture loops, and the
// last one lands exactly on the total so a gesture ends where it was asked to.

@Test
func gestureScheduleSpacesStepsEvenlyAndEndsOnTheTotal() {
    let timing = GestureTiming(durationMs: 160, maxMs: 60_000)
    let anchor = ContinuousClock.now
    #expect(timing.deadline(forStep: 1, from: anchor) == anchor + .milliseconds(16))
    #expect(timing.deadline(forStep: 5, from: anchor) == anchor + .milliseconds(80))
    #expect(timing.deadline(forStep: timing.steps, from: anchor) == anchor + .milliseconds(160))
}

@Test
func stepDueReportsNothingBeforeTheFirstDeadline() {
    let timing = GestureTiming(durationMs: 160, maxMs: 60_000)
    let anchor = ContinuousClock.now
    #expect(timing.stepDue(at: anchor, from: anchor) == 0)
    // A wake one millisecond short of the first deadline has nothing due yet.
    #expect(timing.stepDue(at: anchor + .milliseconds(15), from: anchor) == 0)
    #expect(timing.stepDue(at: anchor + .milliseconds(16), from: anchor) == 1)
}

@Test
func stepDueClampsToTheFinalStep() {
    let timing = GestureTiming(durationMs: 160, maxMs: 60_000)
    let anchor = ContinuousClock.now
    #expect(timing.stepDue(at: anchor + .milliseconds(160), from: anchor) == timing.steps)
    // Running far past the end reports the last step rather than indexing off
    // the trajectory.
    #expect(timing.stepDue(at: anchor + .seconds(10), from: anchor) == timing.steps)
}

@Test
func stepDueAgreesWithTheDeadlineItInverts() {
    // An uneven schedule is where a plain inverse division breaks: 100ms over
    // six steps floors several deadlines, and undercounting one makes the loop
    // fire two samples back to back to catch up.
    let timing = GestureTiming(durationMs: 100, maxMs: 60_000)
    let anchor = ContinuousClock.now
    for elapsed in 0...timing.totalMs {
        let now = anchor + .milliseconds(elapsed)
        let expected = (0...timing.steps).last { timing.deadline(forStep: $0, from: anchor) <= now }
        #expect(timing.stepDue(at: now, from: anchor) == expected)
    }
}

@Test
func stepDueTreatsTimeBeforeTheAnchorAsNothingDue() {
    let timing = GestureTiming(durationMs: 160, maxMs: 60_000)
    let anchor = ContinuousClock.now
    #expect(timing.stepDue(at: anchor - .milliseconds(50), from: anchor) == 0)
}

@Test
func aZeroDurationGestureHasItsOnlyStepDueImmediately() {
    let timing = GestureTiming(durationMs: 0, maxMs: 60_000)
    let anchor = ContinuousClock.now
    #expect(timing.steps == 1)
    #expect(timing.deadline(forStep: 1, from: anchor) == anchor)
    #expect(timing.stepDue(at: anchor, from: anchor) == 1)
}
