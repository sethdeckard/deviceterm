// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One reading of what the daemon is holding.
///
/// The queue and counter fields come from existing actor state; the footprint
/// is queried with `task_info` at sampling time. Sampling adds no per-frame
/// bookkeeping, though it does take the pane coordinator and each pane's pool
/// briefly. Together the fields distinguish growth from wedged acquisitions,
/// abandoned reads, stalled subscribers, held surfaces, or unfinished
/// handlers.
///
/// Nothing here identifies a device, session, or capability, so the whole
/// sample logs `.public` and survives `log show`.
struct DaemonFootprintSample: Sendable, Equatable {
    /// Physical footprint in bytes, or nil when `task_info` failed.
    var footprintBytes: UInt64?
    var panes = 0
    /// Panes whose close has not completed. A value that persists across
    /// samples indicates slow or stuck teardown.
    var retiringPanes = 0
    var subscribers = 0
    /// Pane events queued across current subscribers, and the surface notices
    /// their channels have folded away. A subscriber that goes away takes its
    /// counts with it.
    var pendingPaneEvents = 0
    var conflatedSurfaceNotices = 0
    /// Simulator lookups currently inside CoreSimulator.
    var acquiresInFlight = 0
    /// Display-start admission slots currently held, abandoned attempts
    /// included. Persisting across samples means an admitted create is stuck
    /// acquiring, bootstrapping, or disposing a backend.
    var displayStartsInFlight = 0
    /// Targets claimed after backend acquisition returned, held until the pane
    /// publishes or disposal finishes. Persisting across samples means a
    /// post-acquisition create has not settled.
    var reservedTargets = 0
    /// Device reads that passed their deadline and are still unaccounted for.
    var abandonedDeviceReads = 0
    /// Inbound XPC event handlers registered on live connections and not yet
    /// retired. Notifications are admitted the same way, so this is not a
    /// count of requests awaiting a reply.
    var xpcRequestsInFlight = 0
    var xpcConnections = 0
    /// Summed across every pane's pool. Frames dropped because no slot was
    /// free, and reuse attempts made while `IOSurfaceIsInUse` still reported
    /// the slot in use. The second says nothing about which holder kept it.
    var surfaceExhaustionDrops = 0
    var surfaceReuseWhileInUse = 0
    /// Cumulative sightings, not a current count, and physical devices only.
    /// The watchdog that produces them runs in `RealDeviceBackend`, so a
    /// simulator pool always reports zero, and one stuck hold on a device is
    /// counted again on every sweep. A rise means the watchdog observed one or
    /// more delinquent holds since the previous reading; the value is not a
    /// current hold count or a duration.
    var delinquentSightings = 0
    /// Input sends whose call returned without error, summed across every
    /// pane. Cumulative per backend, so a pane that closes takes its count
    /// with it. Not delivery: a simulator's HID transport reports success for
    /// a port the guest no longer services, and a device keyboard failure is
    /// swallowed before the relay returns. A count that climbs while the
    /// guest shows no effect is what this is for.
    var inputSubmissions = 0

    /// The single-line payload the logger emits. Formatted here rather than at
    /// the log call so a test can assert on the same string the log carries.
    var summary: String {
        let footprint = footprintBytes.map { "\($0 / 1_048_576)MiB" } ?? "unknown"
        return "footprint=\(footprint) panes=\(panes) retiring=\(retiringPanes) "
            + "subs=\(subscribers) "
            + "paneEventsQueued=\(pendingPaneEvents) "
            + "surfaceNoticesConflated=\(conflatedSurfaceNotices) "
            + "acquiresInFlight=\(acquiresInFlight) "
            + "displayStartsInFlight=\(displayStartsInFlight) "
            + "reservedTargets=\(reservedTargets) "
            + "abandonedReads=\(abandonedDeviceReads) "
            + "xpcInFlight=\(xpcRequestsInFlight) xpcConns=\(xpcConnections) "
            + "surfaceDrops=\(surfaceExhaustionDrops) "
            + "surfaceReuseInUse=\(surfaceReuseWhileInUse) "
            + "delinquentSightings=\(delinquentSightings) "
            + "inputSends=\(inputSubmissions)"
    }
}
