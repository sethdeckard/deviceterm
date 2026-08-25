// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The production pacer: a real continuous clock, slept against with no
/// tolerance.
///
/// `Task.sleep(nanoseconds:)` accepts scheduler leeway by default. Zero
/// tolerance declines that added slack; the task can still wake late for
/// reasons the pacer has no say over.
struct SystemGesturePacer: GesturePacing {
    func now() -> ContinuousClock.Instant {
        ContinuousClock.now
    }

    func sleep(until deadline: ContinuousClock.Instant) async {
        try? await Task.sleep(until: deadline, tolerance: .zero, clock: .continuous)
    }
}
