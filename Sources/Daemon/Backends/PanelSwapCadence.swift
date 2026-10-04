// SPDX-License-Identifier: GPL-3.0-or-later

/// How the display lane paces its search for a foldable's newly lit panel, and
/// when the search ends.
///
/// A fold takes the old panel dark before the new one lights, and the gap
/// measured a few hundred milliseconds, so the search opens with quick polls.
/// A swap that hasn't resolved by the end of that window is still followed, at
/// a slower pace, for as long as the bound panel shows no sampled content,
/// which includes a panel that can't be sampled. The search ends on a rebind,
/// or once the bound panel shows content again, which means no swap is
/// pending. A later properties change or shutdown cancels it from outside.
///
/// The quick phase ignores whether a swap is pending, because the old panel can
/// still be lit for tens of milliseconds after the notice that starts the
/// search. A lit panel drawing black reads as dark, so a search on one keeps
/// polling at the patient pace until something cancels it.
enum PanelSwapCadence {
    /// What the search does after an attempt.
    enum Step: Equatable {
        case wait(nanoseconds: UInt64)
        case stop
    }

    static let quickAttempts = 30
    static let quickIntervalNanoseconds: UInt64 = 100_000_000
    static let patientIntervalNanoseconds: UInt64 = 1_000_000_000

    /// Whether the search is past its quick phase once `attempts` attempts have
    /// run, which is when `swapPending` starts to count.
    static func isPatient(afterAttempts attempts: Int) -> Bool {
        attempts >= quickAttempts
    }

    /// The next step after `attempts` attempts, the last of which rebound the
    /// display if `rebound`. `swapPending` says the bound panel shows no sampled
    /// content, unreadable included, and is ignored during the quick phase.
    static func next(afterAttempts attempts: Int, rebound: Bool, swapPending: Bool) -> Step {
        if rebound { return .stop }
        guard isPatient(afterAttempts: attempts) else { return .wait(nanoseconds: quickIntervalNanoseconds) }
        return swapPending ? .wait(nanoseconds: patientIntervalNanoseconds) : .stop
    }
}
