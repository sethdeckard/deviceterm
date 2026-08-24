// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import DaemonProtocol
import DeviceReachability
import Foundation
import InteractionRelay
import MirrorPipeline
import os

/// A connected physical device as the daemon's roster sees it. `deviceId`
/// is the device's real CoreDevice **UDID** (the `devicectl --device`
/// argument), stable across reconnects, unlike the ephemeral tunnel
/// address. Tunnel coordinates are intentionally absent here: they aren't
/// known until a tunnel is up, which the attach path arranges on demand.
public struct PhysicalDeviceInfo: Sendable, Equatable {
    public let deviceId: String
    public let name: String?
    public let model: String?
    public let osVersion: String?

    public init(
        deviceId: String,
        name: String? = nil,
        model: String? = nil,
        osVersion: String? = nil
    ) {
        self.deviceId = deviceId
        self.name = name
        self.model = model
        self.osVersion = osVersion
    }

    init(from device: DeviceCtlDevice) {
        self.deviceId = device.udid
        self.name = device.name
        self.model = device.model
        self.osVersion = device.osVersion
    }
}
