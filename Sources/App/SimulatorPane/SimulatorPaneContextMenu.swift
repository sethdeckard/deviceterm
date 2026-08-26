// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The right-click menu for a sim pane.
/// Mirrors Apple's Simulator.app pattern of putting hardware controls
/// + housekeeping actions a right-click away, so the user doesn't have
/// to roundtrip to the menu bar for routine sim operations.
///
/// Items target nil so AppKit dispatches through the responder chain
/// Right-clicking on the sim pane makes its content view the
/// momentary first responder, so `SimulatorPaneViewController` (the
/// content view's enclosing VC) handles every selector. It reuses the
/// @objc methods the Device menu already targets, plus Mirror Physical
/// Device… from Shell. Close Pane is the one item with no main-menu
/// twin: ⌘W names `closeFocusedPaneOrTab` on the layout controller,
/// which resolves what to close, where this item always closes the pane
/// the user right-clicked.
///
/// Split out (like `makeMainMenu()`) so tests can inspect the menu
/// structure without instantiating a full pane VC + window.
@MainActor
func makeSimulatorPaneContextMenu() -> NSMenu {
    let menu = NSMenu()

    // Hardware buttons, the same group as Device > Home/Lock/Side/Siri/
    // Apple Pay. Repeating here so the right-click hits the common
    // case without bouncing to the menu bar.
    menu.addItem(
        NSMenuItem(
            title: "Home",
            action: #selector(SimulatorPaneViewController.pressHardwareHome(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Lock",
            action: #selector(SimulatorPaneViewController.pressHardwareLock(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Side Button",
            action: #selector(SimulatorPaneViewController.pressHardwareSide(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Siri",
            action: #selector(SimulatorPaneViewController.pressHardwareSiri(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Apple Pay",
            action: #selector(SimulatorPaneViewController.pressHardwareApplePay(_:)),
            keyEquivalent: ""
        )
    )

    menu.addItem(.separator())
    // Watch-only inputs. The VC's `validateUserInterfaceItem` gates
    // these on the sim being a watch, so a right-click on a phone /
    // pad / tv pane sees them disabled rather than acting on a
    // device that has no Digital Crown.
    menu.addItem(
        NSMenuItem(
            title: "Crown Press",
            action: #selector(SimulatorPaneViewController.pressDigitalCrown(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Crown Rotate Up",
            action: #selector(SimulatorPaneViewController.rotateCrownUp(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Crown Rotate Down",
            action: #selector(SimulatorPaneViewController.rotateCrownDown(_:)),
            keyEquivalent: ""
        )
    )

    menu.addItem(.separator())
    menu.addItem(
        NSMenuItem(
            title: "Rotate Left",
            action: #selector(SimulatorPaneViewController.rotateDeviceLeft(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Rotate Right",
            action: #selector(SimulatorPaneViewController.rotateDeviceRight(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(makeLocationMenuItem())

    menu.addItem(.separator())
    menu.addItem(
        NSMenuItem(
            title: "Reboot",
            action: #selector(SimulatorPaneViewController.rebootDevice(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Shut Down",
            action: #selector(SimulatorPaneViewController.shutDownSim(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Erase All Content and Settings…",
            action: #selector(SimulatorPaneViewController.eraseAllContent(_:)),
            keyEquivalent: ""
        )
    )

    menu.addItem(.separator())
    menu.addItem(
        NSMenuItem(
            title: "Screenshot",
            action: #selector(SimulatorPaneViewController.screenshotPane(_:)),
            keyEquivalent: ""
        )
    )
    // Title-toggles to "Stop Recording" via the VC's
    // validateUserInterfaceItem when a recording is active.
    menu.addItem(
        NSMenuItem(
            title: "Record Screen",
            action: #selector(SimulatorPaneViewController.recordPane(_:)),
            keyEquivalent: ""
        )
    )

    menu.addItem(.separator())
    menu.addItem(
        NSMenuItem(
            title: "Open in Simulator.app",
            action: #selector(SimulatorPaneViewController.openInSimulatorApp(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(
        NSMenuItem(
            title: "Reveal in Finder",
            action: #selector(SimulatorPaneViewController.revealInFinder(_:)),
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
            action: #selector(SimulatorPaneViewController.closePane(_:)),
            keyEquivalent: ""
        )
    )

    return menu
}
