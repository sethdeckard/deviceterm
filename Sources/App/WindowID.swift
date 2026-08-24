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
