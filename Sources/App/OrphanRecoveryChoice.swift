// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol

enum OrphanRecoveryChoice: Sendable, Equatable {
    case reattach
    case shutdownAll
    case leaveRunning
}
