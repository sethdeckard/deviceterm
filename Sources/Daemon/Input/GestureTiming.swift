// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Frame-pacing and dwell math for the interpolated `pane.input.*`
/// gestures (`swipe`, `pinch`) and paced crown input.
///
/// Indigo's digitizer accepts a stream of `tapDown`/`twoFingerDown`
/// events at successive points; treating those as continued contact
/// is what makes a swipe look like a swipe rather than a sequence of
/// taps. At ~60Hz (16ms frames) that means the daemon has to pace its
/// own send loop. This struct does the arithmetic once so the gesture
/// methods aren't four lines of clamp-and-divide each.
///
/// The math: clamp the caller's `durationMs` to `[0, maxMs]` (`maxMs`
/// is `PaneCoordinator.maxGestureDurationMs` in practice, passed in
/// to keep this file independent of the coordinator). Divide into
/// 16ms frames (or one frame minimum for a zero-duration gesture).
/// A loop then sleeps to each step's absolute deadline rather than for
/// a per-step interval, so one step's lateness doesn't shift the rest.
struct GestureTiming {
    /// Approximate display frame duration in ms. 16ms ≈ 60Hz, which
    /// matches Indigo's digitizer cadence on the host.
    static let frameMs: Int = 16

    /// Clamped duration actually used for pacing: `min(max(durationMs, 0), maxMs)`.
    let totalMs: Int

    /// Number of pacing steps. Always ≥ 1 so a zero-duration gesture
    /// still emits one intermediate event.
    let steps: Int

    init(durationMs: Int, maxMs: Int) {
        let clamped = min(max(durationMs, 0), maxMs)
        self.totalMs = clamped
        self.steps = max(1, clamped / Self.frameMs)
    }

    /// Whole milliseconds in `duration`, truncated toward zero.
    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }

    /// Re-report frames covering `holdMs` at `intervalMs`.
    ///
    /// Rounds up, so a hold is never cut short: flooring would lift a 50ms hold
    /// after one 33ms frame. At least one frame, so any positive hold reports
    /// contact at least once.
    static func dwellFrames(holdMs: Int, intervalMs: Int) -> Int {
        guard intervalMs > 0 else { return 1 }
        return max(1, (holdMs + intervalMs - 1) / intervalMs)
    }

    /// When dwell `frame` is due, measured from `anchor`.
    ///
    /// Frames are 1-based and spaced `intervalMs` apart, except the last, which
    /// lands on the hold's end rather than past it. Rounding up the frame count
    /// would otherwise overshoot the requested hold by up to one interval.
    static func dwellDeadline(
        forFrame frame: Int,
        holdMs: Int,
        intervalMs: Int,
        from anchor: ContinuousClock.Instant
    ) -> ContinuousClock.Instant {
        anchor + .milliseconds(min(intervalMs * frame, holdMs))
    }

    /// The highest dwell frame due at `now`, clamped to `frames`.
    ///
    /// `0` means nothing is due yet. Mirrors `stepDue` for the fixed-cadence
    /// dwell loops, whose boundaries are interval multiples rather than a
    /// duration divided into steps.
    static func dwellFrameDue(
        at now: ContinuousClock.Instant,
        from anchor: ContinuousClock.Instant,
        holdMs: Int,
        intervalMs: Int,
        frames: Int
    ) -> Int {
        guard intervalMs > 0 else { return frames }
        let elapsedMs = milliseconds(now - anchor)
        guard elapsedMs > 0 else { return 0 }
        // The final frame sits at `holdMs`, which is not a multiple of the
        // interval, so reaching the hold's end means every frame is due.
        if elapsedMs >= Int64(holdMs) { return frames }
        return min(Int(elapsedMs / Int64(intervalMs)), frames)
    }

    /// When `step` is due, measured from `anchor`.
    ///
    /// Steps are 1-based, matching the gesture loops. The division is on whole
    /// milliseconds so no rounding accumulates across steps, and `steps` lands
    /// exactly on `anchor + totalMs`.
    func deadline(forStep step: Int, from anchor: ContinuousClock.Instant) -> ContinuousClock.Instant {
        anchor + .milliseconds(totalMs * step / steps)
    }

    /// The highest step whose deadline has passed at `now`.
    ///
    /// `0` means nothing is due yet. The result clamps to `steps`, so a gesture
    /// running past its final deadline reports the last step rather than
    /// indexing off the end. A zero-duration gesture has every deadline at the
    /// anchor, so its single step is due immediately.
    func stepDue(at now: ContinuousClock.Instant, from anchor: ContinuousClock.Instant) -> Int {
        guard totalMs > 0 else { return steps }
        let elapsedMs = Self.milliseconds(now - anchor)
        guard elapsedMs > 0 else { return 0 }
        // `deadline` floors `totalMs * k / steps`, so dividing straight back
        // undercounts any step whose own deadline rounded down: at 100ms over
        // six steps, step 2 is due at 33ms but the plain inverse still reports
        // step 1, and the loop then fires two samples back to back to catch up.
        // Solve `floor(totalMs * k / steps) <= elapsedMs` instead, which is
        // `k < (elapsedMs + 1) * steps / totalMs`, so the largest such `k` is
        // that quotient rounded up, less one.
        let scaled = (elapsedMs + 1) * Int64(steps)
        let due = (scaled + Int64(totalMs) - 1) / Int64(totalMs) - 1
        return min(max(Int(due), 0), steps)
    }
}
