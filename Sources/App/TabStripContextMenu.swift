// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabStripContextMenu: the right-click menu for a tab strip cell.
//
// Provides the standard per-tab right-click actions: renaming,
// lifecycle (close / close others / close to the right),
// duplication, privacy toggle, and the automation-tab escape
// hatch. Each item gets an EXPLICIT `target` (the strip VC) rather
// than a nil-targeted responder-chain dispatch. The strip VC is a
// sibling of the focused pane's VC, not an ancestor, so a chain walk
// from a focused terminal / sim pane goes up through the pane's VC
// hierarchy to the window without ever reaching the strip. NSButton
// right-click doesn't promote the button (or its enclosing VC) to
// first responder either, so there's no "force the chain to land
// here" hook the way the per-pane menus get from their content
// view's `menu(for:)` override. Explicit target sidesteps the chain
// entirely. The typed `representedObject = TabID` on each item still
// carries the click target so the handler knows which tab.
//
// Two items are deliberately absent:
//   - "Color Label" submenu: needs persistent per-tab color state
//     on `TabState` and a rendering pass on the strip.
//   - "Move to New Window": `Route.openWindow` does not currently
//     take a `cwd` or carry a tab's identity, so a true "detach to
//     new window" needs new infrastructure (the moved tab's session
//     belongs to its GUI process, so re-parenting is a re-create,
//     not a move).

import AppKit

@MainActor
func makeTabStripContextMenu(
    for tabID: TabID,
    isEffectivelyHidden: Bool,
    isOnlyTab: Bool,
    isLastTab: Bool,
    target: AnyObject? = nil
) -> NSMenu {
    let menu = NSMenu()
    // NSMenu defaults `autoenablesItems = true`, which re-derives each
    // item's enabled state from the responder chain at display time
    // and silently overrides any `item.isEnabled = false` we set here.
    // The strip handlers don't validateMenuItem, so AppKit would
    // re-enable "Close Other Tabs" / "Close Tabs to the Right" even on
    // a single-tab window. Opting out keeps our manual enable bits.
    menu.autoenablesItems = false

    let rename = menuItem(
        title: "Rename Tab…",
        action: #selector(TabStripViewController.renameTabFromMenu(_:)),
        for: tabID,
        target: target
    )
    menu.addItem(rename)

    // Title toggles between "Set Private" and "Set Public" based on what
    // the tab shows right now (effective-hidden, so a tab mid-transition
    // to private already reads "Set Public"); per-tab so the toggle
    // reflects this row.
    let privacy = menuItem(
        title: isEffectivelyHidden ? "Set Public" : "Set Private",
        action: #selector(TabStripViewController.togglePrivacyFromMenu(_:)),
        for: tabID,
        target: target
    )
    privacy.state = isEffectivelyHidden ? .on : .off
    menu.addItem(privacy)

    menu.addItem(.separator())
    menu.addItem(
        menuItem(
            title: "Duplicate Tab",
            action: #selector(TabStripViewController.duplicateTabFromMenu(_:)),
            for: tabID,
            target: target
        )
    )

    menu.addItem(.separator())
    menu.addItem(
        menuItem(
            title: "New Tab",
            action: #selector(TabStripViewController.newTabFromMenu(_:)),
            for: tabID,
            target: target
        )
    )
    menu.addItem(
        menuItem(
            title: "Open Automation Tab",
            action: #selector(TabStripViewController.openAutomationTabFromMenu(_:)),
            for: tabID,
            target: target
        )
    )

    menu.addItem(.separator())
    menu.addItem(
        menuItem(
            title: "Close Tab",
            action: #selector(TabStripViewController.closeTabFromMenu(_:)),
            for: tabID,
            target: target
        )
    )
    // "Close Other Tabs" is a no-op when this is the only tab; AppKit
    // would still dispatch it, so we disable rather than hide so the
    // item is consistently present and discoverable.
    let closeOthers = menuItem(
        title: "Close Other Tabs",
        action: #selector(TabStripViewController.closeOtherTabsFromMenu(_:)),
        for: tabID,
        target: target
    )
    closeOthers.isEnabled = !isOnlyTab
    menu.addItem(closeOthers)
    // "Close Tabs to the Right" needs at least one tab to the right
    // of this one, so a last-tab right-click sees it disabled.
    let closeRight = menuItem(
        title: "Close Tabs to the Right",
        action: #selector(TabStripViewController.closeTabsToRightFromMenu(_:)),
        for: tabID,
        target: target
    )
    closeRight.isEnabled = !isLastTab
    menu.addItem(closeRight)

    return menu
}

@MainActor
private func menuItem(
    title: String,
    action: Selector,
    for tabID: TabID,
    target: AnyObject?
) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.representedObject = tabID
    item.target = target
    return item
}
