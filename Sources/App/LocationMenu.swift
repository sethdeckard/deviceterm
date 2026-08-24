// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// A Location submenu that owns its own delegate.
///
/// `NSMenu.delegate` is weak, and these menus are built by free
/// functions (`makeMainMenu`, `makeSimulatorPaneContextMenu`) with no
/// long-lived object to park a controller on. Holding it here ties the
/// controller's lifetime to the menu's exactly, which is what it should
/// be, and keeps callers from having to thread an owner through.
@MainActor
final class LocationMenu: NSMenu {
    private let controller: LocationMenuController

    init(resolve: @escaping @MainActor () -> SimulatorPaneViewController?) {
        controller = LocationMenuController(resolve: resolve)
        super.init(title: LocationMenuController.menuTitle)
        delegate = controller
    }

    /// Unarchiving path. This menu is normally built in code, but
    /// `NSMenu` requires an unarchiving initializer, and a trap here
    /// would be a termination point in library code, which the house
    /// rules reserve for `main.swift` and `AppDelegate`. Falling back to
    /// the default responder-chain resolver is the behavior a decoded
    /// copy should have anyway, so this stays a working menu.
    required init(coder: NSCoder) {
        controller = LocationMenuController(resolve: LocationMenuController.responderChainPane)
        super.init(coder: coder)
        delegate = controller
    }
}
