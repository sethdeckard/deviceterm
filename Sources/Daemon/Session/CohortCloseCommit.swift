// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// What a `beginClose` commit decided.
struct CohortCloseCommit: Sendable, Equatable {
    var applied: Bool = false
    /// The verdict, present on any applied commit, including a journal
    /// replay.
    var outcome: CohortCloseOutcome?
    /// The members this commit removed, for the coordinator to re-home and
    /// emit. Empty on a journal replay: the first commit already did both.
    var closed: [CohortMember] = []
    var successor: CohortMember?
}
