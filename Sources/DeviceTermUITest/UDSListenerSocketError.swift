// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum UDSListenerSocketError: Error, Equatable {
    case socketFailed(errno: Int32)
    case bindFailed(errno: Int32, path: String)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case socketPathTooLong(path: String)
    case socketPathExists(path: String)
    /// A peer connected but didn't finish sending (or reading) a frame
    /// within `ioTimeoutSeconds`. The connection is dropped rather than
    /// held open.
    case timedOut
}
