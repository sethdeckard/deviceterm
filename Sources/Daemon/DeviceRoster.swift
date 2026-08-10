// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceRoster: pure builder for the `devices.list` aggregate.
//
// Combines booted sims + connected physical devices and annotates each
// with the owning session of a live pane that mirrors it, but only
// when that session is visible to the caller, so a device attached to a
// private tab the caller doesn't own reads as unattached. That reuses
// the exact `tabs.list` opacity rule (the caller passes the set of
// session ids visible to them; an owner-hidden private session simply
// isn't in it). Pure, so the opacity logic is unit-tested without a
// device or CoreSimulator.

import DaemonProtocol
import Foundation

enum DeviceRoster {
    /// A booted sim the roster should list. `DeviceCoordinator` supplies
    /// these so the builder stays free of CoreSimulator.
    struct SimEntry: Sendable, Equatable {
        let udid: String
        let name: String
        let state: String
    }

    /// Display state reported for a connected physical device (sims
    /// carry their CoreSimulator state string instead).
    static let physicalState = "connected"

    static func build(
        sims: [SimEntry],
        physical: [PhysicalDeviceInfo],
        ownerships: [PaneOwnership],
        visibleSessionIds: Set<UUID>
    ) -> [DeviceRosterEntry] {
        // Key by the full `PaneTarget` (already `Hashable`), not the bare
        // id string: a sim `.sim(udid)` and a physical `.device(deviceId)`
        // that happen to share id text must annotate independently, never
        // cross-match.
        var ownerByTarget: [PaneTarget: PaneOwnership] = [:]
        for ownership in ownerships where ownerByTarget[ownership.target] == nil {
            ownerByTarget[ownership.target] = ownership
        }
        func entry(
            id: String,
            kind: DeviceKind,
            name: String?,
            state: String?,
            model: String? = nil,
            osVersion: String? = nil
        ) -> DeviceRosterEntry {
            let target: PaneTarget = kind == .sim ? .sim(udid: id) : .device(deviceId: id)
            // Opacity: annotate the owner only when the caller can see
            // that session; otherwise the device reads as unattached,
            // exactly as `tabs.list` hides a private tab from non-owners.
            if let owner = ownerByTarget[target], visibleSessionIds.contains(owner.sessionId) {
                return DeviceRosterEntry(
                    id: id,
                    kind: kind,
                    name: name,
                    model: model,
                    osVersion: osVersion,
                    state: state,
                    attached: true,
                    ownerSessionId: owner.sessionId.uuidString
                )
            }
            return DeviceRosterEntry(
                id: id,
                kind: kind,
                name: name,
                model: model,
                osVersion: osVersion,
                state: state
            )
        }
        // Sim UDIDs are case-insensitive UUIDs. CoreSimulator hands them
        // back uppercase, but the daemon's canonical form (and so
        // `PaneOwnership.targetKey` (from `canonicalizeUDID`) and the
        // `panes.list` udid) is lowercase. Normalize the sim id to that
        // canonical form so the ownership match lines up and the id a
        // client correlates with `panes.list` is identical. Physical
        // deviceIds are the stable CoreDevice UDID (the `devicectl
        // --device` argument, not an ephemeral tunnel address) and pass
        // through unchanged.
        var entries = sims.map {
            entry(id: $0.udid.lowercased(), kind: .sim, name: $0.name, state: $0.state)
        }
        entries += physical.map {
            entry(
                id: $0.deviceId,
                kind: .device,
                name: $0.name,
                state: physicalState,
                model: $0.model,
                osVersion: $0.osVersion
            )
        }
        return entries.sorted { $0.id < $1.id }
    }
}
