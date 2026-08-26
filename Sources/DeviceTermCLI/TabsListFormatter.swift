// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Pure-logic formatting for `deviceterm tabs list`
/// and `deviceterm tabs current`.
///
/// Lives separate from main.swift so the row shape is unit-testable
/// without spawning a process or threading env values through.
///
/// Format (per row, no header):
///
///   {marker}\t{short_id}\t{name}\t{session_id}\t{label}
///
/// `marker` is `*` for the caller's current tab (the row whose
/// sessionId equals the caller's `DEVICETERM_SESSION` env) and a literal
/// space character otherwise, git-branch's well-known convention.
/// Five tab-separated columns mean an agent can do `awk -F'\t'
/// '$1=="*" {print $2}'` to extract the current tab's short_id.
///
/// Missing fields encode as the empty string; absent `shortId` (an
/// older daemon that predates the short-id column, e.g. during a
/// Sparkle update window) encodes as `?` so the column count stays
/// stable.
public enum TabsListFormatter {
    /// Placeholder for a missing `shortId` (daemon-version skew). The
    /// column has to stay populated so the row's tab-count is stable
    /// for downstream parsers; `?` reads as "unknown" without being
    /// confusable with a real Crockford base32 id.
    public static let missingShortIdPlaceholder = "?"

    /// Format a single `tabs.list` row. `isCurrent` decides the marker;
    /// the caller supplies it by comparing the entry's `sessionId`
    /// with the caller's `DEVICETERM_SESSION`.
    public static func formatRow(entry: TabsListEntry, isCurrent: Bool) -> String {
        let marker = isCurrent ? "*" : " "
        let shortId = entry.shortId ?? missingShortIdPlaceholder
        let name = entry.name ?? ""
        let label = entry.label ?? ""
        return "\(marker)\t\(shortId)\t\(name)\t\(entry.sessionId)\t\(label)"
    }

    /// Format every row in `entries`, marking the row whose
    /// `sessionId` matches `currentSessionId`. Pass nil for
    /// `currentSessionId` when the caller is outside a tab, so no row
    /// gets the `*` marker.
    public static func formatList(
        entries: [TabsListEntry],
        currentSessionId: String?
    ) -> [String] {
        entries.map { entry in
            formatRow(entry: entry, isCurrent: entry.sessionId == currentSessionId)
        }
    }
}
