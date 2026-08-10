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
    // stepDurationNs floors at 1ms-equivalent to keep Task.sleep
    // making forward progress.
    #expect(timing.stepDurationNs == 1_000_000)
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
    // stepDurationNs = (250 / 15) * 1e6 = 16ms ≈ one frame.
    #expect(timing.stepDurationNs == 16_000_000)
}

@Test
func gestureTimingShorterThanOneFrame() {
    // Sub-frame durations still get one step rather than zero.
    let timing = GestureTiming(durationMs: 8, maxMs: 60_000)
    #expect(timing.steps == 1)
    #expect(timing.stepDurationNs == 8_000_000)
}
