// SPDX-License-Identifier: GPL-3.0-or-later
//
// KeybindingEntry: one row of the keybinding catalog, describing what
// the action is, what you press, what the menu says, and which selector
// the responder chain dispatches.
//
// Entries carry AppKit-only `Selector` and `AnyClass` metadata, neither
// of which is `Sendable`, so the catalog is main-actor isolated. The
// pure half of the layer (`KeyChord`, `KeyModifiers`,
// `KeybindingAction`, `KeybindingScope`) stays `Sendable` and actor-free.
// This mirrors the shape `PaneControlAffordance` already uses.

import AppKit

@MainActor
struct KeybindingEntry {
    let action: KeybindingAction
    let chord: KeyChord
    /// The menu item's title.
    let title: String
    let selector: Selector
    /// Classes expected to handle `selector`, including any responder-chain
    /// fallbacks. The drift guard verifies each one implements it, catching a
    /// selector rename or a missing implementation on a declared responder.
    let responders: [AnyClass]
    /// `NSMenuItem.tag`, read by index-driven selectors that share one
    /// selector across many items. Zero when unused.
    let tag: Int
    /// What the shortcut may act on. Read by the layout controller's
    /// validator to keep a device chord from reaching a pane the user is
    /// not looking at.
    let scope: KeybindingScope

    init(
        action: KeybindingAction,
        chord: KeyChord,
        title: String,
        selector: Selector,
        responders: [AnyClass],
        tag: Int = 0,
        scope: KeybindingScope = .app
    ) {
        self.action = action
        self.chord = chord
        self.title = title
        self.selector = selector
        self.responders = responders
        self.tag = tag
        self.scope = scope
    }
}
