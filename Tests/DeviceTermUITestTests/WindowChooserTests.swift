// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import DeviceTermUITest

@Suite("window selection for capture")
struct WindowChooserTests {
    private let app = "com.deviceterm"
    private let other = "com.apple.Safari"

    /// `frame` wins when given; otherwise `area` synthesises one, so the
    /// content-window tests stay written in the terms they care about.
    private func window(
        _ id: UInt32,
        bundleID: String?,
        layer: Int = 0,
        area: Double = 1_000,
        onScreen: Bool = true,
        pid: pid_t? = 100,
        frame: CGRect? = nil
    ) -> CandidateWindow {
        CandidateWindow(
            windowID: id,
            layer: layer,
            frame: frame ?? CGRect(x: 0, y: 0, width: area, height: 1),
            bundleID: bundleID,
            isOnScreen: onScreen,
            pid: pid
        )
    }

    /// A menu-bar extra as the window server reports it: Control Center's
    /// process, a configurable layer, and a small rect at `x` along the top
    /// of the bar.
    private func statusWindow(
        _ id: UInt32,
        x: Double,
        width: Double = 42,
        layer: Int = WindowChooser.overlayLayer
    ) -> CandidateWindow {
        CandidateWindow(
            windowID: id,
            layer: layer,
            frame: CGRect(x: x, y: 0, width: width, height: 24),
            bundleID: "com.apple.controlcenter",
            isOnScreen: true,
            pid: 692
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

    /// The badge is selected by geometry against its accessibility frame.
    /// Ownership cannot find it: macOS hosts every menu-bar extra in
    /// Control Center's process, so every candidate here carries Control
    /// Center's pid and bundle id, exactly as the window server reports.
    @Test
    func statusItemPicksTheWindowHostingTheAXFrame() {
        let badge = statusWindow(1, x: 2_890)
        let axFrame = CGRect(x: 2_895, y: 2, width: 32, height: 20)
        #expect(WindowChooser.chooseStatusItem(from: [badge], axFrame: axFrame)?.windowID == 1)
    }

    /// The real menu bar: about ten Control Center-owned extras coexist, and
    /// geometry picks the one containing the AX frame.
    @Test
    func statusItemPicksOneOfManyMenuBarExtras() {
        let extras = (0..<10).map { index in
            statusWindow(UInt32(index + 1), x: 2_890 + Double(index) * 42)
        }
        // Falls inside the fourth extra: 2890 + 3*42 = 3016, width 42.
        let axFrame = CGRect(x: 3_020, y: 2, width: 30, height: 20)
        #expect(WindowChooser.chooseStatusItem(from: extras, axFrame: axFrame)?.windowID == 4)
    }

    /// The hosting window need not share the item's bounds, so the match is
    /// containment of the AX frame's centre, never rect equality.
    @Test
    func statusItemMatchesAHostWindowLargerThanTheAXElement() {
        let badge = statusWindow(1, x: 2_880, width: 60)
        let axFrame = CGRect(x: 2_900, y: 4, width: 20, height: 16)
        #expect(WindowChooser.chooseStatusItem(from: [badge], axFrame: axFrame)?.windowID == 1)
    }

    /// If the status *menu* is open too, the badge button is captured
    /// rather than the dropdown: the menu is far taller than the item, so
    /// the size bound excludes it even though it is frontmost and also
    /// covers the point.
    @Test
    func statusItemPrefersTheSmallerButtonOverAnOpenMenu() {
        let button = statusWindow(1, x: 2_890)
        let menu = CandidateWindow(
            windowID: 2,
            layer: 101,
            frame: CGRect(x: 2_700, y: 0, width: 300, height: 400),
            bundleID: "com.apple.controlcenter",
            isOnScreen: true,
            pid: 692
        )
        let axFrame = CGRect(x: 2_895, y: 2, width: 32, height: 20)
        // The menu is frontmost and also contains the point; the smaller
        // button still wins.
        #expect(WindowChooser.chooseStatusItem(from: [menu, button], axFrame: axFrame)?.windowID == 1)
    }

    /// A published item that no window hosts: the badge was crowded out of
    /// the bar. The caller reads nil as "absent", not an error.
    @Test
    func statusItemNilWhenNoWindowHostsTheAXFrame() {
        let elsewhere = statusWindow(1, x: 100)
        let axFrame = CGRect(x: 2_895, y: 2, width: 32, height: 20)
        #expect(WindowChooser.chooseStatusItem(from: [elsewhere], axFrame: axFrame) == nil)
    }

    /// A full-screen content window contains any menu-bar point, so without
    /// a size bound the capture would be the window behind the bar.
    @Test
    func statusItemIgnoresWindowsFarTallerThanTheItem() {
        let fullScreen = window(
            1,
            bundleID: app,
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 3_456, height: 2_234)
        )
        let axFrame = CGRect(x: 2_895, y: 2, width: 32, height: 20)
        #expect(WindowChooser.chooseStatusItem(from: [fullScreen], axFrame: axFrame) == nil)
    }

    /// Eligibility must not depend on `windowLayer`: ScreenCaptureKit does
    /// not report menu-extra layers consistently, and a layer test would
    /// reject the very window the capture wants. A badge reported at the
    /// content layer is still the badge.
    @Test
    func statusItemAcceptsAHostReportedAtAnyLayer() {
        let axFrame = CGRect(x: 2_895, y: 2, width: 32, height: 20)
        for layer in [0, 8, WindowChooser.overlayLayer, 101] {
            let badge = statusWindow(1, x: 2_890, layer: layer)
            #expect(WindowChooser.chooseStatusItem(from: [badge], axFrame: axFrame)?.windowID == 1)
        }
    }

    /// Two plausible hosts overlapping the same point: the smaller wins.
    @Test
    func statusItemBreaksTiesOnSmallerArea() {
        let wide = statusWindow(1, x: 2_880, width: 80)
        let narrow = statusWindow(2, x: 2_888, width: 40)
        let axFrame = CGRect(x: 2_900, y: 2, width: 16, height: 20)
        let chosen = WindowChooser.chooseStatusItem(from: [wide, narrow], axFrame: axFrame)
        #expect(chosen?.windowID == 2)
    }

    @Test
    func statusItemIgnoresZeroAreaWindows() {
        let empty = statusWindow(1, x: 2_890, width: 0)
        let axFrame = CGRect(x: 2_890, y: 2, width: 0, height: 20)
        #expect(WindowChooser.chooseStatusItem(from: [empty], axFrame: axFrame) == nil)
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
}
