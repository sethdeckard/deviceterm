// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum SimulatorShellOutError: Error, CustomStringConvertible, Sendable {
    case commandFailed(arguments: [String], status: Int32, stderr: String)

    var description: String {
        switch self {
        case let .commandFailed(arguments, status, stderr):
            let cmd = (["xcrun"] + arguments).joined(separator: " ")
            return stderr.isEmpty
                ? "`\(cmd)` failed (exit \(status))"
                : "`\(cmd)` failed (exit \(status)): \(stderr)"
        }
    }
}
