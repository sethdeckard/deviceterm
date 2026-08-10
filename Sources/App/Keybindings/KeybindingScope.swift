// SPDX-License-Identifier: GPL-3.0-or-later
//
// KeybindingScope: what a shortcut is allowed to act on.
//
// Device-control actions belong to the pane the user is looking at: a
// mixed tab keeps ⌘← and ⌘→ for the focused terminal's cursor rather
// than rotating a sim the user is not looking at.
//
// Scope binds the *keyboard* path only. Clicking Device ▸ Home with a
// terminal focused forwards through the layout controller, which is what
// `DeviceShortcutScopeDecision` separates.

enum KeybindingScope: Equatable, Sendable {
    /// Uses normal responder-chain availability, with no additional
    /// device-focus restriction. The default for everything that is not a
    /// device control.
    case app
    /// Reaches the device pane only when that pane holds focus.
    case devicePane
}
