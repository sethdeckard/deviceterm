// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum UDSClientSocketError: Error, Equatable, Sendable {
    case socketFailed(
        errno:
        Int32
        )
    case connectFailed(
        errno:
        Int32,
        path: String
        )
    case socketPathTooLong(
        path:
        String
        )
    case readFailed(
        errno:
        Int32
        )
    case writeFailed(
        errno:
        Int32
        )
}
