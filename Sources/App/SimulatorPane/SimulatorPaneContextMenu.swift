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
    let iHome = NSMenuItem(
        title: "Home",
        action: #selector(SimulatorPaneViewController.pressHardwareHome(_:)),
        keyEquivalent: ""
    )
    iHome.image = .menuSymbol("house.fill", describedAs: "Home")
    KeybindingCatalog.applyChord(.deviceHome, to: iHome)
    menu.addItem(iHome)
    // Sits with Home as the other system-navigation action, matching the
    // Device menu's order. Not a hardware button: a synthesized edge swipe.
    let iAppSwitcher = NSMenuItem(
        title: "App Switcher",
        action: #selector(SimulatorPaneViewController.invokeAppSwitcher(_:)),
        keyEquivalent: ""
    )
    iAppSwitcher.image = .menuSymbol(
        SimChromeAction.appSwitcherSymbol,
        describedAs: "App Switcher"
    )
    menu.addItem(iAppSwitcher)
    let iLock = NSMenuItem(
        title: "Lock",
        action: #selector(SimulatorPaneViewController.pressHardwareLock(_:)),
        keyEquivalent: ""
    )
    iLock.image = .menuSymbol("lock.iphone", describedAs: "Lock")
    KeybindingCatalog.applyChord(.deviceLock, to: iLock)
    menu.addItem(iLock)
    let iSideButton = NSMenuItem(
        title: "Side Button",
        action: #selector(SimulatorPaneViewController.pressHardwareSide(_:)),
        keyEquivalent: ""
    )
    iSideButton.image = .menuSymbol("button.horizontal.top.press", describedAs: "Side Button")
    menu.addItem(iSideButton)
    let iSiri = NSMenuItem(
        title: "Siri",
        action: #selector(SimulatorPaneViewController.pressHardwareSiri(_:)),
        keyEquivalent: ""
    )
    iSiri.image = .menuSymbol("siri", describedAs: "Siri", fallback: "waveform")
    menu.addItem(iSiri)
    let iApplePay = NSMenuItem(
        title: "Apple Pay",
        action: #selector(SimulatorPaneViewController.pressHardwareApplePay(_:)),
        keyEquivalent: ""
    )
    iApplePay.image = .menuSymbol("creditcard", describedAs: "Apple Pay")
    menu.addItem(iApplePay)

    menu.addItem(.separator())
    // Watch-only inputs. The VC's `validateUserInterfaceItem` gates
    // these on the sim being a watch, so a right-click on a phone /
    // pad / tv pane sees them disabled rather than acting on a
    // device that has no Digital Crown.
    let iCrownPress = NSMenuItem(
        title: "Crown Press",
        action: #selector(SimulatorPaneViewController.pressDigitalCrown(_:)),
        keyEquivalent: ""
    )
    iCrownPress.image = .menuSymbol("digitalcrown.press", describedAs: "Crown Press")
    menu.addItem(iCrownPress)
    let iCrownRotateUp = NSMenuItem(
        title: "Crown Rotate Up",
        action: #selector(SimulatorPaneViewController.rotateCrownUp(_:)),
        keyEquivalent: ""
    )
    iCrownRotateUp.image = .menuSymbol("digitalcrown.arrow.clockwise", describedAs: "Crown Rotate Up")
    menu.addItem(iCrownRotateUp)
    let iCrownRotateDown = NSMenuItem(
        title: "Crown Rotate Down",
        action: #selector(SimulatorPaneViewController.rotateCrownDown(_:)),
        keyEquivalent: ""
    )
    iCrownRotateDown.image = .menuSymbol("digitalcrown.arrow.counterclockwise", describedAs: "Crown Rotate Down")
    menu.addItem(iCrownRotateDown)

    menu.addItem(.separator())
    let iRotateLeft = NSMenuItem(
        title: "Rotate Left",
        action: #selector(SimulatorPaneViewController.rotateDeviceLeft(_:)),
        keyEquivalent: ""
    )
    iRotateLeft.image = .menuSymbol("rotate.left", describedAs: "Rotate Left")
    KeybindingCatalog.applyChord(.deviceRotateLeft, to: iRotateLeft)
    menu.addItem(iRotateLeft)
    let iRotateRight = NSMenuItem(
        title: "Rotate Right",
        action: #selector(SimulatorPaneViewController.rotateDeviceRight(_:)),
        keyEquivalent: ""
    )
    iRotateRight.image = .menuSymbol("rotate.right", describedAs: "Rotate Right")
    KeybindingCatalog.applyChord(.deviceRotateRight, to: iRotateRight)
    menu.addItem(iRotateRight)
    menu.addItem(makeLocationMenuItem())

    menu.addItem(.separator())
    let iReboot = NSMenuItem(
        title: "Reboot",
        action: #selector(SimulatorPaneViewController.rebootDevice(_:)),
        keyEquivalent: ""
    )
    iReboot.image = .menuSymbol("restart", describedAs: "Reboot")
    menu.addItem(iReboot)
    let iShutDown = NSMenuItem(
        title: "Shut Down",
        action: #selector(SimulatorPaneViewController.shutDownSim(_:)),
        keyEquivalent: ""
    )
    iShutDown.image = .menuSymbol("power", describedAs: "Shut Down")
    menu.addItem(iShutDown)
    let iEraseAllContentandSettings = NSMenuItem(
        title: "Erase All Content and Settings…",
        action: #selector(SimulatorPaneViewController.eraseAllContent(_:)),
        keyEquivalent: ""
    )
    iEraseAllContentandSettings.image = .menuSymbol("trash", describedAs: "Erase All Content and Settings")
    menu.addItem(iEraseAllContentandSettings)

    menu.addItem(.separator())
    let iScreenshot = NSMenuItem(
        title: "Screenshot",
        action: #selector(SimulatorPaneViewController.screenshotPane(_:)),
        keyEquivalent: ""
    )
    iScreenshot.image = .menuSymbol("camera", describedAs: "Screenshot")
    KeybindingCatalog.applyChord(.deviceScreenshot, to: iScreenshot)
    menu.addItem(iScreenshot)
    // Title-toggles to "Stop Recording" via the VC's
    // validateUserInterfaceItem when a recording is active.
    let iRecordScreen = NSMenuItem(
        title: "Record Screen",
        action: #selector(SimulatorPaneViewController.recordPane(_:)),
        keyEquivalent: ""
    )
    iRecordScreen.image = .menuSymbol("record.circle", describedAs: "Record Screen")
    KeybindingCatalog.applyChord(.deviceRecord, to: iRecordScreen)
    menu.addItem(iRecordScreen)
    // Expose AX inspection alongside the other ribbon actions in the
    // context menu.
    let iToggleAXInspector = NSMenuItem(
        title: "Toggle AX Inspector",
        action: #selector(SimulatorPaneViewController.toggleAxInspector(_:)),
        keyEquivalent: ""
    )
    iToggleAXInspector.image = .menuSymbol("accessibility", describedAs: "Toggle AX Inspector")
    KeybindingCatalog.applyChord(.toggleAxInspector, to: iToggleAXInspector)
    menu.addItem(iToggleAXInspector)

    menu.addItem(.separator())
    let iOpeninSimulatorapp = NSMenuItem(
        title: "Open in Simulator.app",
        action: #selector(SimulatorPaneViewController.openInSimulatorApp(_:)),
        keyEquivalent: ""
    )
    iOpeninSimulatorapp.image = .menuSymbol("arrow.up.forward.app", describedAs: "Open in Simulator.app")
    menu.addItem(iOpeninSimulatorapp)
    let iRevealinFinder = NSMenuItem(
        title: "Reveal in Finder",
        action: #selector(SimulatorPaneViewController.revealInFinder(_:)),
        keyEquivalent: ""
    )
    iRevealinFinder.image = .menuSymbol("folder", describedAs: "Reveal in Finder")
    menu.addItem(iRevealinFinder)

    menu.addItem(.separator())
    // Mirror a physical device into this tab. Nil target → responder
    // chain → AppDelegate (same action as Shell > Mirror Physical
    // Device…), so there's one picker+attach implementation; the
    // right-clicked pane's window is key, so it targets the right tab.
    let iMirrorPhysicalDevice = NSMenuItem(
        title: "Mirror Physical Device…",
        action: #selector(AppDelegate.mirrorPhysicalDevice(_:)),
        keyEquivalent: ""
    )
    iMirrorPhysicalDevice.image = .menuSymbol("iphone", describedAs: "Mirror Physical Device")
    menu.addItem(iMirrorPhysicalDevice)

    menu.addItem(.separator())
    let iClosePane = NSMenuItem(
        title: "Close Pane",
        action: #selector(SimulatorPaneViewController.closePane(_:)),
        keyEquivalent: ""
    )
    iClosePane.image = .menuSymbol("xmark", describedAs: "Close Pane")
    menu.addItem(iClosePane)

    return menu
}
