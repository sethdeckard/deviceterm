// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import DaemonProtocol
import DeviceReachability
import Foundation
import InteractionRelay
import MirrorPipeline
import os

/// Why a physical-device attach couldn't be set up. All map to clean
/// RPC errors, so the attach path never crashes when a device is absent
/// or not serving the expected services.
public enum PhysicalDeviceError: Error, Equatable, Sendable {
    /// No connected device matches the requested `deviceId` (unplugged or
    /// untrusted, i.e. not in the `devicectl` roster).
    case notConnected(deviceId: String)
    /// The keepalive ran but no `utun` came up for the device within the
    /// poll window (locked, or the tunnel never established).
    case tunnelBringUpFailed(deviceId: String)
    /// Channel bootstrap couldn't complete, or the required human-input channel
    /// couldn't be established (the tunnel is up but the device isn't serving its
    /// directory, or a needed connection failed).
    case serviceCatalogUnavailable(deviceId: String)
    /// The channels bootstrapped but lack a role the pane requires (the
    /// human-input role); `service` carries its human-facing name.
    case missingService(deviceId: String, service: String)
    /// The channels vend no mirror role: the device's iOS is too old to mirror.
    /// Distinct from `missingService` so the attach path can surface a user-facing
    /// "needs a newer iOS" message rather than a raw service name.
    case tooOldToMirror(deviceId: String)
}
