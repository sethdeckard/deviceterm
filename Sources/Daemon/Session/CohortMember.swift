// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// One verified member of a cohort. The incarnation is what makes a restored
/// session with the same UUID a *different* member: without it, closing a
/// session and restoring it would silently re-open access granted to the
/// earlier one.
public struct CohortMember: Sendable, Equatable, Hashable {
    public let sessionId: UUID
    public let incarnation: UInt64

    public init(sessionId: UUID, incarnation: UInt64) {
        self.sessionId = sessionId
        self.incarnation = incarnation
    }
}
