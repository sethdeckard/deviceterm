// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol
import Testing

@testable import App

/// A rearrange moves panes, not dividers. Dragging a pane to the other
/// side of its split has to take its width along, or the two panes trade
/// extents and a narrow sim arrives wide.
///
/// The claim is about divider arithmetic reaching real `NSSplitView`
/// frames, so these mount the controller in a window rather than testing
/// the mapping alone; `PaneRatioRemapTests` pins the mapping. What only a
/// mounted test can catch is the ordering inside `reconcile`: a remap
/// that lands after the seed pass, or after the hierarchy rebuild,
/// computes the right numbers and applies none of them.
///
/// Device-backed slots hold real `SimulatorPaneViewController`s rather
/// than stubs. A stub is not merely a simpler pane, it is a pane with no
/// size preset: `reconcile` arms an auto-fit for a sim that arrives in a
/// new parent, and the preset that lands afterwards is what decides that
/// pane's width. A suite built on stubs would report a preserved divider
/// for arrangements where the shipping app moves one.
@MainActor
struct PaneLayoutRatioReorderTests {
    /// Controller plus the window keeping it alive, since a released
    /// window takes the view hierarchy with it. The controller is
    /// retained for the same reason the rotation suite retains it: a
    /// pane reaches it through the responder chain to apply a preset.
    @MainActor
    private struct Mounted {
        let controller: PaneLayoutViewController
        let window: NSWindow

        var rootSplit: NSSplitView? {
            controller.view.subviews.first as? NSSplitView
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
        }

        /// Put a divider at `position` and let the layout settle.
        /// `setPosition` fires the same resize notification a user's
        /// drag does, so the ratio store captures it either way.
        func setDivider(at index: Int, to position: CGFloat) async {
            rootSplit?.setPosition(position, ofDividerAt: index)
            await settle()
        }

        /// Lay out repeatedly so an auto-fit has every chance to land.
        /// The assertions below are mostly negative (the divider did not
        /// move), and a preset that arrives one pass later than the
        /// measurement would leave them passing for the wrong reason.
        func settle() async {
            for _ in 0..<30 {
                layout()
                try? await Task.sleep(nanoseconds: 2_000_000)  // 2ms
            }
            layout()
        }

        func width(of slot: PaneSlot) -> CGFloat {
            controller.slotFrames()[slot]?.width ?? 0
        }

        func height(of slot: PaneSlot) -> CGFloat {
            controller.slotFrames()[slot]?.height ?? 0
        }

        func minX(of slot: PaneSlot) -> CGFloat {
            controller.slotFrames()[slot]?.minX ?? 0
        }
    }

    private static let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
    private static let sim = PaneSlot.sim(udid: "U-TEST")
    private static let device = PaneSlot.device(deviceId: "D-TEST")
    private static let pendingID = PendingPaneID(value: 7)
    private static let pending = PaneSlot.pending(pendingID)

    // MARK: - The rearrange carries the width

    @Test
    func draggingASimAcrossTheDividerTakesItsWidthWithIt() async {
        let mount = await makeMounted(slots: [Self.terminal, Self.sim])
        await mount.setDivider(at: 0, to: 1_000)

        // Assert the arrangement the claim is about before making it.
        // The delegate clamps a divider against each pane's minimum, so
        // a window too narrow to hold this split would leave the panes
        // near even and the real assertions would pass having proved
        // nothing.
        let simBefore = mount.width(of: Self.sim)
        let terminalBefore = mount.width(of: Self.terminal)
        #expect(simBefore < terminalBefore / 2)

        mount.controller.reconcile(
            tree: horizontal([Self.sim, Self.terminal]),
            pendingTargets: [:]
        ) { _ in nil }
        await mount.settle()

        #expect(abs(mount.width(of: Self.sim) - simBefore) < 1)
        #expect(abs(mount.width(of: Self.terminal) - terminalBefore) < 1)
        // And it really did move, rather than the reconcile no-oping.
        #expect(mount.minX(of: Self.sim) < mount.minX(of: Self.terminal))
    }

    @Test
    func droppingASimBelowItsNeighborRebuildsTheDividerForTheNewAxis() async {
        let mount = await makeMounted(slots: [Self.terminal, Self.sim], height: 900)
        await mount.setDivider(at: 0, to: 1_000)
        #expect(mount.width(of: Self.sim) < mount.width(of: Self.terminal) / 2)

        mount.controller.reconcile(
            tree: .split(
                axis: .vertical,
                children: [.leaf(Self.terminal), .leaf(Self.sim)],
                extents: [1, 1]
            ),
            pendingTargets: [:]
        ) { _ in nil }
        await mount.settle()

        // A share of width is not a share of height. Carried over, the
        // sim's 0.29 would leave it the shorter pane; reseeded from
        // natural extents it is the taller one.
        #expect(mount.height(of: Self.sim) > mount.height(of: Self.terminal))
    }

    // MARK: - Replacing a leaf in place

    @Test
    func aPlaceholderBecomingADevicePaneKeepsTheDivider() async {
        // Helper recovery and the post-reboot resurrect swap a pane's
        // leaf for a placeholder and back, and depend on the divider
        // not moving underneath them. A device pane is where that
        // depends on the remap alone: `reconcile` arms its auto-fit for
        // sim slots only, so nothing else here can put the divider back.
        let mount = await makeMounted(
            slots: [Self.terminal, Self.pending],
            pendingTargets: [Self.pendingID: .device(deviceId: "D-TEST")]
        )
        await mount.setDivider(at: 0, to: 1_000)
        let widthBefore = mount.width(of: Self.pending)
        #expect(widthBefore < mount.width(of: Self.terminal) / 2)

        mount.controller.reconcile(
            tree: horizontal([Self.terminal, Self.device]),
            pendingTargets: [:]
        ) { _ in makeDevicePane() }
        await mount.settle()

        #expect(abs(mount.width(of: Self.device) - widthBefore) < 1)
    }

    @Test
    func aPlaceholderBecomingASimPaneIsSizedByItsOwnPreset() async {
        // The sim counterpart of the case above, and it does not hold
        // the divider. A sim arriving where no sim was is armed for
        // auto-fit, and the preset it applies once pixel dimensions land
        // is the last word on its width. Recorded so the remap isn't
        // read as the authority on a path it doesn't decide.
        let mount = await makeMounted(
            slots: [Self.terminal, Self.pending],
            pendingTargets: [Self.pendingID: .sim(udid: "U-TEST")]
        )
        await mount.setDivider(at: 0, to: 1_000)
        let widthBefore = mount.width(of: Self.pending)

        mount.controller.reconcile(
            tree: horizontal([Self.terminal, Self.sim]),
            pendingTargets: [:]
        ) { _ in makeSimPane() }
        await mount.settle()

        let after = mount.width(of: Self.sim)
        #expect(after != widthBefore)
        // Fit Screen on a portrait phone in a 600pt-tall pane asks for
        // less than a phone pane's floor, so the preset lands on the
        // floor itself.
        #expect(after == PaneLayoutViewController.simMinThickness(family: .phone, isVertical: true))
    }

    // MARK: - Harness

    /// `slots` side by side in a window wide enough to hold them well
    /// off centre. Device-backed slots get the pane controller the app
    /// builds for them; 1400 leaves a 71/29 split reachable, where the
    /// 800 the other mounted suites use would clamp against the 380 and
    /// 320 point pane floors.
    ///
    /// Only the first slot is mounted up front; the rest arrive through
    /// a `reconcile`, which is the one way a pane reaches a tab in the
    /// app. `reconcile` decides a sim's auto-fit by diffing against the
    /// paths it recorded on the previous pass, so a sim installed
    /// straight through `init` reads as newly attached on the very next
    /// call and re-fits where the shipping app would leave it alone.
    private func makeMounted(
        slots: [PaneSlot],
        pendingTargets: [PendingPaneID: PaneTarget] = [:],
        width: CGFloat = 1_400,
        height: CGFloat = 600
    ) async -> Mounted {
        let controller = PaneLayoutViewController(
            tabID: TabID(value: 1),
            router: nil,
            initialTree: .leaf(slots[0]),
            initialPaneVCs: [slots[0]: makePane(for: slots[0])]
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = host
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        let mount = Mounted(controller: controller, window: window)
        guard slots.count > 1 else { return mount }
        controller.reconcile(
            tree: horizontal(slots),
            pendingTargets: pendingTargets
        ) { slot in makePane(for: slot) }
        // Let the attach's own auto-fit land before the test touches the
        // divider, so what a later rearrange must not disturb is a
        // settled width rather than one still on its way.
        await mount.settle()
        return mount
    }

    private func makePane(for slot: PaneSlot) -> NSViewController {
        switch slot {
        case .sim:
            return makeSimPane()

        case .device:
            return makeDevicePane()

        case .terminal, .pending:
            return StubReorderPaneViewController()
        }
    }

    /// Pixel dimensions are supplied from the start, since a pane
    /// without them can't auto-fit and the negative assertions would
    /// hold for a reason that has nothing to do with the remap.
    private func makeSimPane() -> SimulatorPaneViewController {
        SimulatorPaneViewController(
            simPane: SimPaneState(
                paneId: "p-sim",
                udid: "U-TEST",
                displayName: "iPhone 17 Pro",
                family: "phone",
                pixelWidth: 1_206,
                pixelHeight: 2_622
            ),
            daemonClient: FakeDaemonClient(),
            advisory: .silent()
        )
    }

    private func makeDevicePane() -> SimulatorPaneViewController {
        SimulatorPaneViewController(
            mirroredPane: DevicePaneState(
                paneId: "p-device",
                deviceId: "D-TEST",
                displayName: "iPhone",
                family: "phone",
                pixelWidth: 1_206,
                pixelHeight: 2_622
            ),
            daemonClient: FakeDaemonClient(),
            advisory: .silent()
        )
    }

    private func horizontal(_ slots: [PaneSlot]) -> PaneNode {
        guard slots.count > 1 else { return .leaf(slots[0]) }
        return .split(
            axis: .horizontal,
            children: slots.map { PaneNode.leaf($0) },
            extents: slots.map { _ in 1 }
        )
    }
}

/// Stands in for a terminal or placeholder pane, neither of which
/// carries a size preset, so nothing about their width is faked here.
@MainActor
private final class StubReorderPaneViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }
}
