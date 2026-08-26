// SPDX-License-Identifier: GPL-3.0-or-later
/// The device's self-reported identity, read from the service-directory
/// handshake's properties.
///
/// `uniqueDeviceID` is the device's real, stable UDID rather than the ephemeral
/// tunnel address the daemon may otherwise key on. Every field is optional
/// because a locked or partially-answering device may omit some.
package struct DeviceIdentity: Sendable, Equatable {
    package let uniqueDeviceID: String?
    package let productType: String?
    package let osVersion: String?
    /// The user-visible model name, e.g. "iPhone 16 Pro".
    package let marketingName: String?

    package init(
        uniqueDeviceID: String?,
        productType: String?,
        osVersion: String?,
        marketingName: String?
    ) {
        self.uniqueDeviceID = uniqueDeviceID
        self.productType = productType
        self.osVersion = osVersion
        self.marketingName = marketingName
    }
}
