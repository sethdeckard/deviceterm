// SPDX-License-Identifier: GPL-3.0-or-later
//
// GesturePacing: the clock a paced `pane.input.*` gesture sleeps against.
//
// Sleeping a nominal interval per step and counting the nominal value as
// time spent lets every step's scheduler leeway compound, so a long hold
// overshoots by more than a short one. A gesture instead computes absolute
// deadlines from one anchor and sleeps to them, which bounds the total error
// against that anchor rather than growing it with the step count.
//
// The seam exists because a two-frame dwell is not observable against real
// time without making the test a race. A fake conformer advances a virtual
// instant on demand, so missed-deadline behaviour is exercised deterministically
// and nothing sleeps.

import Foundation

/// The clock and sleeper a paced gesture schedules against.
protocol GesturePacing: Sendable {
    func now() -> ContinuousClock.Instant
    /// Suspend until `deadline`.
    ///
    /// Non-throwing, and returns early when the task is cancelled, so a
    /// cancelled gesture still reaches the checkpoint after its sleep and can
    /// release the contact it holds. A throwing sleep would skip that release.
    func sleep(until deadline: ContinuousClock.Instant) async
}
