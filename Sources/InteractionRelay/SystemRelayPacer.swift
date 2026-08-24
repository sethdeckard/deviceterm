// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The production pacer: a real continuous clock, slept against with no
/// tolerance. Zero tolerance declines the leeway a sleep would otherwise
/// accept; a frame can still wake late.
struct SystemRelayPacer: RelayPacing {
    func now() -> ContinuousClock.Instant {
        ContinuousClock.now
    }

    func sleep(until deadline: ContinuousClock.Instant) async {
        try? await Task.sleep(until: deadline, tolerance: .zero, clock: .continuous)
    }
}
