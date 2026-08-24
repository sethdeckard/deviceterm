// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

struct CohortCloseEffect: Sendable, Equatable {
    let sessionId: UUID
    /// The incarnation the verdict was recorded for, nil only on the
    /// compatibility arm where a close raced session removal before it could
    /// be resolved. A tombstone without one applies to every claim naming the
    /// session, whatever its incarnation.
    let incarnation: UInt64?
    let outcome: CohortCloseOutcome
}
