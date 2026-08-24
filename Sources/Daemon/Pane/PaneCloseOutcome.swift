// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation
import IOSurface
import os
import SurfaceTrace

public struct PaneCloseOutcome: Sendable, Equatable {
    /// `udid` to shut down after the pane is gone, if the caller
    /// asked for `.shutdown` mode. `nil` for detach mode or unknown
    /// paneIds.
    public let udidToShutdown: String?
    /// The physical-device `deviceId` whose tunnel keepalive should be
    /// released now that this pane is gone: non-nil only when the closed
    /// pane mirrored a physical device. The RPC layer forwards it to
    /// `PhysicalDeviceCoordinator.releaseKeepalive`, keeping pane lifecycle
    /// decoupled from the tunnel-holding subprocess (same pattern as
    /// `udidToShutdown`).
    public let deviceTunnelToRelease: String?

    public init(udidToShutdown: String?, deviceTunnelToRelease: String? = nil) {
        self.udidToShutdown = udidToShutdown
        self.deviceTunnelToRelease = deviceTunnelToRelease
    }
}
