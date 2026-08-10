// SPDX-License-Identifier: GPL-3.0-or-later
//
/// Why a device route could not be resolved.
package enum DeviceReachabilityError: Error, Equatable, Sendable {
    /// No `utun` carrying the device's advertised tunnel address appeared
    /// within the resolver's polling window: the device stayed locked, or the
    /// OS never finished bringing the tunnel up. Includes the case where an
    /// address was advertised but never lined up with a live interface.
    case tunnelUnavailable(deviceId: String)
}
