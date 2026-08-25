// SPDX-License-Identifier: GPL-3.0-or-later

/// One entry of the bare-array `physicalDevice.list` result: a
/// physically-connected iPhone/iPad the daemon can mirror. Feeds the
/// GUI "Mirror Physical Device…" picker.
///
/// `deviceId` is the daemon's handle for the device: its real CoreDevice
/// **UDID**, read from `devicectl list devices` (which works over usbmux
/// with no tunnel up). Stable across reconnects and human-meaningful, the
/// same id the `devicectl --device` spec uses. The tunnel address is no
/// longer the handle; it's resolved on demand at attach when the daemon
/// brings the device's tunnel up itself.
public struct PhysicalDeviceListEntry: Codable, Sendable, Equatable {
    public let deviceId: String
    /// Best-effort human-readable device name. Nil when the handshake
    /// doesn't expose one (the common case).
    public let name: String?
    /// Best-effort device model. Nil when unknown.
    public let model: String?
    /// Best-effort OS version (e.g. `"17.5"`). Nil when unknown. With
    /// `model`, disambiguates two connected devices that share a name.
    public let osVersion: String?
    /// Whether this device is currently connected and **selectable** in the
    /// picker. **Today this is always `true`**: `physicalDevice.list` is a
    /// cheap enumeration, not a mirror-capability probe; capability is judged
    /// at attach (an iOS-too-old device surfaces a clear error then). This is
    /// the forward slot for a future picker that pre-greys rows via an async
    /// per-device probe, so it is *not* a known-mirror-capable signal yet.
    public let available: Bool
    /// Why `available` is false, once a future async probe populates it (iOS
    /// too old, no media support…). Always nil today.
    public let unavailableReason: String?

    public init(
        deviceId: String,
        name: String? = nil,
        model: String? = nil,
        osVersion: String? = nil,
        available: Bool = true,
        unavailableReason: String? = nil
    ) {
        self.deviceId = deviceId
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.available = available
        self.unavailableReason = unavailableReason
    }
}
