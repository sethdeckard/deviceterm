// SPDX-License-Identifier: GPL-3.0-or-later
/// A resolved path to a connected device: which `utun` carries its traffic and
/// the unique-local addresses of both ends of that point-to-point link.
///
/// Produced by `DeviceRouteResolver` once the OS has brought the tunnel up, and
/// consumed downstream to open channels to the device's services. It is a
/// snapshot of where the device could be reached at resolution time; it carries
/// no liveness guarantee beyond that instant.
package struct DeviceRoute: Sendable, Equatable {
    /// The device's stable CoreDevice handle (its real UDID).
    package let deviceId: String
    /// The `utun` interface the OS is using for this device.
    package let interfaceName: String
    /// This host's (Mac) end of the link.
    package let hostAddress: String
    /// The device's end of the link, the address channels dial.
    package let deviceAddress: String

    package init(
        deviceId: String,
        interfaceName: String,
        hostAddress: String,
        deviceAddress: String
    ) {
        self.deviceId = deviceId
        self.interfaceName = interfaceName
        self.hostAddress = hostAddress
        self.deviceAddress = deviceAddress
    }
}
