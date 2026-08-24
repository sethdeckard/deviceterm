// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import os

struct RPCPerformanceBucket: Equatable {
    var calls = 0
    var replies = 0
    var timeouts = 0
    var failures = 0
    var totalMilliseconds: UInt64 = 0
    var maximumMilliseconds: UInt64 = 0
}
