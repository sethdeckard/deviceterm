// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import os

enum RPCPerformanceOutcome: String, Sendable {
    case reply
    case replyError
    case timeout
    case transport
    case cancelled
    case localFailure
}
