// SPDX-License-Identifier: GPL-3.0-or-later

/// The stable accessibility identifier each
/// pane's root view carries.
///
/// The out-of-process UI-test harness can read a window's accessibility
/// tree and must verify that pane identity and focus are exposed through
/// AppKit accessibility, independently of the public `pane list` projection.
/// An identifier on each root view makes splits, closes, and focus movement
/// assertable from outside the process.
///
/// The strings are an observability contract with that harness, not
/// user-visible text, so they stay machine-shaped and stable.
enum PaneAccessibilityIdentity {
    /// Shared prefix, so a harness can select every pane node in one
    /// pass without knowing the pane kinds.
    static let prefix = "deviceterm.pane"

    /// The identifier for one pane. The kind is spelled out and the key
    /// is the layout tree's own identity, so a harness can follow one
    /// pane across dumps, and across layout and focus checks, without a
    /// lookup table of its own.
    static func identifier(for slot: PaneSlot) -> String {
        switch slot {
        case let .terminal(id):
            return "\(prefix).terminal.\(id.value)"

        case let .sim(udid):
            return "\(prefix).sim.\(udid)"

        case let .device(deviceId):
            return "\(prefix).device.\(deviceId)"

        case let .pending(id):
            return "\(prefix).pending.\(id.value)"
        }
    }
}
