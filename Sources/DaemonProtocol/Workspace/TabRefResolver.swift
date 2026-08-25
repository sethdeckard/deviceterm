// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabRefResolver: pure-logic `--tab <ref>` resolution.
//
// Walks the documented priority (short_id → name → UUID prefix →
// sentinel) and returns the most-specific match. Lives in
// DaemonProtocol so both the CLI (consuming `tabs.list`) and any
// future daemon-side resolver share the same matcher. No I/O, no
// optionals on the entry list shape: the caller fetches the list and
// hands it in.

import Foundation

public enum TabRefResolver {
    public enum Resolution: Equatable, Sendable {
        case entry(TabsListEntry)
        case sentinel(TabRef.Sentinel)
        case notFound
        case ambiguous([TabsListEntry])
    }

    /// Minimum length of a UUID-prefix match. Anything shorter is too
    /// noisy (3 chars × 16-char hex space hits collisions fast) and
    /// can mask a short_id / name match the user actually meant. 4
    /// hex chars = 65k space; combined with the per-session list size
    /// (single digits in practice) the false-positive rate is
    /// effectively zero.
    public static let minUUIDPrefixLength = 4

    /// Resolve `ref` against `entries`. Returns the first non-empty
    /// match in priority order; ambiguity only surfaces within a
    /// single tier (e.g. two tabs with the same name), not across
    /// tiers (a short_id match wins over an ambiguous-name tier).
    public static func resolve(
        _ ref: String,
        in entries: [TabsListEntry]
    ) -> Resolution {
        // Tier 1: exact short_id match (case-sensitive, since the daemon emits
        // lowercased Crockford). At most one match by construction
        // (collision-retry mint enforces per-container uniqueness),
        // but we still surface `.ambiguous` if the list is malformed.
        let shortIdMatches = entries.filter { $0.shortId == ref }
        if let single = uniqueOrAmbiguous(shortIdMatches) {
            return single
        }

        // Tier 2: exact name match. Case-sensitive; names are
        // user-provided and case can be load-bearing.
        let nameMatches = entries.filter { $0.name == ref }
        if let single = uniqueOrAmbiguous(nameMatches) {
            return single
        }

        // Tier 3: UUID prefix match (case-insensitive). Requires
        // `minUUIDPrefixLength` chars to avoid noise on short inputs.
        if ref.count >= minUUIDPrefixLength {
            let lowered = ref.lowercased()
            let uuidMatches = entries.filter {
                $0.sessionId.lowercased().hasPrefix(lowered)
            }
            if let single = uniqueOrAmbiguous(uuidMatches) {
                return single
            }
        }

        // Tier 4: reserved sentinel keyword. Lowest priority so a
        // literal tab named `current` shadows the sentinel, which is rare but
        // self-inflicted.
        if let sentinel = TabRef.Sentinel(rawValue: ref) {
            return .sentinel(sentinel)
        }

        return .notFound
    }

    /// Translate a tier's hit list into a `Resolution`. Returns:
    ///   - `.entry` when exactly one match (the happy path).
    ///   - `.ambiguous` when multiple hits; the caller surfaces the
    ///     conflict instead of guessing.
    ///   - `nil` when empty, letting `resolve` fall through to the
    ///     next tier.
    private static func uniqueOrAmbiguous(_ hits: [TabsListEntry]) -> Resolution? {
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
