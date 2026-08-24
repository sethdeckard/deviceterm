// SPDX-License-Identifier: GPL-3.0-or-later

/// A terminal pane inside a tab. A tab always has at least one
/// terminal pane (the primary, created when the tab opens); additional
/// terminals are added via `Route.openTerminalPane`. Each terminal
/// pane backs its own daemon session, so its identity must survive
/// even when its array position changes.
struct TerminalPaneID: Hashable, Sendable, Codable, CustomStringConvertible {
    let value: Int
    var description: String { "terminal#\(value)" }
}
