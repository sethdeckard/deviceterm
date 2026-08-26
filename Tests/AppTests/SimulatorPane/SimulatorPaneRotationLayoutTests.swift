// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import DaemonProtocol
import Testing

/// A rotation must not move a divider. The pane keeps the extent it has
/// and the renderer aspect-fits the turned picture inside it, so a
/// landscape phone becomes a short wide strip rather than a pane that
/// grew and took the width out of whatever sits beside it.
///
/// Both tests mount the actual layout and simulator-pane controllers in
/// an NSWindow, because the claim is about divider arithmetic and the
/// preset math underneath it is already pinned by `SimSizePresetTests`.
///
/// The pane carries device pixel dimensions from the start, so an
/// orientation-triggered preset would have everything it needs to move
/// the divider. Without them the negative assertion below would pass
/// vacuously.
///
/// The second test is what keeps the first honest. A broken subscription
/// would leave the pane portrait and the divider still, so the first
/// test would pass having proved nothing. An explicit preset can only
/// produce a landscape-shaped pane if the rotation reached the pane
/// through exactly the path the first test claims moves nothing.
@MainActor
struct SimulatorPaneRotationLayoutTests {
    private static let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
    private static let sim = PaneSlot.sim(udid: "U-TEST")

    @Test
    func rotationLeavesTheDividerWhereItWas() async {
        let mount = makeMounted()
        #expect(await mount.subscribed())
        let widthBefore = mount.simWidth

        mount.rotate(to: .landscapeLeft)
        // Negative assertion, so give the would-be resize its chance
        // before confirming it never came.
        _ = await mount.poll(maxIterations: 25) { mount.simWidth != widthBefore }

        #expect(mount.simWidth == widthBefore)
        // Applying a preset stamps the chrome's selection, so a rotation
        // must not leave one selected the user never asked for.
        #expect(mount.pane.chromeViewModel.selectedPreset == nil)
    }

    @Test
    func anExplicitPresetStillFitsTheRotatedShape() async {
        let portrait = makeMounted()
        #expect(await portrait.subscribed())
        portrait.pane.applySizePreset(.fitScreen)
        portrait.layout()
        let portraitFit = portrait.simWidth

        let landscape = makeMounted()
        #expect(await landscape.subscribed())
        landscape.rotate(to: .landscapeLeft)

        // Fit Screen sizes the displayed extent, so the turned device
        // asks for a wider pane than the upright one. That difference is
        // only reachable if the orientation event landed on the pane.
        //
        // The event crosses an AsyncStream, so the pane hasn't
        // necessarily adopted it yet. Applying a preset is idempotent,
        // so ask for the fit until the rotated shape comes back; the
        // poll ends on the first pass that widens rather than running
        // out a fixed wait.
        let widened = await landscape.poll {
            landscape.pane.applySizePreset(.fitScreen)
            landscape.layout()
            return landscape.simWidth > portraitFit
        }
        #expect(widened)
    }

    /// A terminal beside a phone sim in a side-by-side split, mounted in
    /// an 800×600 window. `.horizontal` is the axis whose divider runs
    /// vertically, so the panes divide width.
    private func makeMounted() -> MountedRotationLayout {
        let fake = FakeDaemonClient()
        let pane = SimulatorPaneViewController(
            simPane: SimPaneState(
                paneId: "p1",
                udid: "U-TEST",
                displayName: "iPhone 17 Pro",
                family: "phone",
                pixelWidth: 1_206,
                pixelHeight: 2_622
            ),
            daemonClient: fake,
            advisory: .silent()
        )
        let controller = PaneLayoutViewController(
            tabID: TabID(value: 1),
            router: nil,
            initialTree: .split(
                axis: .horizontal,
                children: [.leaf(Self.terminal), .leaf(Self.sim)],
                extents: [1, 1]
            ),
            initialPaneVCs: [
                Self.terminal: StubRotationLayoutPaneViewController(),
                Self.sim: pane
            ]
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = host
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return MountedRotationLayout(
            controller: controller,
            pane: pane,
            fake: fake,
            window: window
        )
    }
}

/// Mounted pane fixture. Retaining the window keeps its hierarchy
/// attached for AppKit layout.
@MainActor
private struct MountedRotationLayout {
    /// Retained because the view hierarchy does not retain its
    /// controller. The pane reaches this controller through the
    /// responder chain to apply presets, and it also owns the split's
    /// delegate and ratio handling. Drop the reference and a preset
    /// finds nothing to ask, leaving the split laid out AppKit's way.
    let controller: PaneLayoutViewController
    let pane: SimulatorPaneViewController
    let fake: FakeDaemonClient
    let window: NSWindow

    /// Width of the sim pane's own view, which is what a moved divider
    /// changes.
    var simWidth: CGFloat { pane.view.frame.width }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Publish an orientation the way the daemon does, through the
    /// pane's own subscription.
    func rotate(to orientation: Orientation) {
        fake.lastPaneEventContinuation?.yield(
            .orientationChanged(
                OrientationChangedEvent(paneId: "p1", orientation: orientation.rawValue)
            )
        )
    }

    /// Wait for the pane's subscription to exist, since nothing can be
    /// published into it before then.
    func subscribed() async -> Bool {
        await poll { fake.lastPaneEventContinuation != nil }
    }

    func poll(maxIterations: Int = 500, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<maxIterations {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)  // 2ms
        }
        return condition()
    }
}

@MainActor
private final class StubRotationLayoutPaneViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }
}
