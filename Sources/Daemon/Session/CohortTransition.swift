// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Everything one cohort reconcile decided, returned by value.
///
/// No caller reads a "last result" property. A transition's consequences
/// belong to that transition, and an actor-global side channel can be
/// overwritten by an intervening call before the caller gets to it.
struct CohortTransition: Sendable, Equatable {
    var applied: Bool = false
    var rejection: CohortReconcileRejection?
    /// Members this reconcile removed: dropped by a replacement, or absent
    /// from a same-id resubmission. Still alive, so their panes change hands
    /// as a targeted transfer, never as a close.
    var removed: [CohortMember] = []
    var bindings: [SessionCohortBindingResult] = []
}
