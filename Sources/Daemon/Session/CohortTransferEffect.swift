// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

struct CohortTransferEffect: Sendable, Equatable {
    let previousOwner: CohortMember
    let successor: CohortMember
    let targets: [PaneTarget]
}
