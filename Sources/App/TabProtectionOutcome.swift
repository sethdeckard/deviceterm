// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// First decisive outcome of an awaited tab-protection transition, reported
/// to the intent layer so `tab set-protected` reflects the daemon's real
/// state. `.pending` means the requested state remains unconfirmed because
/// of a deadline, indeterminate transport loss, same-state supersession, or
/// tab disappearance.
enum TabProtectionOutcome: Sendable, Equatable {
    case committed
    case rejected
    case pending
}
