// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import DeviceTermUITest

@Suite("window selection for capture")
struct WindowChooserTests {
    private let app = "com.deviceterm"
    private let other = "com.apple.Safari"
    private let daemon = "com.deviceterm.daemon"

    private func window(
        _ id: UInt32,
        bundleID: String,
        layer: Int = 0,
        area: Double = 1_000,
        onScreen: Bool = true
    ) -> CandidateWindow {
        CandidateWindow(
            windowID: id,
            layer: layer,
            area: area,
            bundleID: bundleID,
            isOnScreen: onScreen
        )
    }

    @Test
    func picksTheFrontmostWindowOfTheTargetApp() {
        let windows = [window(1, bundleID: app), window(2, bundleID: app)]
        let chosen = WindowChooser.choose(from: windows, bundleID: app, frontToBack: [2, 1])
        #expect(chosen?.windowID == 2)
    }

    @Test
    func ignoresWindowsOwnedByOtherApps() {
        let windows = [window(1, bundleID: other), window(2, bundleID: app)]
        let chosen = WindowChooser.choose(from: windows, bundleID: app, frontToBack: [1, 2])
        #expect(chosen?.windowID == 2)
    }

    @Test
    func ignoresOffScreenWindows() {
        let windows = [window(1, bundleID: app, onScreen: false), window(2, bundleID: app)]
        let chosen = WindowChooser.choose(from: windows, bundleID: app, frontToBack: [1, 2])
        #expect(chosen?.windowID == 2)
    }

    /// An app-modal alert (close-tab prompt, ⌘Q) sits *above* layer 0, in
    /// front of the main window. Capturing must pick the alert, not the
    /// larger window behind it, so there is no layer-0 preference. (The
    /// old code filtered to layer 0 and so captured the window behind the
    /// prompt, the exact bug a live run surfaced.)
    @Test
    func picksAnAppModalAlertAboveTheMainWindow() {
        let mainWindow = window(1, bundleID: app, layer: 0, area: 1_000_000)
        let alert = window(2, bundleID: app, layer: 8, area: 40_000)
        let chosen = WindowChooser.choose(from: [mainWindow, alert], bundleID: app, frontToBack: [2, 1])
        #expect(chosen?.windowID == 2)
    }

    /// Overlay-layer windows (menu-bar status items, tooltips) are never
    /// document content, so `choose` skips them even when frontmost:
    /// otherwise a stray one could be mistaken for the app window.
    @Test
    func excludesOverlayLayerWindows() {
        let statusItem = window(1, bundleID: app, layer: WindowChooser.overlayLayer)
        let mainWindow = window(2, bundleID: app, layer: 0)
        let chosen = WindowChooser.choose(from: [statusItem, mainWindow], bundleID: app, frontToBack: [1, 2])
        #expect(chosen?.windowID == 2)
    }

    @Test
    func returnsNilWhenOnlyOverlayWindowsExist() {
        let statusItem = window(1, bundleID: app, layer: WindowChooser.overlayLayer)
        #expect(WindowChooser.choose(from: [statusItem], bundleID: app, frontToBack: [1]) == nil)
    }

    /// Windows absent from the window-server ordering sort last, so area
    /// is the tiebreaker and the main window wins over a small panel.
    @Test
    func breaksOrderingTiesOnLargerArea() {
        let small = window(1, bundleID: app, area: 100)
        let large = window(2, bundleID: app, area: 900)
        let chosen = WindowChooser.choose(from: [small, large], bundleID: app, frontToBack: [])
        #expect(chosen?.windowID == 2)
    }

    @Test
    func returnsNilWhenTheAppHasNoOnScreenWindows() {
        let windows = [window(1, bundleID: other), window(2, bundleID: app, onScreen: false)]
        #expect(WindowChooser.choose(from: windows, bundleID: app, frontToBack: [1, 2]) == nil)
    }

    // MARK: - Status item

    /// The status item is the daemon's overlay-layer window; `chooseStatusItem`
    /// finds it while `choose` (content windows) correctly ignores it.
    @Test
    func statusItemPicksTheDaemonOverlayWindow() {
        let badge = window(1, bundleID: daemon, layer: WindowChooser.overlayLayer, area: 900)
        let chosen = WindowChooser.chooseStatusItem(from: [badge], bundleID: daemon, frontToBack: [1])
        #expect(chosen?.windowID == 1)
    }

    /// No overlay window for the daemon == the status item is hidden (zero
    /// owned booted sims). The caller reads nil as "absent", not an error.
    @Test
    func statusItemNilWhenDaemonHasNoOverlayWindow() {
        let content = window(1, bundleID: daemon, layer: 0)
        #expect(WindowChooser.chooseStatusItem(from: [content], bundleID: daemon, frontToBack: [1]) == nil)
    }

    /// If the status *menu* is open too, the smaller window (the badge
    /// button, not the dropdown) is captured.
    @Test
    func statusItemPrefersTheSmallerButtonOverAnOpenMenu() {
        let menu = window(1, bundleID: daemon, layer: WindowChooser.overlayLayer, area: 40_000)
        let button = window(2, bundleID: daemon, layer: WindowChooser.overlayLayer, area: 900)
        // Menu is frontmost, but the smaller button wins.
        let chosen = WindowChooser.chooseStatusItem(from: [menu, button], bundleID: daemon, frontToBack: [1, 2])
        #expect(chosen?.windowID == 2)
    }

    @Test
    func statusItemIgnoresOtherAppsMenuBarItems() {
        let otherItem = window(1, bundleID: other, layer: WindowChooser.overlayLayer)
        #expect(WindowChooser.chooseStatusItem(from: [otherItem], bundleID: daemon, frontToBack: [1]) == nil)
    }
}
