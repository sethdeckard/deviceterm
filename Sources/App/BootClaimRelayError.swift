// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Dispatch
import Foundation
import TerminalProvenance
#if canImport(Darwin)
import Darwin
#endif

enum BootClaimRelayError: Error {
    case socketPathTooLong
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case permissionFailed(Int32)
}
