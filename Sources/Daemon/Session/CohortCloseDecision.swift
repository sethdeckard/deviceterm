// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// What an explicit close's verdict request decided.
enum CohortCloseDecision: Sendable, Equatable {
    /// A `beginClose` already decided this member; its consequences are
    /// already out.
    case alreadyRecorded
    case decided(outcome: CohortCloseOutcome, successor: CohortMember?)
}
