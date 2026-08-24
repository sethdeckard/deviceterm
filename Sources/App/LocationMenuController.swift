// SPDX-License-Identifier: GPL-3.0-or-later
//
// LocationMenuController: turns `LocationMenuModel` rows into the live
// Device ▸ Location submenu.
//
// One implementation serves both surfaces that show the submenu (the
// main menu and a pane's right-click menu); which pane it acts on comes
// from an injected `resolve` closure, so neither surface needs its own
// copy of the rule and tests can drive it with a stub pane.
//
// `menuNeedsUpdate` builds rows from the view model's **current
// snapshot** and does no I/O: a menu that had to await the daemon
// before drawing would stutter on every open, and a menu that could
// throw would be worse than one showing a slightly stale checkmark. A
// later open uses the refresh it kicks off, once that completes.

import AppKit

@MainActor
final class LocationMenuController: NSObject, NSMenuDelegate {
    /// Title of the parent item and its submenu.
    static let menuTitle = "Location"
    /// Shown when the daemon refuses this surface. See
    /// `PaneLocationViewModel.isAvailable`.
    static let unavailableTitle = "Location Unavailable"

    private let resolve: @MainActor () -> SimulatorPaneViewController?

    /// `nonisolated` so `LocationMenu`'s unarchiving initializer, which
    /// AppKit declares outside the main actor, can construct one. It only
    /// stores the closure; every use of `resolve` is main-actor isolated.
    nonisolated init(resolve: @escaping @MainActor () -> SimulatorPaneViewController?) {
        self.resolve = resolve
    }

    /// The pane a Location submenu acts on when no explicit resolver is
    /// supplied: the same one the Device menu's other items reach.
    ///
    /// Walks the key window's responder chain, exactly how every
    /// nil-targeted Device-menu action is dispatched, so the submenu can
    /// never act on a different pane than the Rotate items beside it. A
    /// focused sim pane wins; otherwise the enclosing layout controller
    /// picks the tab's targeted pane, which keeps the menu working while
    /// a *terminal* pane holds focus.
    static func responderChainPane() -> SimulatorPaneViewController? {
        var responder: NSResponder? = NSApp.keyWindow?.firstResponder
        while let next = responder {
            if let simPane = next as? SimulatorPaneViewController { return simPane }
            if let layout = next as? PaneLayoutViewController { return layout.targetedSimPane() }
            responder = next.nextResponder
        }
        return nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let pane = resolve() else {
            menu.addItem(disabledItem(titled: LocationMenuModel.clearedTitle))
            return
        }
        let viewModel = pane.locationViewModel
        guard viewModel.isAvailable else {
            menu.addItem(disabledItem(titled: Self.unavailableTitle))
            return
        }
        let rows = LocationMenuModel.rows(
            for: viewModel.state,
            saved: viewModel.savedLocations,
            activeRoutePath: viewModel.activeRoutePath
        )
        for row in rows {
            menu.addItem(item(for: row))
        }
        // Prime the snapshot for the *next* open. Deliberately after the
        // rows are built: this is asynchronous, so it cannot affect the
        // menu being drawn right now, and pretending otherwise would
        // invite a race that only shows up on a slow daemon.
        viewModel.refresh()
    }

    /// `internal` (not `private`): the keybinding drift guard renders every
    /// row shape through this to assert none of them carries a key
    /// equivalent. Direct rendering covers every row case without depending
    /// on a live pane and its current model.
    func item(for row: LocationMenuRow) -> NSMenuItem {
        switch row {
        case .separator:
            return .separator()

        case let .header(title):
            // No action, so AppKit's automatic enabling greys it out,
            // making it a section label rather than a control.
            return disabledItem(titled: title)

        case let .location(title, location, isActive):
            let item = NSMenuItem(
                title: title,
                action: #selector(SimulatorPaneViewController.applySimulatedLocation(_:)),
                keyEquivalent: ""
            )
            // `target` stays nil so the click dispatches through the
            // responder chain like every other Device-menu action,
            // which is what lets the menu work while a terminal pane
            // holds focus (the `+DeviceMenu` forwarder catches it).
            item.representedObject = location
            item.state = isActive ? .on : .off
            return item

        case let .route(title, path, isActive):
            let item = NSMenuItem(
                title: title,
                action: #selector(SimulatorPaneViewController.applyRouteFile(_:)),
                keyEquivalent: ""
            )
            // The path, not a `SimulatedLocation`: the waypoints are in
            // the file, and opening it is the click's job rather than
            // the menu's. Same nil-target dispatch as the other rows.
            item.representedObject = path
            item.state = isActive ? .on : .off
            // The row's title may be a label the user chose, so the
            // tooltip is the only place the actual file is visible.
            item.toolTip = path
            return item

        case .useMyLocation:
            // Same nil-target dispatch as the location rows.
            return NSMenuItem(
                title: LocationMenuModel.useMyLocationTitle,
                action: #selector(SimulatorPaneViewController.useMyLocation(_:)),
                keyEquivalent: ""
            )

        case .customCoordinates:
            // Same nil-target dispatch as the location rows, so the
            // sheet opens on whichever pane the rest of the submenu is
            // acting on.
            return NSMenuItem(
                title: LocationMenuModel.customTitle,
                action: #selector(SimulatorPaneViewController.showCustomCoordinates(_:)),
                keyEquivalent: ""
            )
        }
    }

    private func disabledItem(titled title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// The `Location` item plus its dynamic submenu, shared by the Device
/// menu and the pane's right-click menu so the two can't drift.
///
/// The item carries `applySimulatedLocation` as its action even though
/// AppKit never sends it (an item owning a submenu opens the submenu
/// instead). The action is what routes the item through
/// `validateUserInterfaceItem`, so a pane whose device reports no
/// location support greys the whole submenu out rather than offering
/// rows that would fail.
@MainActor
func makeLocationMenuItem(
    resolve: @escaping @MainActor () -> SimulatorPaneViewController? = LocationMenuController.responderChainPane
) -> NSMenuItem {
    let item = NSMenuItem(
        title: LocationMenuController.menuTitle,
        action: #selector(SimulatorPaneViewController.applySimulatedLocation(_:)),
        keyEquivalent: ""
    )
    item.submenu = LocationMenu(resolve: resolve)
    return item
}
