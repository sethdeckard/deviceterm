// SPDX-License-Identifier: GPL-3.0-or-later
//
// OrphanRecovery: cold-start cleanup of session dirs left behind by
// a GUI that crashed or was force-quit.
//
// Each tab's SessionEnvironment writes owner.pid (= GUI pid) and
// owned-udids.json into ~/Library/Caches/deviceterm/sessions/<id>/.
// At launch we enumerate that tree; any dir whose owner.pid names
// a dead process is a candidate. We intersect its UDIDs with the
// daemon's current `Booted` set (the daemon is the source of truth
// for what's actually running), and only surface UDIDs that are
// both manifest-owned and daemon-Booted as live orphans.
//
// Orphan-recovery decisions:
//   - Re-attach: adopt each udid into the first tab as a sim pane.
//   - Shut Down All: device.shutdown each, delete the dead dir.
//   - Leave Running: leave the dead dir (re-offered next launch).
//
// Candidates with no Booted intersection are cleaned up silently
// (no UX): the manifest references sims that are already gone.
// Live session dirs (alive owner.pid) are never touched; that's
// another running deviceterm GUI process.

import AppKit
import DaemonProtocol

/// One sim that's currently Booted *and* attributable to a dead
/// session (by GUI manifest or by daemon `ownedBySession`).
struct OrphanLiveSim: Sendable, Equatable {
    let udid: String
    let displayName: String
}

struct OrphanRecord: Sendable, Equatable {
    let sessionId: String
    let sessionDir: String
    let liveSims: [OrphanLiveSim]
}

enum OrphanRecoveryChoice: Sendable, Equatable {
    case reattach
    case shutdownAll
    case leaveRunning
}

@MainActor
enum OrphanRecovery {
    /// Read every dead-owner session dir's manifest, then resolve live
    /// orphans against the daemon truth (the pure `OrphanDecision`).
    /// Returns (live-orphan records, dead-with-no-booted-sims dir paths).
    /// Live session dirs (`owner.pid` alive) are filtered out here; the
    /// dir name *is* the sessionId by SessionEnvironment's layout.
    static func collect(deviceList: [DeviceListEntry]) -> (
        live: [OrphanRecord],
        dead: [String]
    ) {
        let cache = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Caches/deviceterm/sessions")
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: cache) else {
            return ([], [])
        }
        var candidates: [DeadSessionCandidate] = []
        for entry in entries {
            let dir = (cache as NSString).appendingPathComponent(entry)
            let markerPath = (dir as NSString).appendingPathComponent("owner.pid")
            if let pidStr = try? String(contentsOfFile: markerPath, encoding: .utf8),
                let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
                kill(pid, 0) == 0 { continue }  // alive: someone else's GUI
            var manifestUDIDs: [String] = []
            let manifestPath = (dir as NSString)
                .appendingPathComponent("owned-udids.json")
            if let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
                let object = try? JSONSerialization.jsonObject(with: data),
                let dict = object as? [String: Any],
                let udids = dict["udids"] as? [String] {
                manifestUDIDs = udids
            }
            candidates.append(
                DeadSessionCandidate(
                sessionId: entry,
                sessionDir: dir,
                manifestUDIDs: manifestUDIDs
            )
                )
        }
        return OrphanDecision.resolve(
            deadCandidates: candidates,
            deviceList: deviceList
        )
    }

    /// Modal sheet summarizing the orphans and offering the three
    /// choices. Runs at cold start before any window is shown, so
    /// `NSAlert.runModal` (app-modal, no parent) is intentional.
    static func runSheet(for records: [OrphanRecord]) -> OrphanRecoveryChoice {
        let allSims = records.flatMap(\.liveSims)
        let lines = allSims.map { "• \($0.displayName)  (\($0.udid))" }
        let alert = NSAlert()
        let count = allSims.count
        let plural = count == 1 ? "" : "s"
        alert.messageText =
            "Previous deviceterm session left \(count) simulator\(plural) running"
        alert.informativeText = lines.joined(separator: "\n")
            + "\n\nRe-attach into a new tab, shut them down, or leave them running?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Re-attach")          // first
        alert.addButton(withTitle: "Shut Down All")      // second
        alert.addButton(withTitle: "Leave Running")      // third
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .reattach

        case .alertSecondButtonReturn:
            return .shutdownAll

        default:
            return .leaveRunning
        }
    }

    /// Remove dead session dirs from disk. Best-effort.
    static func cleanup(_ dirs: [String]) {
        let fileManager = FileManager.default
        for dir in dirs { try? fileManager.removeItem(atPath: dir) }
    }
}
