// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

enum BootClaimRequestOutcome: Sendable {
    case accepted
    case rejected
    case uncertain
}
