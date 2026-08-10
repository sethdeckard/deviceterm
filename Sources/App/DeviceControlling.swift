// SPDX-License-Identifier: GPL-3.0-or-later
//
// Role protocol: simulator device control on the daemon.
//
// One of four narrow role protocols carved out of `DaemonClient`
// (see `SessionControlling` for the rationale). Covers the device-
// level RPCs: list, boot, shutdown, and attach-into-a-session.

import DaemonProtocol

@MainActor
protocol DeviceControlling: AnyObject {
    /// `device.list`, where `scope` is `.owned` or `.all`.
    func deviceList(scope: DeviceListScope) async throws -> [DeviceListEntry]
    /// `device.boot`: boot `udid`. When `(sessionId, capability)` is
    /// given the daemon attributes ownership to that session.
    func bootDevice(
        udid: String,
        sessionId: String?,
        capability: String?
    ) async throws
    /// `device.shutdown`: stop a booted simulator.
    func shutdownDevice(udid: String) async throws
    /// `device.attach`: transfer ownership of an already-Booted `udid`
    /// to `(sessionId, capability)` and create its sim pane.
    func attachDevice(
        sessionId: String,
        capability: String,
        udid: String
    ) async throws -> PaneCreateResponse
}
