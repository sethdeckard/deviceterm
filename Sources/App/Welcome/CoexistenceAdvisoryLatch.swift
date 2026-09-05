// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// One "an advisory already appeared this launch" flag, shared by every
/// coexistence advisory.
///
/// A per-advisory latch can't do this job, because neither advisory sees
/// what the other presented. On a machine running both Simulator.app and
/// Device Hub, a single sim attach satisfies both, and the second alert
/// lands on a user still reading the first, which is how both get
/// dismissed unread.
///
/// The rule is one coexistence warning per launch. That matches the
/// welcome catalog's one-per-launch rule and the existing gate where a
/// welcome silences the advisory.
///
/// This flag admits one warning; it does not choose which. When both
/// apply, `HeadlessAdvisoryDecision` yields to Device Hub before either
/// presents, so the choice is made in the decision layer and this latch
/// only stops whatever comes after.
///
/// Injected rather than reached for, so a test gets its own instance and
/// isn't ordered against the rest of the suite by a process-global flag.
@MainActor
@Observable
final class CoexistenceAdvisoryLatch {
    /// Shared instance. The flag is process-global by design: every pane
    /// attach, of either kind, has to see the same answer.
    static let shared = CoexistenceAdvisoryLatch()

    /// True once any coexistence advisory has been presented this launch.
    /// In-process only; persistent opt-out is each advisory's own config
    /// key.
    private(set) var didShowThisLaunch = false

    func markPresented() {
        didShowThisLaunch = true
    }
}
