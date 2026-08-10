// SPDX-License-Identifier: GPL-3.0-or-later
//
// Stable navigation identities. Windows and tabs are addressed by
// these value ids so a Route can name an existing window/tab and
// the AppKit glue can reconcile its controllers to nav state by id,
// not by array position. Allocated monotonically by the Router.

struct WindowID: Hashable, Sendable, Codable, CustomStringConvertible {
    let value: Int
    var description: String { "window#\(value)" }
}

struct TabID: Hashable, Sendable, Codable, CustomStringConvertible {
    let value: Int
    var description: String { "tab#\(value)" }
}

/// A terminal pane inside a tab. A tab always has at least one
/// terminal pane (the primary, created when the tab opens); additional
/// terminals are added via `Route.openTerminalPane`. Each terminal
/// pane backs its own daemon session, so its identity must survive
/// even when its array position changes.
struct TerminalPaneID: Hashable, Sendable, Codable, CustomStringConvertible {
    let value: Int
    var description: String { "terminal#\(value)" }
}

/// A transient placeholder pane shown while a sim/device attach is in
/// flight (or has failed and is awaiting Retry). A GUI-only concept the
/// daemon never sees: the Router inserts a `.pending` leaf immediately,
/// then swaps it for the real `.sim`/`.device` leaf once `device.attach`
/// / `physicalDevice.attach` returns. Keyed by its own id rather than the
/// target's UDID/deviceId, so the success swap is a leaf identity
/// change and the layout tree stays addressable while the real pane id
/// is still unknown.
struct PendingPaneID: Hashable, Sendable, Codable, CustomStringConvertible {
    let value: Int
    var description: String { "pending#\(value)" }
}
