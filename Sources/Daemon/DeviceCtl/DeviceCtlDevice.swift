// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One physically-connected device as `devicectl list devices` reports it.
/// `udid` is the stable CoreDevice identifier (the `--device` argument).
/// `tunnelState` / `tunnelIPAddress` are populated only while a tunnel is
/// up; with it down they are `"disconnected"` / `nil` but the device is
/// still listed (the whole point: selectable without Device Hub).
struct DeviceCtlDevice: Sendable, Equatable {
    let udid: String
    let name: String?
    let model: String?
    let osVersion: String?
    let transportType: String?
    let tunnelState: String?
    let tunnelIPAddress: String?
}
