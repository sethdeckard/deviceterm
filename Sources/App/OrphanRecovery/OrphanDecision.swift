// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// The pure core of OrphanRecovery.collect.
/// `collect` does the filesystem read (enumerate session dirs, skip
/// live-owner dirs via kill(0), parse owned-udids.json) and hands the
/// dead-session candidates here; this resolver intersects them with the
/// daemon's ownership + Booted truth to decide live orphans vs.
/// already-empty dead dirs. No filesystem and no daemon, so it is unit-tested.
enum OrphanDecision {
    /// Resolve which dead sessions still own Booted sims (→ `live`
    /// orphan records) and which are empty (→ `dead` dir paths to sweep).
    ///
    /// A manifest UDID counts only if the daemon doesn't yet attribute it
    /// or still attributes it to this same dead session (daemon truth
    /// wins a tie, since a partial re-attach can leave a stale manifest line).
    /// Any Booted sim the daemon attributes to a dead session is also an
    /// orphan, manifest or not (the shim-boot path).
    static func resolve(
        deadCandidates: [DeadSessionCandidate],
        deviceList: [DeviceListEntry]
    ) -> (live: [OrphanRecord], dead: [String]) {
        let ownerByUDID = Dictionary(
            uniqueKeysWithValues: deviceList.map { ($0.udid, $0.ownedBySession) }
        )
        let booted = deviceList.filter { $0.state == "Booted" }
        let bootedUDIDs = Set(booted.map(\.udid))
        let nameByUDID = Dictionary(
            uniqueKeysWithValues: booted.map { ($0.udid, $0.name) }
        )
        let deadSessionIds = Set(deadCandidates.map(\.sessionId))

        var udidsBySession: [String: Set<String>] = [:]
        for candidate in deadCandidates {
            for udid in candidate.manifestUDIDs {
                let owner = ownerByUDID[udid].flatMap(\.self)
                if owner == nil || owner == candidate.sessionId {
                    udidsBySession[candidate.sessionId, default: []].insert(udid)
                }
            }
        }
        for entry in booted {
            if let owner = entry.ownedBySession, deadSessionIds.contains(owner) {
                udidsBySession[owner, default: []].insert(entry.udid)
            }
        }

        var liveOrphans: [OrphanRecord] = []
        var emptyDeadDirs: [String] = []
        for candidate in deadCandidates {
            let liveUDIDs = (udidsBySession[candidate.sessionId] ?? [])
                .filter { bootedUDIDs.contains($0) }
                .sorted()
            if liveUDIDs.isEmpty {
                emptyDeadDirs.append(candidate.sessionDir)
            } else {
                let sims = liveUDIDs.map {
                    OrphanLiveSim(udid: $0, displayName: nameByUDID[$0] ?? $0)
                }
                liveOrphans.append(
                    OrphanRecord(
                    sessionId: candidate.sessionId,
                    sessionDir: candidate.sessionDir,
                    liveSims: sims
                )
                    )
            }
        }
        return (liveOrphans, emptyDeadDirs)
    }
}
