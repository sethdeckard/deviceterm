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
    /// The connection currently in use. For a caller that needs to name the
    /// live connection on its own, with no call to hang it off. Anything
    /// reporting the outcome of a call takes the generation from that call's
    /// own `…WithGeneration` form instead, which captures it with the answer
    /// rather than sampling it afterward, where a replacement can slip in.
    var connectionGeneration: Int { get }
    /// `device.list`, where `scope` is `.owned` or `.all`.
    func deviceList(scope: DeviceListScope) async throws -> [DeviceListEntry]
    /// `device.list`, plus the connection generation that answered it, captured
    /// with the request rather than sampled after it. For a caller that has to
    /// attribute the answer to a particular helper, which a later sample can
    /// get wrong once a replacement is live.
    func deviceListWithGeneration(
        scope: DeviceListScope
    ) async throws -> (entries: [DeviceListEntry], generation: Int)
    /// `device.boot`: register an optional causal claim and boot `udid`.
    func bootDevice(
        udid: String,
        sessionId: String?,
        capability: String?,
        claim: BootClaimEvidence?
    ) async throws
    /// `device.boot`, returning the connection that accepted the intent.
    func bootDeviceWithGeneration(
        udid: String,
        sessionId: String?,
        capability: String?,
        claim: BootClaimEvidence?
    ) async throws -> Int
    /// Reconcile a GUI-retained boot attempt against the live daemon.
    func reconcileBootClaim(
        claim: BootClaimEvidence,
        sessionId: String?
    ) async throws -> (result: DeviceReconcileBootClaimResult, generation: Int)
    /// `device.shutdown`: stop a booted simulator.
    func shutdownDevice(udid: String) async throws
    /// `device.attach`: transfer ownership of an already-Booted `udid`
    /// to `(sessionId, capability)` and create its sim pane.
    func attachDevice(
        sessionId: String,
        capability: String,
        udid: String
    ) async throws -> PaneCreateResponse
    /// `device.attach`, returning the connection that recorded the ownership.
    func attachDeviceWithGeneration(
        sessionId: String,
        capability: String,
        udid: String
    ) async throws -> (response: PaneCreateResponse, generation: Int)
    /// `device.restoreOwnership`: restore deviceterm's owned-sim claims to a
    /// helper that restarted, preserving a live session attribution where one
    /// exists.
    func restoreOwnership(
        devices: [RestoredSimOwnership]
    ) async throws -> DeviceRestoreOwnershipResult
}
