// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneAccessibilityIdentity: the stable accessibility identifier each
// pane's root view carries.
//
// The out-of-process UI-test harness can read a window's accessibility
// tree but has no other way to ask "how many panes does this tab hold"
// or "which one has focus". Pane identity lives entirely in nav state,
// which the harness cannot see. `panes list` enumerates device panes
// only; terminal panes are sessions and never appear there. An
// identifier on the pane's root view is what makes splits, closes, and
// focus movement assertable from outside.
//
// The strings are an observability contract with that harness, not
// user-visible text, so they stay machine-shaped and stable.

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
