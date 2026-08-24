// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// What a teardown found.
enum CohortTearDownDisposition: Sendable, Equatable {
    /// A verdict was already recorded (an explicit close or a `beginClose`
    /// preceded removal); membership is converged and nothing more is owed.
    case alreadyDecided
    /// A reaped member of a live tab: the survivors inherit.
    case promoted(successor: CohortMember)
    /// The member belonged to no cohort, or was its last member. No device
    /// consequence: a reap never dispositions devices, because only an
    /// explicit close carries a user's choice, and GUI recovery owns the
    /// rest.
    case terminal
}
