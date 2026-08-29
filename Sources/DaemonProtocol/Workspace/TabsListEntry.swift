// SPDX-License-Identifier: GPL-3.0-or-later

/// One entry of the bare-array `tabs.list` result.
/// Mirrors `SessionMethods.TabsListEntry`.
///
/// `sessionId` identifies one daemon session. Required `tabId` is its grouping
/// UUID. GUI terminal sessions in one tab share their tab UUID; a non-GUI
/// session self-groups under `sessionId`. Consumers group rows by `tabId`.
/// A GUI-backed group's `tabId` may be passed directly to `--tab <ref>`.
/// `shortId` and `name` remain optional convenience identifiers used by the
/// tiered resolver.
///
/// `displayTitle` is the GUI's live tab label in the optional, bounded,
/// normalized form that crosses the wire: the shell's OSC 0/2 title, a
/// manual rename, or whatever else won the GUI's title precedence. It is
/// not an identifier and never resolves a `--tab <ref>`, since it changes
/// as often as the shell redraws its prompt. Consumers fall back to
/// `name` whenever it is nil, which it is when no GUI has pushed one (the
/// daemon holds titles in memory only, so also after a daemon restart
/// until the GUI republishes), when the label would say nothing `name`
/// does not already (the label IS the name, or it is the GUI's generic
/// fallback for a tab with no name, no title and no known directory), and
/// for the non-primary terminals of a split tab, whose title publishes
/// under the primary terminal's session.
public struct TabsListEntry: Codable, Sendable, Equatable {
    public let sessionId: String
    public let tabId: String
    public let shortId: String?
    public let name: String?
    public let displayTitle: String?
    public let label: String?

    public init(
        sessionId: String,
        label: String?,
        tabId: String? = nil,
        shortId: String? = nil,
        name: String? = nil,
        displayTitle: String? = nil
    ) {
        self.sessionId = sessionId
        self.tabId = tabId ?? sessionId
        self.shortId = shortId
        self.name = name
        self.displayTitle = displayTitle
        self.label = label
    }
}
