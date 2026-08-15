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
        onScreen: Bool = true,
        pid: pid_t? = 100
    ) -> CandidateWindow {
        CandidateWindow(
            windowID: id,
            layer: layer,
            area: area,
            bundleID: bundleID,
            isOnScreen: onScreen,
            pid: pid
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

    // MARK: - Ambiguous targets

    /// The GUI smoke launches a second `com.deviceterm` while a harness run
    /// may be in flight, and the chooser has no way to prefer either one.
    /// Callers refuse on more than one owner rather than capture a coin flip.
    @Test
    func reportsBothOwnersWhenTwoInstancesShowContentWindows() {
        let windows = [window(1, bundleID: app, pid: 100), window(2, bundleID: app, pid: 200)]
        #expect(WindowChooser.contentOwners(from: windows, bundleID: app) == [100, 200])
    }

    @Test
    func reportsOneOwnerForSeveralWindowsOfOneInstance() {
        let windows = [window(1, bundleID: app, pid: 100), window(2, bundleID: app, pid: 100)]
        #expect(WindowChooser.contentOwners(from: windows, bundleID: app) == [100])
    }

    @Test
    func contentOwnersIgnoresOtherAppsAndOffScreenWindows() {
        let windows = [
            window(1, bundleID: other, pid: 200),
            window(2, bundleID: app, onScreen: false, pid: 300),
            window(3, bundleID: app, pid: 100)
        ]
        #expect(WindowChooser.contentOwners(from: windows, bundleID: app) == [100])
    }

    /// `contentOwners` ignores overlay-only instances, staying scoped to
    /// the windows `choose` itself considers. Process-level ambiguity is
    /// supplied separately by `TargetOwners.live`.
    @Test
    func contentOwnersIgnoresOverlayOnlyInstances() {
        let windows = [
            window(1, bundleID: app, pid: 100),
            window(2, bundleID: app, layer: WindowChooser.overlayLayer, pid: 200)
        ]
        #expect(WindowChooser.contentOwners(from: windows, bundleID: app) == [100])
    }

    /// Owner counting drops a target candidate whose pid is unavailable.
    /// Production mapping cannot create this pairing; this test pins the
    /// helper's behavior for manually constructed candidates.
    @Test
    func contentOwnersSkipsWindowsWithNoReportedOwner() {
        let windows = [window(1, bundleID: app, pid: 100), window(2, bundleID: app, pid: nil)]
        #expect(WindowChooser.contentOwners(from: windows, bundleID: app) == [100])
    }

    /// Two daemons each showing a badge: the smoke spawns its own from the
    /// bundle's LoginItems, so this is the status-item form of the same race.
    @Test
    func statusItemOwnersReportsBothDaemonsShowingABadge() {
        let windows = [
            window(1, bundleID: daemon, layer: WindowChooser.overlayLayer, pid: 100),
            window(2, bundleID: daemon, layer: WindowChooser.overlayLayer, pid: 200)
        ]
        #expect(WindowChooser.statusItemOwners(from: windows, bundleID: daemon) == [100, 200])
    }

    /// Two daemons showing *no* badge is still just "absent", so the caller
    /// reaches its hidden-item path rather than an ambiguity error.
    @Test
    func statusItemOwnersIsEmptyWhenNeitherDaemonShowsABadge() {
        let windows = [
            window(1, bundleID: daemon, layer: 0, pid: 100),
            window(2, bundleID: daemon, layer: 0, pid: 200)
        ]
        #expect(WindowChooser.statusItemOwners(from: windows, bundleID: daemon).isEmpty)
    }
}
