// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The right-click menu for a tab strip cell.
///
/// Provides the standard per-tab right-click actions: renaming,
/// lifecycle (close / close others / close to the right),
/// duplication, protection and pin toggles, and the automation-tab
/// escape hatch. Each item gets an EXPLICIT `target` (the strip VC) rather
/// than a nil-targeted responder-chain dispatch. The strip VC is a
/// sibling of the focused pane's VC, not an ancestor, so a chain walk
/// from a focused terminal / sim pane goes up through the pane's VC
/// hierarchy to the window without ever reaching the strip. NSButton
/// right-click doesn't promote the button (or its enclosing VC) to
/// first responder either, so there's no "force the chain to land
/// here" hook the way the per-pane menus get from their content
/// view's `menu(for:)` override. Explicit target sidesteps the chain
/// entirely. The typed `representedObject = TabID` on each item still
/// carries the click target so the handler knows which tab.
///
/// Two items are deliberately absent:
///   - "Color Label" submenu: needs persistent per-tab color state
///     on `TabState` and a rendering pass on the strip.
///   - "Move to New Window": cross-window relocation is available
///     through tab drag and tear-off, which moves the live controller
///     via `TabTransferCoordinating`.
@MainActor
func makeTabStripContextMenu(
    for tabID: TabID,
    isEffectivelyProtected: Bool,
    isPinned: Bool,
    canCloseOthers: Bool,
    canCloseToTheRight: Bool,
    target: AnyObject? = nil
) -> NSMenu {
    let menu = NSMenu()
    // NSMenu defaults `autoenablesItems = true`, which re-derives each
    // item's enabled state from the responder chain at display time
    // and silently overrides any `item.isEnabled = false` we set here.
    // The strip handlers don't validateMenuItem, so AppKit would
    // re-enable "Close Other Tabs" / "Close Tabs to the Right" even
    // when they have nothing to close. Opting out keeps our manual enable bits.
    menu.autoenablesItems = false

    let rename = menuItem(
        title: "Rename Tab…",
        action: #selector(TabStripViewController.renameTabFromMenu(_:)),
        for: tabID,
        target: target
    )
    rename.image = .menuSymbol("pencil", describedAs: "Rename Tab")
    menu.addItem(rename)

    // Title toggles between "Protect Tab" and "Unprotect Tab" based on
    // what the tab shows right now (effective-hidden, so a tab
    // mid-transition to protected already reads "Unprotect Tab"); per-tab
    // so the toggle reflects this row.
    let protection = menuItem(
        title: isEffectivelyProtected ? "Unprotect Tab" : "Protect Tab",
        action: #selector(TabStripViewController.toggleProtectionFromMenu(_:)),
        for: tabID,
        target: target
    )
    protection.state = isEffectivelyProtected ? .on : .off
    // `lock.fill` in both states, matching the pill's marker. The title
    // carries the verb, so the symbol names the subject and stays tied to
    // what the strip shows. The state checkmark sits in its own column to
    // the left, the way AppKit's own menus pair the two.
    protection.image = .menuSymbol("lock.fill", describedAs: "Protected tab")
    menu.addItem(protection)

    // A plain title flip, with no state checkmark: the pill itself shows
    // whether the tab is pinned, since a pinned pill is the compact one.
    let pin = menuItem(
        title: isPinned ? "Unpin Tab" : "Pin Tab",
        action: #selector(TabStripViewController.togglePinFromMenu(_:)),
        for: tabID,
        target: target
    )
    pin.image = .menuSymbol(isPinned ? "pin.slash" : "pin", describedAs: pin.title)
    menu.addItem(pin)

    menu.addItem(.separator())
    let duplicate = menuItem(
        title: "Duplicate Tab",
        action: #selector(TabStripViewController.duplicateTabFromMenu(_:)),
        for: tabID,
        target: target
    )
    duplicate.image = .menuSymbol("plus.square.on.square", describedAs: "Duplicate Tab")
    menu.addItem(duplicate)

    menu.addItem(.separator())
    let newTab = menuItem(
        title: "New Tab",
        action: #selector(TabStripViewController.newTabFromMenu(_:)),
        for: tabID,
        target: target
    )
    // Plain `plus`, the same symbol the strip's own "+" button carries.
    newTab.image = .menuSymbol("plus", describedAs: "New Tab")
    menu.addItem(newTab)
    let automation = menuItem(
        title: "Open Automation Tab",
        action: #selector(TabStripViewController.openAutomationTabFromMenu(_:)),
        for: tabID,
        target: target
    )
    automation.image = .menuSymbol("bolt.fill", describedAs: "Automation tab")
    menu.addItem(automation)

    menu.addItem(.separator())
    // The three close items deliberately share one plain `xmark`. Their
    // titles carry the difference; the repeated glyph is what marks them as
    // one family, which is how AppKit's own tab menus render the same set.
    let closeTab = menuItem(
        title: "Close Tab",
        action: #selector(TabStripViewController.closeTabFromMenu(_:)),
        for: tabID,
        target: target
    )
    closeTab.image = .menuSymbol("xmark", describedAs: "Close Tab")
    menu.addItem(closeTab)
    // "Close Other Tabs" is a no-op when no other unpinned tab exists
    // (`TabBulkCloseTargets`); AppKit would still dispatch it, so we
    // disable rather than hide so the item is consistently present and
    // discoverable.
    let closeOthers = menuItem(
        title: "Close Other Tabs",
        action: #selector(TabStripViewController.closeOtherTabsFromMenu(_:)),
        for: tabID,
        target: target
    )
    closeOthers.isEnabled = canCloseOthers
    closeOthers.image = .menuSymbol("xmark", describedAs: "Close Other Tabs")
    menu.addItem(closeOthers)
    // "Close Tabs to the Right" needs at least one unpinned tab to the
    // right of this one, so a last-tab right-click sees it disabled.
    let closeRight = menuItem(
        title: "Close Tabs to the Right",
        action: #selector(TabStripViewController.closeTabsToRightFromMenu(_:)),
        for: tabID,
        target: target
    )
    closeRight.isEnabled = canCloseToTheRight
    closeRight.image = .menuSymbol("xmark", describedAs: "Close Tabs to the Right")
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
