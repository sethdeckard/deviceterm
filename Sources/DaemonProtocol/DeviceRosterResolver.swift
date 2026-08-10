// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceRosterResolver: pure `device attach <ref>` resolution.
//
// Resolves a user-supplied `<ref>` against the `devices.list` roster,
// the aggregate of booted sims + connected physical devices, attached
// or not. This is deliberately distinct from `PaneRefResolver`, which
// matches *attached panes* (by shortId / name / key): `device attach`
// can target a device that has no pane yet (an orphan sim, an
// unattached physical device), so it resolves the roster, not the pane
// list. Lives in DaemonProtocol so the CLI and any future daemon-side
// resolver share one matcher. No I/O; the caller fetches the roster.

import Foundation

public enum DeviceRosterResolver {
    public enum Resolution: Equatable, Sendable {
        case entry(DeviceRosterEntry)
        case notFound
        case ambiguous([DeviceRosterEntry])
    }

    /// Resolve `ref` against `entries`. Priority: id (a sim UDID or a
    /// physical deviceId), case-insensitively → name; ambiguity
    /// surfaces within a tier only. The roster carries no shortId, so
    /// there is no shortId tier (unlike `PaneRefResolver`).
    public static func resolve(
        _ ref: String,
        in entries: [DeviceRosterEntry]
    ) -> Resolution {
        let lowered = ref.lowercased()
        let idMatches = entries.filter { $0.id.lowercased() == lowered }
        if let single = uniqueOrAmbiguous(idMatches) {
            return single
        }

        let nameMatches = entries.filter { $0.name == ref }
        if let single = uniqueOrAmbiguous(nameMatches) {
            return single
        }

        return .notFound
    }

    private static func uniqueOrAmbiguous(_ hits: [DeviceRosterEntry]) -> Resolution? {
        switch hits.count {
        case 0:
            return nil

        case 1:
            return .entry(hits[0])

        default:
            return .ambiguous(hits)
        }
    }
}
