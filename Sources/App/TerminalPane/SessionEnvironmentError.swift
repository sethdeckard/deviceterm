// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum SessionEnvironmentError: Error {
    case shimBinaryNotFound
    case directorySetupFailed(String)
}
