// SPDX-License-Identifier: GPL-3.0-or-later

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
