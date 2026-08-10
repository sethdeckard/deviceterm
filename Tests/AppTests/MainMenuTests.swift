// SPDX-License-Identifier: GPL-3.0-or-later
//
// Structural assertions on the programmatic main menu.
// We don't (and can't easily) test live AppKit dispatch from a
// headless test process, so the gate here is "the menu the GUI
// installs has the shape the responder-chain code on the other side
// expects." If a selector is renamed without updating the menu, this
// test trips before a user hits a no-op menu item.

@testable import App
import AppKit
import Testing

@MainActor
struct MainMenuTests {
    private func deviceMenu() -> NSMenu? {
        makeMainMenu().items.first { $0.submenu?.title == "Device" }?.submenu
    }

    private func shellMenu() -> NSMenu? {
        makeMainMenu().items.first { $0.submenu?.title == "Shell" }?.submenu
    }

    // MARK: - Structure

    /// The top-level bar, pinned so a reshuffle reads as a diff. The
    /// application menu is first and carries no title; AppKit takes the
    /// first menu as the app menu regardless of what it is called.
    @Test
    func theTopLevelMenusAreInOrder() {
        let titles = makeMainMenu().items.compactMap { $0.submenu?.title }
        #expect(titles == ["", "Shell", "Edit", "View", "Device", "Window", "Help"])
    }

    @Test
    func shellMenuHasExpectedItemsInOrder() throws {
        let shell = try #require(shellMenu(), "Shell submenu missing")
        // Three groups: open a surface, split one, close one. Mirror
        // Physical Device… sits with the splits because it creates a
        // pane; the Device menu drives a pane that already exists.
        let titles = shell.items.map(\.title)
        #expect(titles == [
            "New Window",
            "New Tab",
            "Open Orchestrator Tab",
            "Duplicate Tab",
            "",  // separator
            "Split Right",
            "Split Down",
            "Mirror Physical Device…",
            "",  // separator
            "Close Pane",
            "Close Tab",
            "Close Window"
        ])
    }

    @Test
    func editMenuHasExpectedItemsInOrder() throws {
        let edit = try #require(editMenu(), "Edit submenu missing")
        let titles = edit.items.map(\.title)
        #expect(titles == [
            "Cut",
            "Copy",
            "Paste",
            "",  // separator
            "Select All",
            "Clear Buffer"
        ])
    }

    @Test
    func viewMenuHasExpectedItemsInOrder() throws {
        let view = try #require(viewMenu(), "View submenu missing")
        // Terminal zoom and the device size presets are adjacent: both
        // answer how big a pane's content renders.
        let titles = view.items.map(\.title)
        #expect(titles == [
            "Zoom In",
            "Zoom Out",
            "Reset Zoom",
            "",  // separator
            "Physical Size",
            "Point Accurate",
            "Pixel Accurate",
            "Fit Screen",
            "",  // separator
            "Toggle Split Direction",
            "Reset Pane Layout",
            "",  // separator
            "Toggle AX Inspector",
            "",  // separator
            "Enter Full Screen"
        ])
    }

    @Test
    func deviceMenuExistsBetweenViewAndWindow() {
        let menu = makeMainMenu()
        let titles = menu.items.compactMap { $0.submenu?.title }
        let viewIndex = titles.firstIndex(of: "View")
        let deviceIndex = titles.firstIndex(of: "Device")
        let windowIndex = titles.firstIndex(of: "Window")
        #expect(viewIndex != nil)
        #expect(deviceIndex != nil)
        #expect(windowIndex != nil)
        if let viewIndex, let deviceIndex, let windowIndex {
            #expect(viewIndex < deviceIndex)
            #expect(deviceIndex < windowIndex)
        }
    }

    @Test
    func deviceMenuHasExpectedItemsInOrder() throws {
        let device = try #require(deviceMenu(), "Device submenu missing")
        // Hardware buttons, then rotation, then the actions that restart
        // or wipe, then capture, then housekeeping on the device itself.
        // The two submenus close it out.
        let titles = device.items.map(\.title)
        #expect(titles == [
            "Home",
            "App Switcher",
            "Lock",
            "Side Button",
            "Siri",
            "Apple Pay",
            "",  // separator
            "Rotate Left",
            "Rotate Right",
            "",  // separator
            "Reboot",
            "Erase All Content and Settings…",
            "",  // separator
            "Screenshot",
            "Record Screen",
            "",  // separator
            "Install App…",
            "Open in Simulator.app",
            "Reveal in Finder",
            "Shut Down",
            "",  // separator
            "Location",
            "Hardware"
        ])
    }

    @Test
    func windowMenuHasExpectedItemsInOrder() throws {
        let window = try #require(windowMenu(), "Window submenu missing")
        // Bring All to Front is last of our own items: AppKit appends the
        // open-window list below whatever menu is `NSApp.windowsMenu`.
        let titles = window.items.map(\.title)
        #expect(titles == [
            "Minimize",
            "Zoom",
            "Rename Tab…",
            "",  // separator
            "Select Next Tab",
            "Select Previous Tab",
            "Move Tab Left",
            "Move Tab Right",
            "",  // separator
            "Select Pane",
            "Move Pane",
            "",  // separator
            "Tab 1",
            "Tab 2",
            "Tab 3",
            "Tab 4",
            "Tab 5",
            "Tab 6",
            "Tab 7",
            "Tab 8",
            "Last Tab",
            "",  // separator
            "Bring All to Front"
        ])
    }

    /// The Location item is a dynamic submenu: it is empty until its
    /// delegate populates it on open, and its action exists only so the
    /// affordance gate can grey the whole thing out (AppKit never sends
    /// an action for an item that owns a submenu).
    @Test
    func deviceMenuHasADynamicLocationSubmenu() throws {
        let device = try #require(deviceMenu(), "Device submenu missing")
        let location = try #require(
            device.items.first(where: { $0.title == "Location" }),
            "Location item missing"
        )
        let submenu = try #require(location.submenu, "Location submenu missing")
        #expect(submenu.delegate is LocationMenuController)
        #expect(submenu.items.isEmpty)
        #expect(
            location.action == #selector(SimulatorPaneViewController.applySimulatedLocation(_:))
        )
    }

    /// `NSMenu.delegate` is weak, so the submenu owning its controller is
    /// what keeps the delegate alive. If that ownership regressed the
    /// delegate would be nil by the time the menu opened, and the
    /// submenu would silently render empty forever.
    @Test
    func theLocationSubmenuOutlivesItsFactoryCall() throws {
        let item = makeLocationMenuItem { nil }
        let submenu = try #require(item.submenu)
        #expect(submenu.delegate != nil)
    }

    @Test
    func deviceMenuHasHardwareSubmenuWithCrownItems() throws {
        let device = try #require(deviceMenu(), "Device submenu missing")
        let hardware = try #require(
            device.items.first(where: { $0.submenu?.title == "Hardware" })?.submenu,
            "Hardware submenu missing"
        )
        let titles = hardware.items.map(\.title)
        #expect(titles == [
            "Crown Press",
            "Crown Rotate Up",
            "Crown Rotate Down"
        ])
    }

    @Test
    func hardwareSubmenuItemsRouteToSimulatorPaneVCSelectors() throws {
        let device = try #require(deviceMenu())
        let hardware = try #require(
            device.items.first(where: { $0.submenu?.title == "Hardware" })?.submenu
        )
        let expected: [(String, Selector)] = [
            ("Crown Press", #selector(SimulatorPaneViewController.pressDigitalCrown(_:))),
            ("Crown Rotate Up", #selector(SimulatorPaneViewController.rotateCrownUp(_:))),
            (
                "Crown Rotate Down",
                #selector(SimulatorPaneViewController.rotateCrownDown(_:))
            )
        ]
        for (title, selector) in expected {
            let item = try #require(
                hardware.items.first { $0.title == title },
                "Hardware submenu missing \(title)"
            )
            #expect(item.action == selector, "wrong action on \(title)")
            #expect(item.target == nil, "\(title) should target responder chain")
        }
    }

    // MARK: - Edit menu

    private func editMenu() -> NSMenu? {
        makeMainMenu().items.first { $0.submenu?.title == "Edit" }?.submenu
    }

    @Test
    func editMenuUsesStandardEditingSelectors() throws {
        // Load-bearing: the app has editable text fields (the rename
        // sheet, the custom-coordinates sheet) whose field editors answer
        // the standard `NSText` selectors. Terminal-specific names here
        // would leave those fields with a dead Edit menu.
        let edit = try #require(editMenu(), "Edit submenu missing")
        let expected: [(String, Selector)] = [
            ("Cut", #selector(NSText.cut(_:))),
            ("Copy", #selector(NSText.copy(_:))),
            ("Paste", #selector(NSText.paste(_:))),
            ("Select All", #selector(NSText.selectAll(_:)))
        ]
        for (title, selector) in expected {
            let item = try #require(
                edit.items.first { $0.title == title },
                "Edit menu missing \(title)"
            )
            #expect(item.action == selector, "wrong action on \(title)")
            #expect(item.target == nil, "\(title) should target responder chain")
        }
    }

    @Test
    func theTerminalPaneAnswersTheStandardEditingSelectors() {
        // The other half: a focused terminal must resolve the same
        // selectors, or the Edit menu is dead there instead. A terminal
        // pane's responder chain contains no `NSText`, so naming only
        // `NSText` would leave these items validating disabled and ⌘C /
        // ⌘V falling through to libghostty's own bindings.
        // Hoisted out of `#expect`: the macro rewrites a call on a
        // metatype into an instance call and fails to compile.
        let terminal: AnyClass = TerminalPaneViewController.self
        let respondsToCopy = terminal.instancesRespond(to: #selector(NSText.copy(_:)))
        let respondsToPaste = terminal.instancesRespond(to: #selector(NSText.paste(_:)))
        let respondsToSelectAll = terminal.instancesRespond(to: #selector(NSText.selectAll(_:)))
        let respondsToCut = terminal.instancesRespond(to: #selector(NSText.cut(_:)))
        #expect(respondsToCopy)
        #expect(respondsToPaste)
        #expect(respondsToSelectAll)
        // Not cut: a terminal has no editable region, so the item should
        // read disabled with a terminal focused rather than do nothing.
        #expect(!respondsToCut)
    }

    @Test
    func clearBufferStaysTerminalSpecific() throws {
        // Clear Buffer has no text-field meaning, so it keeps a
        // terminal-only selector and correctly greys out in a sheet.
        let edit = try #require(editMenu(), "Edit submenu missing")
        let item = try #require(
            edit.items.first { $0.title == "Clear Buffer" },
            "Edit menu missing Clear Buffer"
        )
        #expect(item.action == #selector(TerminalPaneViewController.clearTerminalScreen(_:)))
        #expect(item.keyEquivalent == "k")
        #expect(item.keyEquivalentModifierMask == [.command])
    }

    // MARK: - View menu zoom + Full Screen

    private func viewMenu() -> NSMenu? {
        makeMainMenu().items.first { $0.submenu?.title == "View" }?.submenu
    }

    @Test
    func viewMenuHasZoomItemsWithStandardKeyEquivalents() throws {
        let view = try #require(viewMenu(), "View submenu missing")
        let titles = view.items.map(\.title)
        for expected in ["Zoom In", "Zoom Out", "Reset Zoom"] {
            #expect(titles.contains(expected), "View menu missing \(expected)")
        }
        let zoomIn = try #require(view.items.first(where: { $0.title == "Zoom In" }))
        #expect(zoomIn.keyEquivalent == "=")
        #expect(zoomIn.keyEquivalentModifierMask == [.command])
        let zoomOut = try #require(view.items.first(where: { $0.title == "Zoom Out" }))
        #expect(zoomOut.keyEquivalent == "-")
        #expect(zoomOut.keyEquivalentModifierMask == [.command])
        let reset = try #require(view.items.first(where: { $0.title == "Reset Zoom" }))
        #expect(reset.keyEquivalent == "0")
        #expect(reset.keyEquivalentModifierMask == [.command])
    }

    @Test
    func viewMenuZoomItemsRouteToTerminalPaneVC() throws {
        let view = try #require(viewMenu())
        let expected: [(String, Selector)] = [
            ("Zoom In", #selector(TerminalPaneViewController.zoomTerminalIn(_:))),
            ("Zoom Out", #selector(TerminalPaneViewController.zoomTerminalOut(_:))),
            ("Reset Zoom", #selector(TerminalPaneViewController.resetTerminalZoom(_:)))
        ]
        for (title, selector) in expected {
            let item = try #require(
                view.items.first(where: { $0.title == title }),
                "View menu missing \(title)"
            )
            #expect(item.action == selector, "wrong action on \(title)")
            #expect(item.target == nil, "\(title) should target responder chain")
        }
    }

    /// Bare ⌥A bypasses AppKit key-equivalent matching, and Option is
    /// reserved for terminal Meta and compose input. AX Inspector therefore
    /// uses ⌥⌘A.
    @Test
    func axInspectorUsesOptionCommandAndNotBareOption() throws {
        let view = try #require(viewMenu())
        let item = try #require(
            view.items.first(where: { $0.title == "Toggle AX Inspector" }),
            "Toggle AX Inspector missing"
        )
        #expect(item.keyEquivalent == "a")
        #expect(item.keyEquivalentModifierMask == [.option, .command])
        #expect(item.keyEquivalentModifierMask != [.option], "bare ⌥A never fires")
    }

    @Test
    func viewMenuHasEnterFullScreen() throws {
        let view = try #require(viewMenu())
        let item = try #require(
            view.items.first(where: { $0.title == "Enter Full Screen" }),
            "Enter Full Screen missing"
        )
        #expect(item.action == #selector(NSWindow.toggleFullScreen(_:)))
        #expect(item.keyEquivalent == "f")
        #expect(item.keyEquivalentModifierMask == [.command, .control])
    }

    // MARK: - Window menu

    private func windowMenu() -> NSMenu? {
        makeMainMenu().items.first { $0.submenu?.title == "Window" }?.submenu
    }

    @Test
    func windowMenuRoutesToStandardSelectors() throws {
        let window = try #require(windowMenu())
        let expected: [(String, Selector)] = [
            ("Minimize", #selector(NSWindow.performMiniaturize(_:))),
            ("Zoom", #selector(NSWindow.performZoom(_:))),
            ("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        ]
        for (title, selector) in expected {
            let item = try #require(
                window.items.first(where: { $0.title == title }),
                "Window menu missing \(title)"
            )
            #expect(item.action == selector, "wrong action on \(title)")
        }
    }

    /// Close Window sits in Shell with the other close items rather than
    /// in Window, so the three closes read as one group at one depth.
    @Test
    func closeWindowLivesInTheShellMenu() throws {
        let shell = try #require(shellMenu())
        let item = try #require(
            shell.items.first(where: { $0.title == "Close Window" }),
            "Shell menu missing Close Window"
        )
        #expect(item.action == #selector(NSWindow.performClose(_:)))
        #expect(item.target == nil)
    }

    @Test
    func splitFallbackImplementsHardwareSubmenuSelectors() {
        // Watch-only fallbacks live alongside the rest so menu-bar
        // dispatch reaches them when a terminal pane is focused; the
        // family gate happens inside `validateUserInterfaceItem`.
        let selectors: [Selector] = [
            #selector(SimulatorPaneViewController.pressDigitalCrown(_:)),
            #selector(SimulatorPaneViewController.rotateCrownUp(_:)),
            #selector(SimulatorPaneViewController.rotateCrownDown(_:))
        ]
        for selector in selectors {
            #expect(
                PaneLayoutViewController.instancesRespond(to: selector),
                "PaneLayoutViewController missing fallback for \(selector)"
            )
        }
    }

    @Test
    func shellMenuHasMirrorPhysicalDevice() throws {
        // The picker trigger creates a pane, so it lives in Shell beside
        // the splits and routes through the responder chain to
        // AppDelegate. If the selector is renamed without updating the
        // menu, this trips before a user hits a dead "Mirror Physical
        // Device…" item.
        let shell = try #require(shellMenu())
        let item = try #require(
            shell.items.first { $0.title == "Mirror Physical Device…" },
            "Shell menu missing Mirror Physical Device…"
        )
        #expect(item.action == #selector(AppDelegate.mirrorPhysicalDevice(_:)))
        #expect(item.target == nil, "should target the responder chain")
    }

    @Test
    func deviceMenuItemsHaveResponderChainSelectors() throws {
        let device = try #require(deviceMenu())
        let expected: [(String, Selector)] = [
            ("Home", #selector(SimulatorPaneViewController.pressHardwareHome(_:))),
            ("App Switcher", #selector(SimulatorPaneViewController.invokeAppSwitcher(_:))),
            ("Lock", #selector(SimulatorPaneViewController.pressHardwareLock(_:))),
            ("Side Button", #selector(SimulatorPaneViewController.pressHardwareSide(_:))),
            ("Siri", #selector(SimulatorPaneViewController.pressHardwareSiri(_:))),
            ("Apple Pay", #selector(SimulatorPaneViewController.pressHardwareApplePay(_:))),
            ("Rotate Left", #selector(SimulatorPaneViewController.rotateDeviceLeft(_:))),
            ("Rotate Right", #selector(SimulatorPaneViewController.rotateDeviceRight(_:))),
            ("Reboot", #selector(SimulatorPaneViewController.rebootDevice(_:))),
            (
                "Erase All Content and Settings…",
                #selector(SimulatorPaneViewController.eraseAllContent(_:))
            ),
            ("Screenshot", #selector(SimulatorPaneViewController.screenshotPane(_:))),
            ("Record Screen", #selector(SimulatorPaneViewController.recordPane(_:))),
            ("Install App…", #selector(SimulatorPaneViewController.installApp(_:))),
            (
                "Open in Simulator.app",
                #selector(SimulatorPaneViewController.openInSimulatorApp(_:))
            ),
            ("Reveal in Finder", #selector(SimulatorPaneViewController.revealInFinder(_:))),
            ("Shut Down", #selector(SimulatorPaneViewController.shutDownSim(_:)))
        ]
        for (title, selector) in expected {
            let item = try #require(
                device.items.first { $0.title == title },
                "Device menu missing \(title)"
            )
            #expect(item.action == selector, "wrong action on \(title)")
            #expect(item.target == nil, "\(title) should target responder chain")
        }
    }

    @Test
    func splitFallbackImplementsEveryDeviceMenuSelector() throws {
        // Pre-condition: the fallback responder claims every selector the
        // Device menu dispatches, so no item goes dead when a terminal
        // pane holds focus.
        //
        // Walks the menu rather than a hand-listed set, because the
        // catalog's own responder check is blind here: Shut Down, Reveal
        // in Finder, and the rest are deliberately shortcut-free, so they
        // have no `KeybindingEntry` and appear in no `responders` list.
        // The walk covers the Hardware submenu and the Location parent
        // item too. Location's *rows* are built on open and are covered
        // in `KeybindingCatalogTests`; they dispatch the same four
        // selectors the parent item's affordance gate already names.
        let device = try #require(deviceMenu())
        func check(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { check(submenu) }
                guard item.target == nil, let selector = item.action else { continue }
                #expect(
                    PaneLayoutViewController.instancesRespond(to: selector),
                    "PaneLayoutViewController missing fallback for \(selector) ('\(item.title)')"
                )
            }
        }
        check(device)
    }

    @Test
    func theSplitFallbackIsNotShadowedByTheDevicePane() {
        // Split Right / Split Down reach `PaneLayoutViewController` only
        // because nothing between a focused device pane and the
        // controller claims the selector. If `SimulatorPaneViewController`
        // ever grew one, it would swallow the item and the fallback would
        // silently stop running, with the menu still reading enabled.
        let selectors: [Selector] = [
            #selector(TerminalPaneViewController.splitTerminalRight(_:)),
            #selector(TerminalPaneViewController.splitTerminalDown(_:))
        ]
        for selector in selectors {
            // Hoisted out of `#expect`: the macro rewrites a call on a
            // metatype into an instance call and fails to compile.
            let layoutResponds = PaneLayoutViewController.instancesRespond(to: selector)
            let simResponds = SimulatorPaneViewController.instancesRespond(to: selector)
            #expect(layoutResponds, "PaneLayoutViewController missing fallback for \(selector)")
            #expect(!simResponds, "SimulatorPaneViewController shadows the fallback for \(selector)")
        }
    }

    @Test
    func theCloseFallbackIsNotShadowedBetweenThePaneAndTheStrip() {
        // ⌘W reaches `PaneLayoutViewController` whenever a pane holds focus,
        // and `TabStripViewController` when none does. A pane VC growing
        // the selector would claim it first and skip the resolution the
        // layout controller performs, leaving the item titled for a pane
        // close that never consults the terminal count.
        let selector = #selector(PaneLayoutViewController.closeFocusedPaneOrTab(_:))
        // Hoisted out of `#expect`: the macro rewrites a call on a
        // metatype into an instance call and fails to compile.
        let layoutResponds = PaneLayoutViewController.instancesRespond(to: selector)
        let stripResponds = TabStripViewController.instancesRespond(to: selector)
        let terminalResponds = TerminalPaneViewController.instancesRespond(to: selector)
        let simResponds = SimulatorPaneViewController.instancesRespond(to: selector)
        #expect(layoutResponds, "PaneLayoutViewController does not implement \(selector)")
        #expect(stripResponds, "TabStripViewController is missing the no-focus fallback")
        #expect(!terminalResponds, "TerminalPaneViewController shadows the close resolution")
        #expect(!simResponds, "SimulatorPaneViewController shadows the close resolution")
    }

    // MARK: - Shell menu

    @Test
    func shellMenuOffersBothSplits() throws {
        // Both split actions have to be reachable from the Shell menu, so
        // they are discoverable without right-clicking a pane.
        let shell = try #require(shellMenu(), "Shell submenu missing")
        let right = try #require(
            shell.items.first(where: { $0.title == "Split Right" }),
            "Shell menu missing Split Right"
        )
        #expect(right.action == #selector(TerminalPaneViewController.splitTerminalRight(_:)))
        #expect(right.keyEquivalent == "d")
        #expect(right.keyEquivalentModifierMask == [.command])
        let down = try #require(
            shell.items.first(where: { $0.title == "Split Down" }),
            "Shell menu missing Split Down"
        )
        #expect(down.action == #selector(TerminalPaneViewController.splitTerminalDown(_:)))
        #expect(down.keyEquivalent == "d")
        #expect(down.keyEquivalentModifierMask == [.command, .shift])
    }

    /// Rename Tab… and Duplicate Tab exist in the tab strip's right-click
    /// menu too, and those copies open with
    /// `guard let tabID = sender.representedObject as? TabID`. A main-menu
    /// item carries no represented object, so pointing these at the
    /// right-click selectors would produce two items that silently do
    /// nothing.
    ///
    /// This pins which selector each item names, and that the strip
    /// implements it. It does not exercise dispatch: reaching the handler
    /// needs a live `TabStripViewController`, whose init takes a router,
    /// an intent dispatcher, a daemon client, and a resurrect service,
    /// and Rename opens a modal sheet. Both are checked by hand in
    /// `Tests/Manual/keyboard-shortcuts.md`.
    @Test
    func theMainMenuUsesTheSelectedTabEntryPoints() throws {
        let shell = try #require(shellMenu())
        let window = try #require(windowMenu())
        let duplicate = try #require(
            shell.items.first(where: { $0.title == "Duplicate Tab" }),
            "Shell menu missing Duplicate Tab"
        )
        let rename = try #require(
            window.items.first(where: { $0.title == "Rename Tab…" }),
            "Window menu missing Rename Tab…"
        )
        #expect(duplicate.action == #selector(TabStripViewController.duplicateSelectedTab(_:)))
        #expect(rename.action == #selector(TabStripViewController.renameSelectedTab(_:)))
        #expect(duplicate.target == nil)
        #expect(rename.target == nil)
        for selector in [duplicate, rename].compactMap(\.action) {
            #expect(
                TabStripViewController.instancesRespond(to: selector),
                "TabStripViewController does not implement \(selector)"
            )
        }
    }

    @Test
    func toggleSplitDirectionMovedOffTheSplitChord() throws {
        // ⇧⌘D creates a split, so flipping an existing one answers to
        // the distinct ⌃⇧D. The catalog's duplicate-chord check is what
        // keeps the two from converging.
        let view = try #require(viewMenu())
        let item = try #require(
            view.items.first(where: { $0.title == "Toggle Split Direction" }),
            "Toggle Split Direction missing"
        )
        #expect(item.keyEquivalent == "d")
        #expect(item.keyEquivalentModifierMask == [.control, .shift])
    }

    @Test
    func theSelectPaneSubmenuOffersEveryDirection() throws {
        let window = try #require(windowMenu())
        let select = try #require(
            window.items.first(where: { $0.submenu?.title == "Select Pane" })?.submenu,
            "Select Pane submenu missing"
        )
        let expected: [(String, Selector)] = [
            ("Select Pane Above", #selector(PaneLayoutViewController.selectPaneAbove(_:))),
            ("Select Pane Below", #selector(PaneLayoutViewController.selectPaneBelow(_:))),
            ("Select Pane Left", #selector(PaneLayoutViewController.selectPaneLeft(_:))),
            ("Select Pane Right", #selector(PaneLayoutViewController.selectPaneRight(_:))),
            ("Next Pane", #selector(PaneLayoutViewController.selectNextPane(_:))),
            ("Previous Pane", #selector(PaneLayoutViewController.selectPreviousPane(_:)))
        ]
        for (title, selector) in expected {
            let item = try #require(
                select.items.first(where: { $0.title == title }),
                "Select Pane submenu missing \(title)"
            )
            #expect(item.action == selector, "wrong action on \(title)")
            #expect(item.target == nil, "\(title) should target responder chain")
        }
    }

    @Test
    func theMovePaneSubmenuOffersBothDirections() throws {
        let window = try #require(windowMenu())
        let move = try #require(
            window.items.first(where: { $0.submenu?.title == "Move Pane" })?.submenu,
            "Move Pane submenu missing"
        )
        let titles = move.items.map(\.title)
        #expect(titles == ["Move Pane Left", "Move Pane Right"])
        for item in move.items {
            #expect(item.target == nil, "\(item.title) should target responder chain")
        }
    }

    @Test
    func openOrchestratorTabHasCommandShiftT() throws {
        let shell = try #require(shellMenu(), "Shell submenu missing")
        let item = try #require(
            shell.items.first(where: { $0.title == "Open Orchestrator Tab" }),
            "Open Orchestrator Tab missing"
        )
        #expect(item.keyEquivalent == "t")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
    }

    @Test
    func installAppItemRoutesToSimulatorPaneVC() throws {
        // Install App… acts on the focused device, so it belongs in
        // Device with the rest of that surface.
        let device = try #require(deviceMenu())
        let item = try #require(
            device.items.first(where: { $0.title == "Install App…" }),
            "Install App… missing"
        )
        let action = try #require(item.action, "Install App… has no action")
        #expect(action == #selector(SimulatorPaneViewController.installApp(_:)))
        #expect(item.target == nil)
        #expect(
            PaneLayoutViewController.instancesRespond(to: action),
            "PaneLayoutViewController missing fallback for installApp:"
        )
    }

    // MARK: - App menu (Settings) + Help menu

    /// The application menu is the first top-level item; its submenu has
    /// no title.
    private func appMenu() -> NSMenu? {
        makeMainMenu().items.first?.submenu
    }

    private func helpMenu() -> NSMenu? {
        makeMainMenu().items.first { $0.submenu?.title == "Help" }?.submenu
    }

    @Test
    func appMenuHasSettingsItemWithCommandComma() throws {
        let app = try #require(appMenu(), "App submenu missing")
        let item = try #require(
            app.items.first(where: { $0.title == "Settings…" }),
            "Settings… missing"
        )
        #expect(item.keyEquivalent == ",")
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(item.action == #selector(AppDelegate.openSettings(_:)))
        #expect(item.target == nil, "Settings… should target responder chain")
    }

    @Test
    func helpMenuIsLastWithThirdPartyNotices() throws {
        let titles = makeMainMenu().items.compactMap { $0.submenu?.title }
        #expect(titles.last == "Help", "Help should be the last top-level menu")
        let help = try #require(helpMenu(), "Help submenu missing")
        let item = try #require(
            help.items.first(where: { $0.title == "Third-Party Notices" }),
            "Third-Party Notices missing"
        )
        #expect(item.action == #selector(AppDelegate.openThirdPartyNotices(_:)))
        #expect(item.target == nil)
    }
}
