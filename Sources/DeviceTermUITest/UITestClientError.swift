// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

enum UITestClientError: Error, Equatable {
    /// Couldn't connect, most likely because no resident harness is running.
    case notRunning(path: String)
    /// Connected, but no complete reply arrived before the deadline / EOF.
    case noReply
}
