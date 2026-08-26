// SPDX-License-Identifier: GPL-3.0-or-later

/// A stable navigation identity for a window, so a Route can name an
/// existing window and the AppKit glue can reconcile its controllers to
/// nav state by id rather than by array position. Allocated
/// monotonically by the Router.
struct WindowID: Hashable, Sendable, Codable, CustomStringConvertible {
    let value: Int
    var description: String { "window#\(value)" }
}
