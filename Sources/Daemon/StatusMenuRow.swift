// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// One sim, formatted for menu display, plus the group header it
/// belongs to. Pure value type so the grouping helper below can be
/// unit-tested without instantiating SessionManager or AppKit menus.
public struct StatusMenuRow: Sendable, Equatable {
    /// The user-facing label for the device, already disambiguated
    /// against duplicate names per `statusMenuEntries`'s rules.
    public let title: String
    public let udid: String
    /// Group header for this row. The status item renders each
    /// distinct value as a disabled section header; rows that share
    /// the same value cluster underneath it. nil signals
    /// "ungrouped", used for orphan sims whose owning session has
    /// been closed.
    public let groupHeader: String?
}
