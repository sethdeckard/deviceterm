// SPDX-License-Identifier: GPL-3.0-or-later
//
// GestureTiming: frame-pacing math for interpolated `pane.input.*`
// gestures (`swipe`, `pinch`, and anything multi-finger that comes
// later).
//
// Indigo's digitizer accepts a stream of `tapDown`/`twoFingerDown`
// events at successive points; treating those as continued contact
// is what makes a swipe look like a swipe rather than a sequence of
// taps. At ~60Hz (16ms frames) that means the daemon has to pace its
// own send loop. This struct does the arithmetic once so the gesture
// methods aren't four lines of clamp-and-divide each.
//
// The math: clamp the caller's `durationMs` to `[0, maxMs]` (`maxMs`
// is `PaneCoordinator.maxGestureDurationMs` in practice, passed in
// to keep this file independent of the coordinator). Divide into
// 16ms frames (or one frame minimum for a zero-duration gesture).
// Compute the per-step nanosecond budget; floor at 1ms-equivalent so
// `Task.sleep` always makes forward progress. The ms→ns multiply is
// safe by construction because `totalMs ≤ maxMs ≤ 60_000`.

import Foundation

struct GestureTiming {
    /// Approximate display frame duration in ms. 16ms ≈ 60Hz, which
    /// matches Indigo's digitizer cadence on the host.
    static let frameMs: Int = 16

    /// Clamped duration actually used for pacing: `min(max(durationMs, 0), maxMs)`.
    let totalMs: Int

    /// Number of pacing steps. Always ≥ 1 so a zero-duration gesture
    /// still emits one intermediate event.
    let steps: Int

    /// Per-step `Task.sleep(nanoseconds:)` budget. Floor of 1ms to
    /// guarantee forward progress even with degenerate inputs.
    let stepDurationNs: UInt64

    init(durationMs: Int, maxMs: Int) {
        let clamped = min(max(durationMs, 0), maxMs)
        let stepCount = max(1, clamped / Self.frameMs)
        self.totalMs = clamped
        self.steps = stepCount
        self.stepDurationNs = UInt64(max(clamped / stepCount, 1)) * 1_000_000
    }
}
