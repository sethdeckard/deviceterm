// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The right-click menu for a terminal pane.
///
/// Provides Copy, Paste, Clear, Open in New Tab, Split Right, Split
/// Down, and Close Pane. Find is absent because the bridge wires none of
/// libghostty's `GHOSTTY_ACTION_SEARCH_TOTAL` /
/// `GHOSTTY_ACTION_SEARCH_SELECTED` callbacks and there is no search
/// state or search-bar overlay to drive.
///
/// Split semantics: "Split Right" / "Split Down" split **just the
/// right-clicked pane**. "Split Right" adds a sibling along a vertical
/// divider (panes side-by-side); "Split Down" along a horizontal
/// divider (panes stacked). When the chosen axis differs from the
/// pane's parent split, the pane is wrapped in a fresh nested sub-split
/// so splitting one pane never re-orients the rest of the tab (e.g.
/// Split Right then Split Down on the left pane yields a left column
/// divided in two beside a full-height right pane). ⌃⇧D ("Toggle Split
/// Direction") flips the axis of the focused pane's immediate parent
/// split, leaving other panes put.
///
/// Items target nil so AppKit dispatches through the responder chain.
/// The terminal pane VC installs this menu on the libghostty surface
/// view (`surface.view.menu = …`); GhosttySurfaceView's `menu(for:)`
/// override promotes itself to first responder before AppKit reads
/// the menu, so every selector lands on the right
/// TerminalPaneViewController even when right-clicking a backgrounded
/// pane.
///
/// Split out (like `makeSimulatorPaneContextMenu()`) so tests can pin
/// the item structure without instantiating a full pane VC + window.
@MainActor
func makeTerminalPaneContextMenu() -> NSMenu {
    let menu = NSMenu()

    menu.addItem(
        NSMenuItem(
            title: "Copy",
            action: #selector(TerminalPaneViewController.copy(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Paste",
            action: #selector(TerminalPaneViewController.paste(_:)),
            keyEquivalent: ""
        )
    )

    menu.addItem(.separator())
    menu.addItem(
        NSMenuItem(
            title: "Clear",
            action: #selector(TerminalPaneViewController.clearTerminalScreen(_:)),
            keyEquivalent: ""
        )
    )

    menu.addItem(.separator())
    menu.addItem(
        NSMenuItem(
            title: "Open in New Tab",
            action: #selector(TerminalPaneViewController.openCurrentInNewTab(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Split Right",
            action: #selector(TerminalPaneViewController.splitTerminalRight(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Split Down",
            action: #selector(TerminalPaneViewController.splitTerminalDown(_:)),
            keyEquivalent: ""
        )
    )

    menu.addItem(.separator())
    // Mirror a physical device into this tab. Nil target → responder
    // chain → AppDelegate (same action as Shell > Mirror Physical
    // Device…), so there's one picker+attach implementation; the
    // right-clicked pane's window is key, so it targets the right tab.
    menu.addItem(
        NSMenuItem(
            title: "Mirror Physical Device…",
            action: #selector(AppDelegate.mirrorPhysicalDevice(_:)),
            keyEquivalent: ""
        )
    )

    menu.addItem(.separator())
    menu.addItem(
        NSMenuItem(
            title: "Close Pane",
            action: #selector(TerminalPaneViewController.closeTerminalPaneViaMenu(_:)),
            keyEquivalent: ""
        )
    )

    return menu
}
