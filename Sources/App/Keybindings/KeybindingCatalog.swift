// SPDX-License-Identifier: GPL-3.0-or-later
//
// KeybindingCatalog: the single source of truth for every keyboard
// shortcut deviceterm binds.
//
// `MainMenu` owns menu structure (order, grouping, separators, submenus)
// and asks this table for every bound item. A drift guard in `AppTests`
// asserts a one-for-one correspondence in both directions. Every catalog
// entry appears in the menu, so a shortcut is always discoverable by
// browsing, and every bound menu item matches a catalog row on title,
// chord, selector, and tag, with multiplicities compared so a duplicate
// is caught too. The guard inspects the menu AppKit would install rather
// than the source that built it.
//
// ## Measured AppKit behavior this design rests on
//
// Measured against real keystrokes, because synthesized
// `NSApp.sendEvent` is not faithful. A synthesized event never enters
// the event queue, so `NSApp.currentEvent` stays stale and command-chord
// fall-through reads falsely negative.
//
//   - Dispatch order is view-hierarchy `performKeyEquivalent`, then
//     main-menu key-equivalent matching, then `keyDown:`. An enabled item
//     here therefore wins against libghostty's own keybinds with no
//     interception code, because libghostty only ever sees a key at the
//     `keyDown:` stage.
//   - An item that validates disabled does NOT swallow the event. It
//     falls through to `keyDown:`, verified for ⌘, ⌃⇧, and ⌥ chords. A
//     conditionally-disabled shortcut therefore degrades to "the focused
//     pane gets the key" rather than eating it.
//   - During `validateUserInterfaceItem`, `NSApp.currentEvent` is the
//     triggering `keyDown` on the key path and a non-key event on the
//     pointer and menu-update paths. AppKit also validates only items
//     whose chord matches, so that discriminator is narrow.
//
// ## Why every chord carries ⌘, or ⌃⇧
//
// Bare-Option chords never enter key-equivalent routing at all. An item
// bound to ⌥A produced no `performKeyEquivalent` and no validation, and
// the key went straight to the focused view, apparently because AppKit
// matches the item's `keyEquivalent` against the event's composed
// characters and ⌥A composes to "å". A bare-Option binding is therefore
// silently dead. Option is also the terminal's Meta and compose
// modifier, which the app must leave alone. The drift guard enforces the
// resulting invariant.
//
// ## Deliberately not bound
//
// ⌘` (cycle windows) is an OS-owned, user-configurable system shortcut,
// not deviceterm's to claim. Its absence from this table is a decision
// rather than an oversight.

import AppKit

@MainActor
enum KeybindingCatalog {
    static let entries: [KeybindingEntry] = [
        // MARK: Application

        KeybindingEntry(
            action: .openSettings,
            chord: KeyChord(",", .command),
            title: "Settings…",
            selector: #selector(AppDelegate.openSettings(_:)),
            responders: [AppDelegate.self]
        ),
        KeybindingEntry(
            action: .hideApp,
            chord: KeyChord("h", .command),
            title: "Hide DeviceTerm",
            selector: #selector(NSApplication.hide(_:)),
            responders: [NSApplication.self]
        ),
        KeybindingEntry(
            action: .hideOthers,
            chord: KeyChord("h", [.option, .command]),
            title: "Hide Others",
            selector: #selector(NSApplication.hideOtherApplications(_:)),
            responders: [NSApplication.self]
        ),
        KeybindingEntry(
            action: .quit,
            chord: KeyChord("q", .command),
            title: "Quit DeviceTerm",
            selector: #selector(NSApplication.terminate(_:)),
            responders: [NSApplication.self]
        ),

        // MARK: Tabs, windows, lifecycle

        KeybindingEntry(
            action: .newWindow,
            chord: KeyChord("n", .command),
            title: "New Window",
            selector: #selector(AppDelegate.newWindow(_:)),
            responders: [AppDelegate.self]
        ),
        // AppDelegate implements `newTab:` too, as the windowless fallback
        // for ⌘T when no window is key.
        KeybindingEntry(
            action: .newTab,
            chord: KeyChord("t", .command),
            title: "New Tab",
            selector: #selector(TabStripViewController.newTab(_:)),
            responders: [TabStripViewController.self, AppDelegate.self]
        ),
        KeybindingEntry(
            action: .openAutomationTab,
            chord: KeyChord("t", [.shift, .command]),
            title: "Open Automation Tab",
            selector: #selector(TabStripViewController.openAutomationTab(_:)),
            responders: [TabStripViewController.self]
        ),
        // ⌘W closes the focused pane, and resolves to the whole tab when
        // the focused terminal is the tab's last one, since a tab must
        // keep at least one terminal. The item's title
        // follows that resolution, which is why the selector lands on
        // the layout controller rather than on each pane VC: naming the
        // consequence needs the whole tab in view. The tab strip carries
        // the same selector as the fallback for focus that sits outside
        // every pane, where the layout controller is not in the chain at
        // all. ⌥⌘W closes the tab whatever ⌘W currently resolves to.
        KeybindingEntry(
            action: .closePane,
            chord: KeyChord("w", .command),
            title: "Close Pane",
            selector: #selector(PaneLayoutViewController.closeFocusedPaneOrTab(_:)),
            responders: [PaneLayoutViewController.self, TabStripViewController.self]
        ),
        KeybindingEntry(
            action: .closeTab,
            chord: KeyChord("w", [.option, .command]),
            title: "Close Tab",
            selector: #selector(TabStripViewController.closeTab(_:)),
            responders: [TabStripViewController.self]
        ),
        KeybindingEntry(
            action: .closeWindow,
            chord: KeyChord("w", [.shift, .command]),
            title: "Close Window",
            selector: #selector(NSWindow.performClose(_:)),
            responders: [NSWindow.self]
        ),
        KeybindingEntry(
            action: .minimize,
            chord: KeyChord("m", .command),
            title: "Minimize",
            selector: #selector(NSWindow.performMiniaturize(_:)),
            responders: [NSWindow.self]
        ),

        // MARK: Editing
        //
        // These carry AppKit's *standard* editing selectors, so one Edit
        // menu serves two kinds of responder. A focused terminal pane
        // implements `copy:`, `paste:`, and `selectAll:` itself and drives
        // its libghostty surface. A focused text field (the rename sheet,
        // the custom-coordinates sheet) resolves the same selectors on its
        // `NSText` field editor. Terminal-specific names would leave every
        // text field in the app with a dead Edit menu.
        //
        // Naming `NSText` alone is not enough either. A terminal pane's
        // responder chain contains none, so the items would validate
        // disabled there and ⌘C / ⌘V would reach libghostty's own bindings
        // instead. Both responders are required.

        KeybindingEntry(
            action: .cut,
            chord: KeyChord("x", .command),
            title: "Cut",
            selector: #selector(NSText.cut(_:)),
            // Text fields only. A terminal has no editable region, so
            // `TerminalPaneViewController` deliberately omits `cut:` and
            // the item reads disabled with a terminal focused.
            responders: [NSText.self]
        ),
        KeybindingEntry(
            action: .copy,
            chord: KeyChord("c", .command),
            title: "Copy",
            selector: #selector(NSText.copy(_:)),
            responders: [TerminalPaneViewController.self, NSText.self]
        ),
        KeybindingEntry(
            action: .paste,
            chord: KeyChord("v", .command),
            title: "Paste",
            selector: #selector(NSText.paste(_:)),
            responders: [TerminalPaneViewController.self, NSText.self]
        ),
        KeybindingEntry(
            action: .selectAll,
            chord: KeyChord("a", .command),
            title: "Select All",
            selector: #selector(NSText.selectAll(_:)),
            responders: [TerminalPaneViewController.self, NSText.self]
        ),
        KeybindingEntry(
            action: .clearBuffer,
            chord: KeyChord("k", .command),
            title: "Clear Buffer",
            selector: #selector(TerminalPaneViewController.clearTerminalScreen(_:)),
            responders: [TerminalPaneViewController.self]
        ),

        // MARK: Tab navigation
        //
        // The numbered items share one selector and differ only by `tag`,
        // which carries the 1-based position. ⌘9 is Last Tab rather than
        // Tab 9, matching browsers, so it answers in a window with fewer
        // than nine tabs.
        //
        // ⌘` is deliberately absent. See this file's header.

        KeybindingEntry(
            action: .selectTab1,
            chord: KeyChord("1", .command),
            title: "Tab 1",
            selector: #selector(TabStripViewController.selectTabByIndex(_:)),
            responders: [TabStripViewController.self],
            tag: 1
        ),
        KeybindingEntry(
            action: .selectTab2,
            chord: KeyChord("2", .command),
            title: "Tab 2",
            selector: #selector(TabStripViewController.selectTabByIndex(_:)),
            responders: [TabStripViewController.self],
            tag: 2
        ),
        KeybindingEntry(
            action: .selectTab3,
            chord: KeyChord("3", .command),
            title: "Tab 3",
            selector: #selector(TabStripViewController.selectTabByIndex(_:)),
            responders: [TabStripViewController.self],
            tag: 3
        ),
        KeybindingEntry(
            action: .selectTab4,
            chord: KeyChord("4", .command),
            title: "Tab 4",
            selector: #selector(TabStripViewController.selectTabByIndex(_:)),
            responders: [TabStripViewController.self],
            tag: 4
        ),
        KeybindingEntry(
            action: .selectTab5,
            chord: KeyChord("5", .command),
            title: "Tab 5",
            selector: #selector(TabStripViewController.selectTabByIndex(_:)),
            responders: [TabStripViewController.self],
            tag: 5
        ),
        KeybindingEntry(
            action: .selectTab6,
            chord: KeyChord("6", .command),
            title: "Tab 6",
            selector: #selector(TabStripViewController.selectTabByIndex(_:)),
            responders: [TabStripViewController.self],
            tag: 6
        ),
        KeybindingEntry(
            action: .selectTab7,
            chord: KeyChord("7", .command),
            title: "Tab 7",
            selector: #selector(TabStripViewController.selectTabByIndex(_:)),
            responders: [TabStripViewController.self],
            tag: 7
        ),
        KeybindingEntry(
            action: .selectTab8,
            chord: KeyChord("8", .command),
            title: "Tab 8",
            selector: #selector(TabStripViewController.selectTabByIndex(_:)),
            responders: [TabStripViewController.self],
            tag: 8
        ),
        KeybindingEntry(
            action: .selectLastTab,
            chord: KeyChord("9", .command),
            title: "Last Tab",
            selector: #selector(TabStripViewController.selectLastTab(_:)),
            responders: [TabStripViewController.self]
        ),
        KeybindingEntry(
            action: .selectPreviousTab,
            chord: KeyChord("[", [.shift, .command]),
            title: "Select Previous Tab",
            selector: #selector(TabStripViewController.selectPreviousTab(_:)),
            responders: [TabStripViewController.self]
        ),
        KeybindingEntry(
            action: .selectNextTab,
            chord: KeyChord("]", [.shift, .command]),
            title: "Select Next Tab",
            selector: #selector(TabStripViewController.selectNextTab(_:)),
            responders: [TabStripViewController.self]
        ),

        // MARK: Splits
        //
        // Both selectors resolve on the focused terminal pane, which
        // splits itself. A focused device pane implements neither, so the
        // responder chain continues to `PaneLayoutViewController` and the new
        // terminal lands beside the device. That fallback is why both
        // classes are listed: the layout controller has to carry the same
        // selector name, since one menu item names one selector.

        KeybindingEntry(
            action: .splitRight,
            chord: KeyChord("d", .command),
            title: "Split Right",
            selector: #selector(TerminalPaneViewController.splitTerminalRight(_:)),
            responders: [TerminalPaneViewController.self, PaneLayoutViewController.self]
        ),
        KeybindingEntry(
            action: .splitDown,
            chord: KeyChord("d", [.shift, .command]),
            title: "Split Down",
            selector: #selector(TerminalPaneViewController.splitTerminalDown(_:)),
            responders: [TerminalPaneViewController.self, PaneLayoutViewController.self]
        ),

        // MARK: Pane navigation

        KeybindingEntry(
            action: .selectPreviousPane,
            chord: KeyChord("[", .command),
            title: "Previous Pane",
            selector: #selector(PaneLayoutViewController.selectPreviousPane(_:)),
            responders: [PaneLayoutViewController.self]
        ),
        KeybindingEntry(
            action: .selectNextPane,
            chord: KeyChord("]", .command),
            title: "Next Pane",
            selector: #selector(PaneLayoutViewController.selectNextPane(_:)),
            responders: [PaneLayoutViewController.self]
        ),
        KeybindingEntry(
            action: .selectPaneAbove,
            chord: KeyChord(.arrowUp, [.option, .command]),
            title: "Select Pane Above",
            selector: #selector(PaneLayoutViewController.selectPaneAbove(_:)),
            responders: [PaneLayoutViewController.self]
        ),
        KeybindingEntry(
            action: .selectPaneBelow,
            chord: KeyChord(.arrowDown, [.option, .command]),
            title: "Select Pane Below",
            selector: #selector(PaneLayoutViewController.selectPaneBelow(_:)),
            responders: [PaneLayoutViewController.self]
        ),
        KeybindingEntry(
            action: .selectPaneLeft,
            chord: KeyChord(.arrowLeft, [.option, .command]),
            title: "Select Pane Left",
            selector: #selector(PaneLayoutViewController.selectPaneLeft(_:)),
            responders: [PaneLayoutViewController.self]
        ),
        KeybindingEntry(
            action: .selectPaneRight,
            chord: KeyChord(.arrowRight, [.option, .command]),
            title: "Select Pane Right",
            selector: #selector(PaneLayoutViewController.selectPaneRight(_:)),
            responders: [PaneLayoutViewController.self]
        ),

        // MARK: Pane and tab arrangement

        KeybindingEntry(
            action: .movePaneLeft,
            chord: KeyChord(.arrowLeft, [.shift, .command]),
            title: "Move Pane Left",
            selector: #selector(PaneLayoutViewController.swapPaneLeft(_:)),
            responders: [PaneLayoutViewController.self]
        ),
        KeybindingEntry(
            action: .movePaneRight,
            chord: KeyChord(.arrowRight, [.shift, .command]),
            title: "Move Pane Right",
            selector: #selector(PaneLayoutViewController.swapPaneRight(_:)),
            responders: [PaneLayoutViewController.self]
        ),
        KeybindingEntry(
            action: .moveTabLeft,
            chord: KeyChord(.arrowLeft, [.control, .shift]),
            title: "Move Tab Left",
            selector: #selector(TabStripViewController.moveSelectedTabLeft(_:)),
            responders: [TabStripViewController.self]
        ),
        KeybindingEntry(
            action: .moveTabRight,
            chord: KeyChord(.arrowRight, [.control, .shift]),
            title: "Move Tab Right",
            selector: #selector(TabStripViewController.moveSelectedTabRight(_:)),
            responders: [TabStripViewController.self]
        ),
        // ⌃⇧D keeps clear of ⇧⌘D, the Split Down chord. Toggling an
        // existing split's axis is the rarer of the two, so the common
        // action takes the ⌘-based chord.
        KeybindingEntry(
            action: .toggleSplitDirection,
            chord: KeyChord("d", [.control, .shift]),
            title: "Toggle Split Direction",
            selector: #selector(PaneLayoutViewController.toggleSplitDirection(_:)),
            responders: [PaneLayoutViewController.self]
        ),

        // MARK: Presentation

        KeybindingEntry(
            action: .zoomIn,
            chord: KeyChord("=", .command),
            title: "Zoom In",
            selector: #selector(TerminalPaneViewController.zoomTerminalIn(_:)),
            responders: [TerminalPaneViewController.self]
        ),
        KeybindingEntry(
            action: .zoomOut,
            chord: KeyChord("-", .command),
            title: "Zoom Out",
            selector: #selector(TerminalPaneViewController.zoomTerminalOut(_:)),
            responders: [TerminalPaneViewController.self]
        ),
        KeybindingEntry(
            action: .resetZoom,
            chord: KeyChord("0", .command),
            title: "Reset Zoom",
            selector: #selector(TerminalPaneViewController.resetTerminalZoom(_:)),
            responders: [TerminalPaneViewController.self]
        ),
        KeybindingEntry(
            action: .toggleFullScreen,
            chord: KeyChord("f", [.control, .command]),
            title: "Enter Full Screen",
            selector: #selector(NSWindow.toggleFullScreen(_:)),
            responders: [NSWindow.self]
        ),
        // AppKit does not route bare-Option chords through key-equivalent
        // matching, so ⌥⌘A is what makes this shortcut work while leaving
        // bare Option available to the terminal.
        KeybindingEntry(
            action: .toggleAxInspector,
            chord: KeyChord("a", [.option, .command]),
            title: "Toggle AX Inspector",
            selector: #selector(SimulatorPaneViewController.toggleAxInspector(_:)),
            responders: [SimulatorPaneViewController.self, PaneLayoutViewController.self],
            scope: .devicePane
        ),

        // MARK: Device controls
        //
        // Every row here is `.devicePane`, so the chord reaches a device
        // only while that pane holds focus and a focused terminal keeps
        // ⌘← / ⌘→ for its own cursor. The menu items stay tab-scoped:
        // clicking one forwards through `PaneLayoutViewController` to the
        // tab's first device pane.

        KeybindingEntry(
            action: .deviceHome,
            chord: KeyChord("h", [.shift, .command]),
            title: "Home",
            selector: #selector(SimulatorPaneViewController.pressHardwareHome(_:)),
            responders: [SimulatorPaneViewController.self, PaneLayoutViewController.self],
            scope: .devicePane
        ),
        KeybindingEntry(
            action: .deviceLock,
            chord: KeyChord("l", .command),
            title: "Lock",
            selector: #selector(SimulatorPaneViewController.pressHardwareLock(_:)),
            responders: [SimulatorPaneViewController.self, PaneLayoutViewController.self],
            scope: .devicePane
        ),
        KeybindingEntry(
            action: .deviceRotateLeft,
            chord: KeyChord(.arrowLeft, .command),
            title: "Rotate Left",
            selector: #selector(SimulatorPaneViewController.rotateDeviceLeft(_:)),
            responders: [SimulatorPaneViewController.self, PaneLayoutViewController.self],
            scope: .devicePane
        ),
        KeybindingEntry(
            action: .deviceRotateRight,
            chord: KeyChord(.arrowRight, .command),
            title: "Rotate Right",
            selector: #selector(SimulatorPaneViewController.rotateDeviceRight(_:)),
            responders: [SimulatorPaneViewController.self, PaneLayoutViewController.self],
            scope: .devicePane
        ),
        KeybindingEntry(
            action: .deviceScreenshot,
            chord: KeyChord("s", .command),
            title: "Screenshot",
            selector: #selector(SimulatorPaneViewController.screenshotPane(_:)),
            responders: [SimulatorPaneViewController.self, PaneLayoutViewController.self],
            scope: .devicePane
        ),
        // The title flips to "Stop Recording" while a recording runs.
        // The catalog carries the start-state title, which is what a
        // freshly built menu shows.
        KeybindingEntry(
            action: .deviceRecord,
            chord: KeyChord("r", .command),
            title: "Record Screen",
            selector: #selector(SimulatorPaneViewController.recordPane(_:)),
            responders: [SimulatorPaneViewController.self, PaneLayoutViewController.self],
            scope: .devicePane
        ),

        // MARK: Device pane size presets

        KeybindingEntry(
            action: .sizePresetPhysical,
            chord: KeyChord("1", [.control, .command]),
            title: "Physical Size",
            selector: #selector(SimulatorPaneViewController.applySizePresetPhysical(_:)),
            responders: [SimulatorPaneViewController.self, PaneLayoutViewController.self],
            scope: .devicePane
        ),
        KeybindingEntry(
            action: .sizePresetPointAccurate,
            chord: KeyChord("2", [.control, .command]),
            title: "Point Accurate",
            selector: #selector(SimulatorPaneViewController.applySizePresetPointAccurate(_:)),
            responders: [SimulatorPaneViewController.self, PaneLayoutViewController.self],
            scope: .devicePane
        ),
        KeybindingEntry(
            action: .sizePresetPixelAccurate,
            chord: KeyChord("3", [.control, .command]),
            title: "Pixel Accurate",
            selector: #selector(SimulatorPaneViewController.applySizePresetPixelAccurate(_:)),
            responders: [SimulatorPaneViewController.self, PaneLayoutViewController.self],
            scope: .devicePane
        ),
        KeybindingEntry(
            action: .sizePresetFitScreen,
            chord: KeyChord("4", [.control, .command]),
            title: "Fit Screen",
            selector: #selector(SimulatorPaneViewController.applySizePresetFitScreen(_:)),
            responders: [SimulatorPaneViewController.self, PaneLayoutViewController.self],
            scope: .devicePane
        )
    ]

    static func entry(for action: KeybindingAction) -> KeybindingEntry? {
        entries.first { $0.action == action }
    }

    /// The entry a menu item dispatches, keyed by what the item carries.
    /// Tab 1 through Tab 8 share a selector and differ by tag, so the
    /// lookup matches both fields.
    static func entry(forSelector selector: Selector, tag: Int) -> KeybindingEntry? {
        entries.first { $0.selector == selector && $0.tag == tag }
    }

    /// Whether `event` matches a catalog shortcut. Keeps a disabled
    /// catalog chord, which the menu leaves unconsumed, from falling
    /// through to the guest as HID.
    static func claims(_ event: NSEvent) -> Bool {
        entries.contains { $0.chord.matches(event) }
    }

    /// Build the menu item for an action. Target stays nil so the responder
    /// chain resolves it.
    static func makeMenuItem(_ action: KeybindingAction) -> NSMenuItem {
        guard let entry = entry(for: action) else {
            // Unreachable via the drift guard, which asserts the catalog
            // covers every case of `KeybindingAction`.
            return NSMenuItem()
        }
        let item = NSMenuItem(
            title: entry.title,
            action: entry.selector,
            keyEquivalent: entry.chord.keyEquivalent
        )
        item.keyEquivalentModifierMask = entry.chord.modifiers.nsFlags
        item.tag = entry.tag
        return item
    }
}
