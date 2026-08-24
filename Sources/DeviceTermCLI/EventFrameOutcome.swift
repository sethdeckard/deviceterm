// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Classification of one decoded `daemon.events` frame.
enum EventFrameOutcome: Equatable {
    case event(Data)
    case subscriptionAck
    case unauthorizedSession
    case daemonError(code: Int, message: String)
}
