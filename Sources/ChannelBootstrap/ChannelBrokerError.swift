// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Why channel bootstrap couldn't complete.
package enum ChannelBrokerError: Error, Sendable, Equatable {
    /// No open port answered the directory handshake, so either the device is
    /// locked or the tunnel isn't serving its directory.
    case directoryUnavailable
    /// A channel was requested for a role the device doesn't vend.
    case roleUnavailable(ChannelRole)
}
