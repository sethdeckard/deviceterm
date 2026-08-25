// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import IOSurface
import os

/// Purpose of one GUI XPC peer. The lanes share the daemon's Mach service and
/// wire protocol, but use different connections so high-rate pane traffic
/// cannot sit ahead of ordinary request replies in one XPC send queue.
enum XPCClientLane: String, Sendable {
    case control
    case pane
}
