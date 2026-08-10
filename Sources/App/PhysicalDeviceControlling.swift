// SPDX-License-Identifier: GPL-3.0-or-later
//
// Role protocol: physically-connected device control on the daemon.
//
// Parallel to `DeviceControlling` (which is CoreSimulator lifecycle). This
// covers the physical-device RPCs the GUI picker + device-attach path use:
// enumerate connected devices and mount one as a pane. A narrow role so the
// picker VM (and its test fake) depend only on these two methods.

import DaemonProtocol

@MainActor
protocol PhysicalDeviceControlling: AnyObject {
    /// `physicalDevice.list`: connected physical devices for the picker.
    /// Daemon-wide; empty when none is plugged in / unlocked / trusted.
    func physicalDeviceList() async throws -> [PhysicalDeviceListEntry]
    /// `physicalDevice.attach`: mount `deviceId` as a pane attributed to
    /// `sessionId` (the target tab's session). The GUI threads the target
    /// session explicitly because its one shared connection can't pick the
    /// tab via connection-auth (the daemon honors it only on this trusted
    /// XPC path). There is no capability; `sessionId` is attribution, not a credential.
    func attachPhysicalDevice(
        deviceId: String,
        sessionId: String
    ) async throws -> PaneCreateResponse
}
