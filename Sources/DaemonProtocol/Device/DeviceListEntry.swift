// SPDX-License-Identifier: GPL-3.0-or-later

/// One entry of the bare-array `device.list` result. Mirrors
/// `DeviceMethods.ListEntry`. `state` is the CoreSimulator state name
/// ("Booted", "Shutdown", …); `ownedBySession` is the owning session UUID
/// string, omitted when unowned.
public struct DeviceListEntry: Codable, Sendable, Equatable {
    public let udid: String
    public let name: String
    public let state: String
    public let ownedBySession: String?
    /// Coarse device family (see `DeviceFamily`). Optional-decoded so a
    /// mismatched (older) daemon that doesn't send it still decodes cleanly.
    public let family: String?
    /// Human-readable device type (e.g. "Apple Watch Ultra 3 (49mm)",
    /// "iPhone 17 Pro"). Sourced from `SimDeviceType.name`. Optional
    /// for skew tolerance: an older daemon that doesn't expose the
    /// field still decodes cleanly. Drives the chrome strip's
    /// "Name · Type" composition; a stock un-renamed sim where
    /// `name == deviceType` collapses to just the name.
    public let deviceType: String?

    public init(
        udid: String,
        name: String,
        state: String,
        ownedBySession: String?,
        family: String? = nil,
        deviceType: String? = nil
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.ownedBySession = ownedBySession
        self.family = family
        self.deviceType = deviceType
    }
}
