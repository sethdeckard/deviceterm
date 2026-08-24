// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Why a reconcile did not commit.
enum CohortReconcileRejection: Sendable, Equatable {
    case staleKey
    case memberInForeignCohort
    case representativeNotAMember
    /// A replacement could not rebind every pane referencing the outgoing
    /// cohort, so the whole request was refused rather than stranding one.
    case bindingRefused
    /// The id was retired by a replacement. A retired id is dead for good:
    /// accepting a late reconcile for it would rebind panes away from the
    /// cohort that replaced it.
    case cohortRetired
    /// A named member is not live at the incarnation given.
    case memberNotLive
    /// A named member has a recorded close verdict. Its consequences are
    /// already committed and possibly already applied, so reinstalling it
    /// would revive an authorization the close withdrew, and a GUI that
    /// died after `beginClose` would leave that revival standing forever.
    /// The member's next incarnation carries no verdict and installs freely.
    case memberClosed
    /// The same member appears twice. An ordered membership with a duplicate
    /// would close that member twice, and emit its consequences twice.
    case duplicateMember
}
