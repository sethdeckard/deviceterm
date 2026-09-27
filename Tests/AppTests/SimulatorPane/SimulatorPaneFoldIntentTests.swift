// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import DaemonProtocol
import Testing

/// Every fold surface goes through one intent on the view controller.
///
/// The slider shows the selected angle and never reads the hinge, so a menu
/// request has to update that selection too. A surface that drove the device
/// without recording the angle would leave the slider contradicting a fold
/// the user had just made from the menu beside it.
@MainActor
struct SimulatorPaneFoldIntentTests {
    private static let foldable = PaneCapabilities(
        touch: true,
        key: true,
        text: true,
        button: true,
        rotate: true,
        crown: false,
        accessibility: true,
        location: true,
        fold: true
    )

    private func makeViewController() -> (SimulatorPaneViewController, FakeDaemonClient) {
        let pane = SimPaneState(
            paneId: "p1",
            udid: "U",
            displayName: "iPhone Duo",
            family: "phone",
            capabilities: Self.foldable
        )
        let fake = FakeDaemonClient()
        let viewController = SimulatorPaneViewController(
            simPane: pane,
            daemonClient: fake,
            advisory: .silent(),
            deviceHubAdvisory: .silent()
        )
        return (viewController, fake)
    }

    @Test("every menu posture moves the slider it shares with the bar", arguments: [
        (#selector(SimulatorPaneViewController.foldDeviceClosed(_:)), FoldPosture.closed),
        (#selector(SimulatorPaneViewController.foldDeviceBook(_:)), FoldPosture.book),
        (#selector(SimulatorPaneViewController.foldDeviceOpen(_:)), FoldPosture.open)
    ])
    func menuPosturesUpdateTheRequestEcho(selector: Selector, posture: FoldPosture) async {
        let (viewController, fake) = makeViewController()
        // Start somewhere the posture will move it, so a no-op would show.
        viewController.chromeViewModel.foldDegrees = 45
        viewController.perform(selector, with: nil)
        await Task.yield()
        #expect(viewController.chromeViewModel.foldDegrees == posture.degrees)
        #expect(fake.foldCalls.map(\.degrees) == [posture.degrees])
    }

    @Test("the chrome reserves a second row only while the bar is up")
    func chromeHeightFollowsTheFoldBar() {
        let (viewController, _) = makeViewController()
        viewController.loadViewIfNeeded()
        let oneRow = PaneChromeRibbonFit.chromeRowHeight
        let twoRows = oneRow + PaneChromeRibbonFit.foldBarHeight
        // A foldable pane opens the bar by itself, so it starts at two rows.
        #expect(viewController.currentChromeHeight() == twoRows)
        viewController.chromeViewModel.foldControlVisible = false
        #expect(viewController.currentChromeHeight() == oneRow)
    }

    @Test("a pane that cannot fold never reserves the second row")
    func chromeStaysOneRowWithoutTheCapability() {
        let pane = SimPaneState(
            paneId: "p2",
            udid: "U2",
            displayName: "iPhone 17 Pro",
            family: "phone",
            capabilities: .simulator
        )
        let viewController = SimulatorPaneViewController(
            simPane: pane,
            daemonClient: FakeDaemonClient(),
            advisory: .silent(),
            deviceHubAdvisory: .silent()
        )
        viewController.loadViewIfNeeded()
        // Even if something flipped the flag, the capability is the gate.
        viewController.chromeViewModel.foldControlVisible = true
        #expect(viewController.currentChromeHeight() == PaneChromeRibbonFit.chromeRowHeight)
    }

    @Test("toggling the bar takes pane focus first")
    func foldToggleFocusesThePane() {
        let (viewController, _) = makeViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewController
        // Park focus somewhere else in the window, the way a sibling terminal
        // holding it would.
        let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        viewController.view.addSubview(other)
        window.makeFirstResponder(other)
        #expect(!(window.firstResponder is SimulatorContentView))

        viewController.chromeViewModel.onFoldBarToggle()

        // Asserted by type rather than identity: the pane's content view is
        // private, and widening it for a test would be the wrong trade.
        #expect(window.firstResponder is SimulatorContentView)
        #expect(!viewController.chromeViewModel.foldControlVisible)
    }

    @Test("hiding the fold bar gives its height back to the divider")
    func foldBarToggleReappliesThePreset() {
        // Mounted in a *stacked* split on purpose. The chrome reduces the
        // pane's height either way, but only a horizontal-axis split puts
        // height on the divided axis, which is the axis the preset moves.
        // Side by side, the divider would not move and this would pass
        // having proved nothing.
        let mount = makeStackedSplit()
        mount.pane.applySizePreset(.pointAccurate)
        mount.layout()
        let twoRows = mount.paneHeight

        mount.pane.chromeViewModel.foldControlVisible = false
        mount.pane.syncChromeHeight()
        mount.layout()

        // The strip lost a row, so the pane needs that much less to show the
        // same picture at the same accuracy.
        #expect(twoRows - mount.paneHeight == PaneChromeRibbonFit.foldBarHeight)
    }

    @Test("a pane with no preset chosen keeps its extent")
    func syncWithoutAPresetChangesNothing() {
        let mount = makeStackedSplit()
        mount.layout()
        let before = mount.paneHeight
        // Nothing was pinned, so nothing gets replayed and the divider stays.
        #expect(mount.pane.chromeViewModel.selectedPreset == nil)
        mount.pane.chromeViewModel.foldControlVisible = false
        mount.pane.syncChromeHeight()
        mount.layout()
        #expect(mount.paneHeight == before)
    }

    private func makeStackedSplit() -> StackedFoldSplit {
        let pane = SimulatorPaneViewController(
            simPane: SimPaneState(
                paneId: "p1",
                udid: "U-FOLD",
                displayName: "iPhone Duo",
                family: "phone",
                pixelWidth: 1_398,
                pixelHeight: 2_034,
                capabilities: Self.foldable
            ),
            daemonClient: FakeDaemonClient(),
            advisory: .silent(),
            deviceHubAdvisory: .silent()
        )
        let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
        let controller = PaneLayoutViewController(
            tabID: TabID(value: 1),
            router: nil,
            initialTree: .split(
                axis: .vertical,
                children: [.leaf(terminal), .leaf(.sim(udid: "U-FOLD"))],
                extents: [1, 1]
            ),
            initialPaneVCs: [terminal: NSViewController(), .sim(udid: "U-FOLD"): pane]
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1_000),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 1_000))
        window.contentView = host
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return StackedFoldSplit(controller: controller, pane: pane, host: host, window: window)
    }

    @Test("the fold bar and the menus share one intent")
    func theBarGoesThroughTheSamePath() async {
        let (viewController, fake) = makeViewController()
        // Load the view to wire `onFold`; the closure is a no-op until
        // `wireChromeActions` runs.
        viewController.loadViewIfNeeded()
        viewController.chromeViewModel.onFold(137)
        await Task.yield()
        #expect(viewController.chromeViewModel.foldDegrees == 137)
        #expect(fake.foldCalls.map(\.degrees) == [137])
    }
}

/// A sim pane stacked under a stub, mounted in a window so the split's
/// divider arithmetic runs for real. The window is retained because the view
/// hierarchy does not retain its controllers, and the pane reaches the
/// layout controller through the responder chain to apply a preset.
@MainActor
private struct StackedFoldSplit {
    let controller: PaneLayoutViewController
    let pane: SimulatorPaneViewController
    let host: NSView
    let window: NSWindow

    var paneHeight: CGFloat { pane.view.frame.height }

    func layout() { host.layoutSubtreeIfNeeded() }
}
