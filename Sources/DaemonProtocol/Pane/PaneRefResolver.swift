// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneRefResolver: pure-logic `--pane <ref>` resolution.
//
// Same shape as `TabRefResolver` but matches against `PanesListEntry`
// instead of `TabsListEntry`. Lives in DaemonProtocol so the CLI and
// any future daemon-side resolver share the same matcher. No I/O; the
// caller fetches `panes.list` and hands the entries in.

import Foundation

public enum PaneRefResolver {
    public enum Resolution: Equatable, Sendable {
        case entry(PanesListEntry)
        case sentinel(PaneRef.Sentinel)
        case notFound
        case ambiguous([PanesListEntry])
    }

    /// Minimum length of a UUID-prefix match, same rationale as
    /// `TabRefResolver.minUUIDPrefixLength`.
    public static let minUUIDPrefixLength = 4

    /// Resolve `ref` against `entries`. Priority: short_id → name →
    /// device key (a sim UDID or a physical deviceId) → UUID prefix →
    /// sentinel; ambiguity surfaces within a tier only.
    public static func resolve(
        _ ref: String,
        in entries: [PanesListEntry]
    ) -> Resolution {
        let shortIdMatches = entries.filter { $0.shortId == ref }
        if let single = uniqueOrAmbiguous(shortIdMatches) {
            return single
        }

        let nameMatches = entries.filter { $0.name == ref }
        if let single = uniqueOrAmbiguous(nameMatches) {
            return single
        }

        // Device-identity exact match. The `udid` column carries each
        // pane's `target.key` (a sim's UDID *or* a physical device's
        // deviceId), so one case-insensitive exact compare resolves
        // both `--pane <udid>` and `--pane <deviceId>`. Exact, never a
        // prefix: a 4-char fragment of a UDID falls through to the
        // paneId-prefix tier below, exactly as before this tier landed.
        let loweredRef = ref.lowercased()
        let keyMatches = entries.filter { $0.udid.lowercased() == loweredRef }
        if let single = uniqueOrAmbiguous(keyMatches) {
            return single
        }

        if ref.count >= minUUIDPrefixLength {
            let uuidMatches = entries.filter {
                $0.paneId.lowercased().hasPrefix(loweredRef)
            }
            if let single = uniqueOrAmbiguous(uuidMatches) {
                return single
            }
        }

        if let sentinel = PaneRef.Sentinel(rawValue: ref) {
            return .sentinel(sentinel)
        }

        return .notFound
    }

    /// Exact device-key lookup, bypassing the tiered `resolve` order.
    /// Matches only the `udid` column (a sim UDID or a physical
    /// deviceId), case-insensitively. Used for the
    /// `DEVICETERM_TARGET_PANE` env fallback, which exports a *canonical*
    /// key: a same-valued shortId/name on another pane must not shadow
    /// the exported target the way the tiered `resolve` would. Returns
    /// the first match (a tab never holds two panes with the same key).
    public static func exactKeyMatch(
        _ key: String,
        in entries: [PanesListEntry]
    ) -> PanesListEntry? {
        let lowered = key.lowercased()
        return entries.first { $0.udid.lowercased() == lowered }
    }

    private static func uniqueOrAmbiguous(_ hits: [PanesListEntry]) -> Resolution? {
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
