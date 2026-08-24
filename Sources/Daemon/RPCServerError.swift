// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum RPCServerError: Error, Equatable, Sendable {
    case alreadyStarted
    case notStarted
}
