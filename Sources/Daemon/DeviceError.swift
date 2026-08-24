// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation

public enum DeviceError: Error, Equatable, Sendable {
    case notFound(
        udid:
        String
        )
    case bootFailed(
        udid:
        String,
        message: String
        )
    case shutdownFailed(
        udid:
        String,
        message: String
        )
    case listFailed(
        message:
        String
        )
    case listTimedOut
    /// `udid` parameter wasn't a well-formed string. UDID format on
    /// macOS is the standard 8-4-4-4-12 UUID. The bridge accepts it
    /// case-insensitively, but we still reject the empty string and
    /// other obvious junk before paying for a bridge round-trip.
    case malformedUDID(
        udid:
        String
        )
}
