// SPDX-License-Identifier: GPL-3.0-or-later

import Observation

/// The observable state behind the automation-program failure notice.
///
/// Keeps the notice's state and its presentation mapping independent of
/// AppKit, the way `UpdateViewModel` does, so both stay testable with no
/// window server. Dismissal clears the failed names.
///
/// Unlike the update pill this does not auto-dismiss. A program deviceterm
/// has given up on stays given up on until someone acts, so a notice that
/// faded after four seconds could be the only report of it and be missed.
@MainActor
@Observable
final class AutomationProgramNoticeViewModel {
    /// Names of the programs supervision has given up on, in the order they
    /// failed. Empty means nothing to show.
    private(set) var failed: [String] = []

    var isVisible: Bool { !failed.isEmpty }

    /// One line naming what stopped, whatever the count.
    var title: String {
        switch failed.count {
        case 0:
            return ""

        case 1:
            return "\(failed[0]) stopped"

        default:
            return "\(failed.count) automation programs stopped"
        }
    }

    /// Append the newly failed names, keeping the order they failed in and
    /// never listing one twice.
    func report(_ names: [String]) {
        for name in names where !failed.contains(name) {
            failed.append(name)
        }
    }

    func dismiss() { failed = [] }
}
