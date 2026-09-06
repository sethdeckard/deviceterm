// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

enum UITestClientError: Error, Equatable, CustomStringConvertible {
    /// Couldn't connect, most likely because no resident harness is running.
    case notRunning(path: String)
    /// The resident closed its side before a complete frame arrived.
    case connectionClosed
    /// The resident stayed connected but did not finish a reply in time.
    case replyTimedOut(seconds: TimeInterval)

    var description: String {
        switch self {
        case let .notRunning(path):
            "no resident harness at \(path)"

        case .connectionClosed:
            "resident closed the connection before sending a complete reply"

        case let .replyTimedOut(seconds):
            "resident did not reply within \(seconds.formatted()) seconds"
        }
    }
}
