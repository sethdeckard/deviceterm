// SPDX-License-Identifier: GPL-3.0-or-later

/// The canonical identity of every bound action.
///
/// Kebab-case raw values are stable, selector-independent identifiers, so
/// the drift guard keys on an identity a selector rename cannot silently
/// break.
///
/// The drift guard depends on `CaseIterable`: it asserts the catalog's
/// action set equals this enum's case set, as `DaemonTests` asserts the
/// RPC registry's keys equal `RPCMethod`'s cases, so an action added here
/// without a catalog entry fails the test gate.
///
/// REFACTOR: a `keybind = ...` config parser could read these raw values
/// as its right-hand vocabulary. Nothing consumes them that way today.
enum KeybindingAction: String, CaseIterable, Sendable {
    // Application
    case openSettings = "open-settings"
    case hideApp = "hide-app"
    case hideOthers = "hide-others"
    case quit

    // Tabs, windows, and session lifecycle
    case newWindow = "new-window"
    case newTab = "new-tab"
    case openAutomationTab = "open-automation-tab"
    case closePane = "close-pane"
    case closeTab = "close-tab"
    case closeWindow = "close-window"
    case minimize

    // Editing
    case cut
    case copy
    case paste
    case selectAll = "select-all"
    case clearBuffer = "clear-buffer"

    // Tab navigation. `selectTab1` through `selectTab8` address a
    // position; `selectLastTab` addresses the end of the strip, which is
    // why ⌘9 is not simply "tab 9".
    case selectTab1 = "select-tab-1"
    case selectTab2 = "select-tab-2"
    case selectTab3 = "select-tab-3"
    case selectTab4 = "select-tab-4"
    case selectTab5 = "select-tab-5"
    case selectTab6 = "select-tab-6"
    case selectTab7 = "select-tab-7"
    case selectTab8 = "select-tab-8"
    case selectLastTab = "select-last-tab"
    case selectPreviousTab = "select-previous-tab"
    case selectNextTab = "select-next-tab"

    // Splits
    case splitRight = "split-right"
    case splitDown = "split-down"

    // Pane navigation. The numbered pair walks display order; the four
    // arrows walk the visible grid.
    case selectPreviousPane = "select-previous-pane"
    case selectNextPane = "select-next-pane"
    case selectPaneLeft = "select-pane-left"
    case selectPaneRight = "select-pane-right"
    case selectPaneAbove = "select-pane-above"
    case selectPaneBelow = "select-pane-below"

    // Pane and tab arrangement
    case movePaneLeft = "move-pane-left"
    case movePaneRight = "move-pane-right"
    case moveTabLeft = "move-tab-left"
    case moveTabRight = "move-tab-right"
    case toggleSplitDirection = "toggle-split-direction"

    // Presentation
    case zoomIn = "zoom-in"
    case zoomOut = "zoom-out"
    case resetZoom = "reset-zoom"
    case toggleFullScreen = "toggle-full-screen"
    case toggleAxInspector = "toggle-ax-inspector"

    // Device controls. On the keyboard path these require device-pane
    // focus, so a terminal-focused mixed tab keeps the chords.
    case deviceHome = "device-home"
    case deviceLock = "device-lock"
    case deviceRotateLeft = "device-rotate-left"
    case deviceRotateRight = "device-rotate-right"
    case deviceScreenshot = "device-screenshot"
    case deviceRecord = "device-record"

    // Device pane size presets
    case sizePresetPhysical = "size-preset-physical"
    case sizePresetPointAccurate = "size-preset-point-accurate"
    case sizePresetPixelAccurate = "size-preset-pixel-accurate"
    case sizePresetFitScreen = "size-preset-fit-screen"
}
