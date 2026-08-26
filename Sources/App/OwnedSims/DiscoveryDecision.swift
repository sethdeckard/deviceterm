// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// The pure per-tab core of app-wide owned-sim discovery.
/// Given the daemon's owned+booted sims for this tab and the tab's bookkeeping
/// sets, it decides which sims need panes and prunes the "already handled"
/// memory. The coordinator reads once, each VC decides and dispatches attach;
/// only the bug-prone set logic is extracted and unit-tested.
struct DiscoveryDecision: Equatable {
    /// Sims that need a fresh pane, in `ownedBooted` order.
    let toAttach: [DeviceListEntry]
    /// `handled` pruned to sims still in the booted+owned set, so a sim
    /// that has shut down is forgotten and a later fresh boot re-attaches.
    let updatedHandled: Set<String>

    /// - Parameters:
    ///   - ownedBooted: sims the daemon reports Booted and owned by this
    ///     session (the caller applies that filter).
    ///   - handled: udids a pane has already been shown for this boot.
    ///   - attaching: udids mid-attach (guards a racing poll/resurrect).
    ///   - mounted: udids that already have a live pane.
    static func decide(
        ownedBooted: [DeviceListEntry],
        handled: Set<String>,
        attaching: Set<String>,
        mounted: Set<String>
    ) -> DiscoveryDecision {
        let bootedUDIDs = Set(ownedBooted.map(\.udid))
        let updatedHandled = handled.intersection(bootedUDIDs)
        let toAttach = ownedBooted.filter {
            !updatedHandled.contains($0.udid)
                && !attaching.contains($0.udid)
                && !mounted.contains($0.udid)
        }
        return DiscoveryDecision(toAttach: toAttach, updatedHandled: updatedHandled)
    }
}
