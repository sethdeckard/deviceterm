// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The programmatic main menu.
///
/// Owns menu structure: which menus exist, in what order, how
/// items are grouped and separated, and which submenus nest where. It
/// does not own shortcuts. Every bound item comes from
/// `KeybindingCatalog.makeMenuItem(_:)`, and items with no shortcut stay
/// plain `NSMenuItem`s.
///
/// The drift guard compares installed menu items with catalog rows by
/// title, chord, selector, tag, and multiplicity. It cannot detect
/// source-level literals.
///
/// Shell owns the surfaces a workspace is made of, Edit owns text, View
/// owns presentation and pane layout, Window owns the window commands
/// plus tab and pane navigation and rearrangement. Device is
/// deviceterm's own and answers to Simulator.app's Device menu.
///
/// Every item targets nil so AppKit resolves it against the key window's
/// responder chain: pane view → pane VC → `PaneLayoutViewController` →
/// `TabContentViewController` → `TabStripViewController` → window →
/// `AppDelegate`. That is why the same New Tab item works with a window
/// focused (reaching the tab strip) and with none (reaching the app
/// delegate's fallback).
@MainActor
func installMainMenu() {
    let menu = makeMainMenu()
    NSApp.mainMenu = menu
    if let window = menu.items.first(where: { $0.submenu?.title == "Window" })?.submenu {
        NSApp.windowsMenu = window
    }
}

/// Construct the main menu without touching `NSApp`. Split out so
/// tests can inspect the menu structure without mutating process
/// global state.
@MainActor
func makeMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(
        NSMenuItem(
        title: "About DeviceTerm",
        action: #selector(AppDelegate.openAbout(_:)),
        keyEquivalent: ""
    )
        )
    appMenu.addItem(.separator())
    appMenu.addItem(
        NSMenuItem(
        title: "Check for Updates…",
        action: #selector(AppDelegate.checkForUpdates(_:)),
        keyEquivalent: ""
    )
        )
    if UpdateSimulator.isEnabled {
        appMenu.addItem(
            NSMenuItem(
            title: "Cycle Update Pill (Debug)",
            action: #selector(AppDelegate.simulateUpdatePill(_:)),
            keyEquivalent: ""
        )
            )
    }
    appMenu.addItem(.separator())
    // Restart Helper… offers to stop the background helper so launchd starts
    // a fresh one; if stopping it leaves recovery able to continue, that
    // reconnects and reattaches device panes. It sits
    // in the app menu because the helper is app-scoped infrastructure, not
    // anything a window or pane owns. Permanent, rather than only offered by
    // the prompt that appears when the helper stops answering: recovery must
    // not depend on that prompt being up at the right moment.
    appMenu.addItem(
        NSMenuItem(
        title: "Restart Helper…",
        action: #selector(AppDelegate.restartHelper(_:)),
        keyEquivalent: ""
    )
        )
    appMenu.addItem(.separator())
    // Settings… opens the config in a new terminal tab running $EDITOR.
    // nil target routes through the responder chain to the AppDelegate,
    // reachable even with no key window, like New Window.
    appMenu.addItem(KeybindingCatalog.makeMenuItem(.openSettings))
    appMenu.addItem(.separator())
    appMenu.addItem(KeybindingCatalog.makeMenuItem(.hideApp))
    appMenu.addItem(KeybindingCatalog.makeMenuItem(.hideOthers))
    appMenu.addItem(.separator())
    appMenu.addItem(KeybindingCatalog.makeMenuItem(.quit))
    appMenuItem.submenu = appMenu

    // Shell menu: everything that creates or destroys one of the
    // surfaces a workspace is made of, meaning windows, tabs, and panes.
    // deviceterm opens and saves no documents, so a File menu would name
    // a concept the app doesn't have.
    let shellMenuItem = NSMenuItem()
    mainMenu.addItem(shellMenuItem)
    let shellMenu = NSMenu(title: "Shell")
    shellMenu.addItem(KeybindingCatalog.makeMenuItem(.newWindow))
    shellMenu.addItem(KeybindingCatalog.makeMenuItem(.newTab))
    // Automation-role minting has no CLI verb, so the menu is the
    // intended product-UI path. Putting it on ⌘⇧T rather than ⌘T
    // discourages accidental automation-tab opens and leaves ⌘T as the
    // muscle-memory default. The daemon backs this up: `session.create`
    // refuses an automation role over UDS, and over XPC only accepts
    // one from a peer whose audit token matches the daemon's signature.
    shellMenu.addItem(KeybindingCatalog.makeMenuItem(.openAutomationTab))
    // Duplicate Tab opens a tab inheriting the source tab's role and
    // working directory. The tab strip's own copy resolves which tab
    // from the clicked item's represented object; a main-menu item
    // carries none, so this names a separate entry point that resolves
    // the selected tab instead.
    shellMenu.addItem(
        NSMenuItem(
            title: "Duplicate Tab",
            action: #selector(TabStripViewController.duplicateSelectedTab(_:)),
            keyEquivalent: ""
        )
    )
    // Split Right / Split Down create a pane the way New Tab creates a
    // tab. Mirror Physical Device… opens the picker that mounts a
    // physically-connected iPhone or iPad as a pane, so it belongs with
    // them rather than in Device, which drives a pane that already
    // exists. It targets AppDelegate and is always enabled.
    shellMenu.addItem(.separator())
    shellMenu.addItem(KeybindingCatalog.makeMenuItem(.splitRight))
    shellMenu.addItem(KeybindingCatalog.makeMenuItem(.splitDown))
    shellMenu.addItem(
        NSMenuItem(
            title: "Mirror Physical Device…",
            action: #selector(AppDelegate.mirrorPhysicalDevice(_:)),
            keyEquivalent: ""
        )
    )
    shellMenu.addItem(.separator())
    // Close Pane sits above Close Tab because it is the narrower of the
    // two, and its title changes to "Close Tab" whenever the focused
    // terminal is the tab's last one. The unconditional Close Tab below
    // it stays put, so tab close is always one item away no matter what
    // ⌘W currently resolves to.
    shellMenu.addItem(KeybindingCatalog.makeMenuItem(.closePane))
    shellMenu.addItem(KeybindingCatalog.makeMenuItem(.closeTab))
    shellMenu.addItem(KeybindingCatalog.makeMenuItem(.closeWindow))
    shellMenuItem.submenu = shellMenu

    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    // Edit menu: standard AppKit editing selectors, so the same items
    // serve a focused terminal pane (which implements them against its
    // libghostty surface) and a focused text field (whose field editor
    // implements them as an `NSText`). Clear Buffer is the one exception,
    // terminal-only with no text-field meaning, so it reads disabled in a
    // sheet. Nothing here falls back to the split: with a device pane
    // focused these are correctly unavailable rather than acting on some
    // other pane.
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(KeybindingCatalog.makeMenuItem(.cut))
    editMenu.addItem(KeybindingCatalog.makeMenuItem(.copy))
    editMenu.addItem(KeybindingCatalog.makeMenuItem(.paste))
    editMenu.addItem(.separator())
    editMenu.addItem(KeybindingCatalog.makeMenuItem(.selectAll))
    editMenu.addItem(KeybindingCatalog.makeMenuItem(.clearBuffer))
    editMenuItem.submenu = editMenu

    // View menu: how big a pane's content renders, and how the tab's
    // panes are arranged. The arrangement selectors target
    // `PaneLayoutViewController`, and AppKit walks the responder chain from
    // whichever pane is first responder up to the split VC, so the
    // actions implicitly target the focused tab's split.
    let viewMenuItem = NSMenuItem()
    mainMenu.addItem(viewMenuItem)
    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(KeybindingCatalog.makeMenuItem(.zoomIn))
    viewMenu.addItem(KeybindingCatalog.makeMenuItem(.zoomOut))
    viewMenu.addItem(KeybindingCatalog.makeMenuItem(.resetZoom))

    // Device-pane size presets, directly under the terminal zoom items:
    // both answer "how big does this pane's content render". Simulator.app
    // puts them in Window, where the sim is the window; here it is a pane.
    // ⌃⌘1 through ⌃⌘4 keeps ⌘1 through ⌘9 free for numbered tabs.
    //
    // These and the AX inspector below are the two device-scoped groups
    // outside the Device menu, and they behave the same way: clicking one
    // with a terminal focused forwards through `PaneLayoutViewController` to
    // the tab's first device pane, while the chord is withheld there and
    // left to the terminal.
    viewMenu.addItem(.separator())
    viewMenu.addItem(KeybindingCatalog.makeMenuItem(.sizePresetPhysical))
    viewMenu.addItem(KeybindingCatalog.makeMenuItem(.sizePresetPointAccurate))
    viewMenu.addItem(KeybindingCatalog.makeMenuItem(.sizePresetPixelAccurate))
    viewMenu.addItem(KeybindingCatalog.makeMenuItem(.sizePresetFitScreen))

    // Reset Pane Layout snaps every split's divider back to natural
    // extents, the same code path the auto-rebalance pass uses on every
    // add and remove. It is a deliberate action with no keyboard
    // shortcut, so muscle memory can't trip it.
    viewMenu.addItem(.separator())
    viewMenu.addItem(KeybindingCatalog.makeMenuItem(.toggleSplitDirection))
    viewMenu.addItem(
        NSMenuItem(
            title: "Reset Pane Layout",
            action: #selector(PaneLayoutViewController.resetPaneLayout(_:)),
            keyEquivalent: ""
        )
    )

    // AX inspector: the chrome ribbon has a button too, and the menu item
    // exposes the same toggle under ⌥⌘A so a power user can flip it
    // without reaching for the mouse. Device-scoped like the presets
    // above; the affordance gate is the separate rule that limits it to
    // panes actually vending an accessibility service.
    viewMenu.addItem(.separator())
    viewMenu.addItem(KeybindingCatalog.makeMenuItem(.toggleAxInspector))

    viewMenu.addItem(.separator())
    viewMenu.addItem(KeybindingCatalog.makeMenuItem(.toggleFullScreen))

    viewMenuItem.submenu = viewMenu

    // Device menu: device controls modeled on Apple's `Simulator.app`
    // Device menu, and the complete surface for driving a pane that
    // already exists. Items target nil so the responder chain resolves
    // them. A focused device pane handles its own action
    // (`SimulatorPaneViewController`), while a focused terminal pane
    // falls through to `PaneLayoutViewController`, which dispatches to the
    // tab's first device pane. The split's `validateUserInterfaceItem`
    // disables the items when the tab has no device panes.
    //
    // That fallback is for menu activation. A device-scoped key
    // equivalent is withheld there instead, so pressing ⌘← with a
    // terminal focused leaves the key to the terminal while clicking
    // Rotate Left reaches the device pane.
    let deviceMenuItem = NSMenuItem()
    mainMenu.addItem(deviceMenuItem)
    let deviceMenu = NSMenu(title: "Device")
    deviceMenu.addItem(KeybindingCatalog.makeMenuItem(.deviceHome))
    // App Switcher is a synthesized swipe-up-and-dwell rather than a
    // hardware button, but it lives with Home as the other "system
    // navigation" action.
    deviceMenu.addItem(
        NSMenuItem(
            title: "App Switcher",
            action: #selector(SimulatorPaneViewController.invokeAppSwitcher(_:)),
            keyEquivalent: ""
        )
    )
    deviceMenu.addItem(KeybindingCatalog.makeMenuItem(.deviceLock))
    deviceMenu.addItem(
        NSMenuItem(
            title: "Side Button",
            action: #selector(SimulatorPaneViewController.pressHardwareSide(_:)),
            keyEquivalent: ""
        )
    )
    deviceMenu.addItem(
        NSMenuItem(
            title: "Siri",
            action: #selector(SimulatorPaneViewController.pressHardwareSiri(_:)),
            keyEquivalent: ""
        )
    )
    deviceMenu.addItem(
        NSMenuItem(
            title: "Apple Pay",
            action: #selector(SimulatorPaneViewController.pressHardwareApplePay(_:)),
            keyEquivalent: ""
        )
    )
    deviceMenu.addItem(.separator())
    deviceMenu.addItem(KeybindingCatalog.makeMenuItem(.deviceRotateLeft))
    deviceMenu.addItem(KeybindingCatalog.makeMenuItem(.deviceRotateRight))
    deviceMenu.addItem(.separator())
    deviceMenu.addItem(
        NSMenuItem(
            title: "Reboot",
            action: #selector(SimulatorPaneViewController.rebootDevice(_:)),
            keyEquivalent: ""
        )
    )
    deviceMenu.addItem(
        NSMenuItem(
            title: "Erase All Content and Settings…",
            action: #selector(SimulatorPaneViewController.eraseAllContent(_:)),
            keyEquivalent: ""
        )
    )
    deviceMenu.addItem(.separator())
    deviceMenu.addItem(KeybindingCatalog.makeMenuItem(.deviceScreenshot))
    // The catalog carries the start-state title; the VC's (and the
    // split's fallback) `validateUserInterfaceItem` toggles it to "Stop
    // Recording" whenever the targeted sim has an active recording.
    deviceMenu.addItem(KeybindingCatalog.makeMenuItem(.deviceRecord))
    // Housekeeping: acts on the device itself rather than on what runs
    // inside it. The pane's right-click menu carries Shut Down and Reveal
    // in Finder too; listing them here as well is what makes this menu
    // the whole device surface rather than a subset with the remainder
    // reachable only by right-clicking. The affordance gate disables all
    // four on a physical-device pane, which has no equivalent for any of
    // them.
    deviceMenu.addItem(.separator())
    deviceMenu.addItem(
        NSMenuItem(
            title: "Install App…",
            action: #selector(SimulatorPaneViewController.installApp(_:)),
            keyEquivalent: ""
        )
    )
    deviceMenu.addItem(
        NSMenuItem(
            title: "Open in Simulator.app",
            action: #selector(SimulatorPaneViewController.openInSimulatorApp(_:)),
            keyEquivalent: ""
        )
    )
    deviceMenu.addItem(
        NSMenuItem(
            title: "Reveal in Finder",
            action: #selector(SimulatorPaneViewController.revealInFinder(_:)),
            keyEquivalent: ""
        )
    )
    deviceMenu.addItem(
        NSMenuItem(
            title: "Shut Down",
            action: #selector(SimulatorPaneViewController.shutDownSim(_:)),
            keyEquivalent: ""
        )
    )

    // Two submenus close the menu, gated at different levels. Location
    // carries an action on its parent item, so the affordance gate greys
    // the whole submenu on a pane with no location support, and its rows
    // are built on open by its delegate. Hardware's parent has no action
    // and no gate; each crown item is validated on its own against the
    // targeted sim being a watch, so on a phone/pad/tv tab the submenu
    // opens with every row disabled. Keeping the crown items in a
    // submenu, rather than scattering them into the top-level Device
    // menu, spares non-watch users a row of controls that never apply to
    // their tabs.
    deviceMenu.addItem(.separator())
    deviceMenu.addItem(makeLocationMenuItem())
    let hardwareMenuItem = NSMenuItem()
    hardwareMenuItem.title = "Hardware"
    let hardwareMenu = NSMenu(title: "Hardware")
    hardwareMenu.addItem(
        NSMenuItem(
            title: "Crown Press",
            action: #selector(SimulatorPaneViewController.pressDigitalCrown(_:)),
            keyEquivalent: ""
        )
    )
    hardwareMenu.addItem(
        NSMenuItem(
            title: "Crown Rotate Up",
            action: #selector(SimulatorPaneViewController.rotateCrownUp(_:)),
            keyEquivalent: ""
        )
    )
    hardwareMenu.addItem(
        NSMenuItem(
            title: "Crown Rotate Down",
            action: #selector(SimulatorPaneViewController.rotateCrownDown(_:)),
            keyEquivalent: ""
        )
    )
    hardwareMenuItem.submenu = hardwareMenu
    deviceMenu.addItem(hardwareMenuItem)

    deviceMenuItem.submenu = deviceMenu

    // Window menu: the standard window commands, then everything that
    // picks or reorders an existing tab or pane. Creating and closing
    // them is Shell's; once they exist, moving between them and moving
    // them around is here, which is why the tab and pane groups sit
    // beside Minimize rather than beside the actions that made them.
    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.minimize))
    windowMenu.addItem(
        NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
    )
    // Rename Tab… opens the same sheet as the tab strip's right-click
    // item, on the selected tab rather than a pointed-at one. See
    // Duplicate Tab above for why that is a separate entry point.
    windowMenu.addItem(
        NSMenuItem(
            title: "Rename Tab…",
            action: #selector(TabStripViewController.renameSelectedTab(_:)),
            keyEquivalent: ""
        )
    )

    // Tab navigation. The selectors reach the focused window's
    // `TabStripViewController` through the responder chain, so each acts
    // on the window the user is looking at. Move Tab Left / Right uses
    // ⌃⇧←/→ so it never collides with the pane ⌘⇧←/→ below.
    windowMenu.addItem(.separator())
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.selectNextTab))
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.selectPreviousTab))
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.moveTabLeft))
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.moveTabRight))

    // Pane navigation and rearrangement, in submenus so the tab groups
    // above and below stay readable. Selecting moves focus; moving
    // swaps a pane with its neighbor. The ⌘[ / ⌘] pair cycles display
    // order so repeated presses reach every pane; the ⌥⌘ arrows move by
    // what the user can see. Both resolve on `PaneLayoutViewController`, so
    // they act on the focused tab's split.
    windowMenu.addItem(.separator())
    let selectPaneMenuItem = NSMenuItem()
    selectPaneMenuItem.title = "Select Pane"
    let selectPaneMenu = NSMenu(title: "Select Pane")
    selectPaneMenu.addItem(KeybindingCatalog.makeMenuItem(.selectPaneAbove))
    selectPaneMenu.addItem(KeybindingCatalog.makeMenuItem(.selectPaneBelow))
    selectPaneMenu.addItem(KeybindingCatalog.makeMenuItem(.selectPaneLeft))
    selectPaneMenu.addItem(KeybindingCatalog.makeMenuItem(.selectPaneRight))
    selectPaneMenu.addItem(.separator())
    selectPaneMenu.addItem(KeybindingCatalog.makeMenuItem(.selectNextPane))
    selectPaneMenu.addItem(KeybindingCatalog.makeMenuItem(.selectPreviousPane))
    selectPaneMenuItem.submenu = selectPaneMenu
    windowMenu.addItem(selectPaneMenuItem)

    let movePaneMenuItem = NSMenuItem()
    movePaneMenuItem.title = "Move Pane"
    let movePaneMenu = NSMenu(title: "Move Pane")
    movePaneMenu.addItem(KeybindingCatalog.makeMenuItem(.movePaneLeft))
    movePaneMenu.addItem(KeybindingCatalog.makeMenuItem(.movePaneRight))
    movePaneMenuItem.submenu = movePaneMenu
    windowMenu.addItem(movePaneMenuItem)

    // Numbered tabs. `makeMenuItem` carries each item's tag, which is how
    // one selector serves all eight.
    windowMenu.addItem(.separator())
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.selectTab1))
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.selectTab2))
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.selectTab3))
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.selectTab4))
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.selectTab5))
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.selectTab6))
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.selectTab7))
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.selectTab8))
    windowMenu.addItem(KeybindingCatalog.makeMenuItem(.selectLastTab))

    // Bring All to Front is last of our own items because AppKit
    // auto-populates a separator plus one item per open window below this
    // point when `NSApp.windowsMenu = windowMenu` is set (see
    // `installMainMenu()`). Anything added after it would be separated
    // from the rest of the menu by that generated list.
    windowMenu.addItem(.separator())
    windowMenu.addItem(
        NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
    )
    windowMenuItem.submenu = windowMenu

    // Help menu: the last top-level menu. Deliberately not set as
    // `NSApp.helpMenu`, because that adds the Spotlight-style Help
    // search field, which makes no sense for a couple of static items.
    //
    // The welcome item is the permanent entry point to the coexistence
    // explanation, which appears automatically only until its id is
    // recorded. The advisory's Learn More… button also reopens it, but
    // that appears only while a sim is attached and Simulator.app is
    // running.
    let helpMenuItem = NSMenuItem()
    mainMenu.addItem(helpMenuItem)
    let helpMenu = NSMenu(title: "Help")
    helpMenu.addItem(
        NSMenuItem(
            title: WelcomeCatalog.simulatorCoexistenceTitle,
            action: #selector(AppDelegate.openSimulatorCoexistenceWelcome(_:)),
            keyEquivalent: ""
        )
    )
    helpMenu.addItem(NSMenuItem.separator())
    helpMenu.addItem(
        NSMenuItem(
            title: "Third-Party Notices",
            action: #selector(AppDelegate.openThirdPartyNotices(_:)),
            keyEquivalent: ""
        )
    )
    helpMenuItem.submenu = helpMenu

    return mainMenu
}
