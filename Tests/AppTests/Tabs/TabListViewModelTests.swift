// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// TabListViewModel: append/select/remove + sim-pane bookkeeping,
/// and the pure close-index-follow selection math.
@MainActor
struct TabListViewModelTests {
    private func tab(_ value: Int) -> TabState {
        TabState(
            id: TabID(value: value),
            terminals: [
                TerminalPaneState(
                id: TerminalPaneID(value: value),
                sessionId: "S\(value)",
                capability: "C\(value)"
            )
            ],
            simPanes: []
        )
    }

    @Test
    func appendSelectsNewTab() {
        let model = TabListViewModel()
        model.append(tab(1))
        model.append(tab(2))
        #expect(model.tabs.map(\.id) == [TabID(value: 1), TabID(value: 2)])
        #expect(model.selectedIndex == 1)
    }

    @Test
    func removeFollowsSelection() {
        let model = TabListViewModel()
        [1, 2, 3].forEach { model.append(tab($0)) }
        model.select(id: TabID(value: 2))   // select middle (index 1)
        model.removeTab(id: TabID(value: 1))  // remove left of selection
        #expect(model.tabs.map(\.id) == [TabID(value: 2), TabID(value: 3)])
        #expect(model.selectedIndex == 0)   // followed down one
    }

    @Test
    func removeLastTabClearsSelection() {
        let model = TabListViewModel()
        model.append(tab(1))
        model.removeTab(id: TabID(value: 1))
        #expect(model.tabs.isEmpty)
        #expect(model.selectedIndex == nil)
    }

    @Test
    func moveReordersWithinBounds() {
        let model = TabListViewModel()
        [1, 2, 3].forEach { model.append(tab($0)) }
        model.move(id: TabID(value: 1), toIndex: 2)
        #expect(model.tabs.map(\.id.value) == [2, 3, 1])
    }

    @Test
    func moveToEndsClampsWithoutLosingTabs() {
        let model = TabListViewModel()
        [1, 2, 3].forEach { model.append(tab($0)) }
        model.move(id: TabID(value: 2), toIndex: 99)   // past the end → last slot
        #expect(model.tabs.map(\.id.value) == [1, 3, 2])
        model.move(id: TabID(value: 2), toIndex: -5)    // before the start → first slot
        #expect(model.tabs.map(\.id.value) == [2, 1, 3])
    }

    @Test
    func movePreservesSelectionByIdentity() {
        let model = TabListViewModel()
        [1, 2, 3].forEach { model.append(tab($0)) }
        model.select(id: TabID(value: 2))               // selection on tab 2 (index 1)
        model.move(id: TabID(value: 1), toIndex: 2)     // move a non-selected tab
        #expect(model.tabs.map(\.id.value) == [2, 3, 1])
        #expect(model.selectedIndex == 0)               // tab 2 followed to its new slot
    }

    @Test
    func moveOfSelectedTabKeepsItSelected() {
        let model = TabListViewModel()
        [1, 2, 3].forEach { model.append(tab($0)) }
        model.select(id: TabID(value: 1))               // selected tab is the one we move
        model.move(id: TabID(value: 1), toIndex: 2)
        #expect(model.tabs.map(\.id.value) == [2, 3, 1])
        #expect(model.selectedIndex == 2)
    }

    @Test
    func detachReturnsStateAndFollowsSelection() {
        let model = TabListViewModel()
        [1, 2, 3].forEach { model.append(tab($0)) }
        model.select(id: TabID(value: 2))               // index 1
        let detached = model.detach(id: TabID(value: 1))  // remove left of selection
        #expect(detached?.id == TabID(value: 1))
        #expect(model.tabs.map(\.id.value) == [2, 3])
        #expect(model.selectedIndex == 0)               // followed down one
        #expect(model.detach(id: TabID(value: 99)) == nil)  // absent → nil
    }

    @Test
    func insertSelectsByDefaultAndCanPreserveSelection() {
        let model = TabListViewModel()
        [1, 2].forEach { model.append(tab($0)) }
        model.select(id: TabID(value: 1))               // index 0
        model.insert(tab(3), at: 0)                     // default select == true
        #expect(model.tabs.map(\.id.value) == [3, 1, 2])
        #expect(model.selectedIndex == 0)               // the inserted tab is active
        model.insert(tab(4), at: 0, select: false)      // insert before selection
        #expect(model.tabs.map(\.id.value) == [4, 3, 1, 2])
        #expect(model.selectedIndex == 1)               // tab 3 stayed selected, index shifted
    }

    @Test
    func simPaneBookkeeping() {
        let model = TabListViewModel()
        model.append(tab(1))
        let pane = SimPaneState(
            paneId: "p1",
            udid: "U",
            displayName: "iPhone",
            family: "phone"
        )
        model.addSimPane(pane, toTab: TabID(value: 1))
        #expect(model.tab(id: TabID(value: 1))?.simPanes.map(\.udid) == ["U"])
        model.removeSimPane(udid: "U", fromTab: TabID(value: 1))
        #expect(model.tab(id: TabID(value: 1))?.simPanes.isEmpty == true)
    }

    @Test
    func devicePaneBookkeeping() {
        // A device pane lands in both the typed `devicePanes` array and
        // the layout tree (as a `.device` leaf), and removal drops it
        // from both, in parity with the sim path.
        let model = TabListViewModel()
        model.append(tab(1))
        let pane = DevicePaneState(
            paneId: "dp1",
            deviceId: "fd00::1",
            displayName: "iPhone 16 Pro",
            family: "phone"
        )
        model.addDevicePane(pane, toTab: TabID(value: 1))
        #expect(model.tab(id: TabID(value: 1))?.devicePanes.map(\.deviceId) == ["fd00::1"])
        let treeAfterAdd = model.tab(id: TabID(value: 1)).map { PaneTreeOps.leavesInOrder($0.paneTree) }
        #expect(treeAfterAdd?.contains(.device(deviceId: "fd00::1")) == true)
        model.removeDevicePane(deviceId: "fd00::1", fromTab: TabID(value: 1))
        #expect(model.tab(id: TabID(value: 1))?.devicePanes.isEmpty == true)
        let treeAfterRemove = model.tab(id: TabID(value: 1)).map { PaneTreeOps.leavesInOrder($0.paneTree) }
        #expect(treeAfterRemove?.contains(.device(deviceId: "fd00::1")) == false)
    }

    @Test
    func addDevicePaneIsIdempotentByDeviceID() {
        // The picker / CLI / shim attach paths can all target the same
        // connected device; without this guard each Router callback
        // would append a second `DevicePaneState` and the GUI would
        // render two mirrors of one device.
        let model = TabListViewModel()
        model.append(tab(1))
        let pane = DevicePaneState(
            paneId: "dp1",
            deviceId: "fd00::1",
            displayName: "iPhone 16 Pro",
            family: "phone"
        )
        model.addDevicePane(pane, toTab: TabID(value: 1))
        model.addDevicePane(pane, toTab: TabID(value: 1))
        #expect(model.tab(id: TabID(value: 1))?.devicePanes.count == 1)
    }

    @Test
    func addSimPaneIsIdempotentByUDID() {
        // Racing attach paths (discovery vs. an explicit
        // `deviceterm device attach`) both round-trip through
        // `daemon.device.attach`; daemon-side dedup returns the
        // same paneId to both, but without this model-layer guard
        // each Router callback still appends a `SimPaneState` and
        // the GUI ends up rendering two MTKViews for one sim.
        let model = TabListViewModel()
        model.append(tab(1))
        let pane = SimPaneState(
            paneId: "p1",
            udid: "U",
            displayName: "iPhone",
            family: "phone"
        )
        model.addSimPane(pane, toTab: TabID(value: 1))
        model.addSimPane(pane, toTab: TabID(value: 1))
        #expect(model.tab(id: TabID(value: 1))?.simPanes.count == 1)
    }

    @Test
    func addSimPaneDedupsAcrossUDIDCase() {
        // Daemon-canonicalized lowercased udid from one attach path
        // and simctl-uppercase from another point at the same sim;
        // case-insensitive compare is the piece that
        // makes the dedup correct in mixed-case storage scenarios.
        let model = TabListViewModel()
        model.append(tab(1))
        let upper = SimPaneState(
            paneId: "p1",
            udid: "ABCDEFAB-1234-5678-9ABC-DEFABCDEF012",
            displayName: "iPhone",
            family: "phone"
        )
        let lower = SimPaneState(
            paneId: "p1",
            udid: "abcdefab-1234-5678-9abc-defabcdef012",
            displayName: "iPhone",
            family: "phone"
        )
        model.addSimPane(upper, toTab: TabID(value: 1))
        model.addSimPane(lower, toTab: TabID(value: 1))
        #expect(model.tab(id: TabID(value: 1))?.simPanes.count == 1)
    }

    @Test
    func selectionAfterCloseFollowLogic() {
        // Remove left of selection → shift down.
        #expect(
            TabListViewModel.selectionAfterClose(
            removing: 0,
            selected: 2,
            remainingCount: 3
        ) == 1
            )
        // Remove the selection itself → stay on the right neighbor (clamped).
        #expect(
            TabListViewModel.selectionAfterClose(
            removing: 2,
            selected: 2,
            remainingCount: 2
        ) == 1
            )
        // Remove right of selection → unchanged.
        #expect(
            TabListViewModel.selectionAfterClose(
            removing: 2,
            selected: 0,
            remainingCount: 2
        ) == 0
            )
        // Nothing left → nil.
        #expect(
            TabListViewModel.selectionAfterClose(
            removing: 0,
            selected: 0,
            remainingCount: 0
        ) == nil
            )
    }

    // MARK: - Pending panes

    private func pending(_ value: Int, udid: String = "U") -> PendingPaneState {
        PendingPaneState(
            id: PendingPaneID(value: value),
            target: .sim(udid: udid),
            displayName: "iPhone"
        )
    }

    @Test
    func addPendingPaneInsertsLeafNextToSpawningTerminal() {
        let model = TabListViewModel()
        model.append(tab(1))
        model.addPendingPane(
            pending(1),
            toTab: TabID(value: 1),
            spawningTerminal: TerminalPaneID(value: 1)
        )
        let leaves = model.tab(id: TabID(value: 1)).map { PaneTreeOps.leavesInOrder($0.paneTree) }
        #expect(leaves == [.terminal(TerminalPaneID(value: 1)), .pending(PendingPaneID(value: 1))])
        #expect(model.tab(id: TabID(value: 1))?.pendingPanes.count == 1)
    }

    @Test
    func replacePendingWithSimSwapsLeafAndArray() {
        let model = TabListViewModel()
        model.append(tab(1))
        model.addPendingPane(pending(1), toTab: TabID(value: 1))
        let sim = SimPaneState(paneId: "p1", udid: "U", displayName: "iPhone", family: "phone")
        model.replacePendingWithSim(id: PendingPaneID(value: 1), pane: sim, inTab: TabID(value: 1))
        let tabState = model.tab(id: TabID(value: 1))
        #expect(tabState?.pendingPanes.isEmpty == true)
        #expect(tabState?.simPanes.map(\.udid) == ["U"])
        let leaves = tabState.map { PaneTreeOps.leavesInOrder($0.paneTree) }
        #expect(leaves?.contains(.sim(udid: "U")) == true)
        #expect(leaves?.contains(.pending(PendingPaneID(value: 1))) == false)
    }

    @Test
    func replacePendingWithSimPreservesTreePosition() {
        let model = TabListViewModel()
        model.append(tab(1))
        // Two terminals so the pending lands between them (index 1).
        model.addTerminal(
            TerminalPaneState(id: TerminalPaneID(value: 2), sessionId: "S2", capability: "C2"),
            toTab: TabID(value: 1)
        )
        model.addPendingPane(
            pending(9),
            toTab: TabID(value: 1),
            spawningTerminal: TerminalPaneID(value: 1)
        )
        let before = model.tab(id: TabID(value: 1)).map { PaneTreeOps.leavesInOrder($0.paneTree) } ?? []
        guard let pendingIndex = before.firstIndex(of: .pending(PendingPaneID(value: 9))) else {
            Issue.record("expected the pending leaf in the tree")
            return
        }
        let sim = SimPaneState(paneId: "p1", udid: "U", displayName: "iPhone", family: "phone")
        model.replacePendingWithSim(id: PendingPaneID(value: 9), pane: sim, inTab: TabID(value: 1))
        let after = model.tab(id: TabID(value: 1)).map { PaneTreeOps.leavesInOrder($0.paneTree) } ?? []
        #expect(after[pendingIndex] == .sim(udid: "U"))
    }

    @Test
    func failThenRetryFlipsPendingPhase() {
        let model = TabListViewModel()
        model.append(tab(1))
        model.addPendingPane(pending(1), toTab: TabID(value: 1))
        model.failPendingPane(id: PendingPaneID(value: 1), message: "boom", inTab: TabID(value: 1))
        #expect(model.tab(id: TabID(value: 1))?.pendingPanes.first?.phase == .failed("boom"))
        model.retryPendingPane(id: PendingPaneID(value: 1), inTab: TabID(value: 1))
        #expect(model.tab(id: TabID(value: 1))?.pendingPanes.first?.phase == .attaching)
    }

    @Test
    func removePendingPaneDropsLeaf() {
        let model = TabListViewModel()
        model.append(tab(1))
        model.addPendingPane(pending(1), toTab: TabID(value: 1))
        model.removePendingPane(id: PendingPaneID(value: 1), fromTab: TabID(value: 1))
        #expect(model.tab(id: TabID(value: 1))?.pendingPanes.isEmpty == true)
        let leaves = model.tab(id: TabID(value: 1)).map { PaneTreeOps.leavesInOrder($0.paneTree) }
        #expect(leaves?.contains(.pending(PendingPaneID(value: 1))) == false)
    }

    @Test
    func isTargetPresentMatchesMountedPendingAndCaseInsensitiveUDID() {
        var tabState = tab(1)
        tabState.simPanes = [
            SimPaneState(paneId: "p", udid: "abc", displayName: "x", family: "phone")
        ]
        // Mounted sim, case-insensitive.
        #expect(TabListViewModel.isTargetPresent(.sim(udid: "ABC"), in: tabState))
        #expect(!TabListViewModel.isTargetPresent(.sim(udid: "other"), in: tabState))
        #expect(!TabListViewModel.isTargetPresent(.device(deviceId: "d"), in: tabState))
        // A pending device target also counts as present.
        tabState.pendingPanes = [
            PendingPaneState(
                id: PendingPaneID(value: 1),
                target: .device(deviceId: "d"),
                displayName: nil
            )
        ]
        #expect(TabListViewModel.isTargetPresent(.device(deviceId: "d"), in: tabState))
    }

    // MARK: - Size preset

    @Test
    func setSizePresetTouchesOnlyTheNamedPane() {
        let model = TabListViewModel()
        model.append(tab(1))
        for udid in ["A", "B"] {
            model.addSimPane(
                SimPaneState(paneId: "p-\(udid)", udid: udid, displayName: udid, family: "phone"),
                toTab: TabID(value: 1)
            )
        }
        model.addDevicePane(
            DevicePaneState(paneId: "p-D", deviceId: "D", displayName: "iPhone", family: "phone"),
            toTab: TabID(value: 1)
        )
        model.setSizePreset(.pixelAccurate, forPane: .sim(udid: "B"), inTab: TabID(value: 1))
        model.setSizePreset(.physical, forPane: .device(deviceId: "D"), inTab: TabID(value: 1))
        let tabState = model.tab(id: TabID(value: 1))
        #expect(tabState?.simPanes.map(\.sizePreset) == [nil, .pixelAccurate])
        #expect(tabState?.devicePanes.map(\.sizePreset) == [.physical])
    }

    @Test
    func aSimPanePresetSurvivesTheRecoveryRoundTrip() {
        // The attach response carries no preset, so the placeholder is the
        // only thing holding it while the pane is away. A pane that comes back
        // without it falls back to its family default.
        let model = TabListViewModel()
        model.append(tab(1))
        model.addSimPane(
            SimPaneState(paneId: "old", udid: "A", displayName: "iPhone", family: "phone"),
            toTab: TabID(value: 1)
        )
        model.setSizePreset(.pixelAccurate, forPane: .sim(udid: "A"), inTab: TabID(value: 1))
        model.replaceSimPaneWithPending(
            udid: "A",
            pending: PendingPaneState(
                id: PendingPaneID(value: 1),
                target: .sim(udid: "A"),
                displayName: "iPhone",
                family: "phone",
                atIndex: 0
            ),
            inTab: TabID(value: 1)
        )
        #expect(model.tab(id: TabID(value: 1))?.pendingPanes.first?.sizePreset == .pixelAccurate)
        mountRecovered(model, "A", 1)
        #expect(model.tab(id: TabID(value: 1))?.simPanes.first?.sizePreset == .pixelAccurate)
    }

    @Test
    func aDevicePanePresetSurvivesTheRecoveryRoundTrip() {
        let model = TabListViewModel()
        model.append(tab(1))
        model.addDevicePane(
            DevicePaneState(paneId: "old", deviceId: "D", displayName: "iPhone", family: "phone"),
            toTab: TabID(value: 1)
        )
        model.setSizePreset(.physical, forPane: .device(deviceId: "D"), inTab: TabID(value: 1))
        model.replaceDevicePaneWithPending(
            deviceId: "D",
            pending: PendingPaneState(
                id: PendingPaneID(value: 1),
                target: .device(deviceId: "D"),
                displayName: "iPhone",
                family: "phone"
            ),
            inTab: TabID(value: 1)
        )
        #expect(model.tab(id: TabID(value: 1))?.pendingPanes.first?.sizePreset == .physical)
        model.replacePendingWithDevice(
            id: PendingPaneID(value: 1),
            pane: DevicePaneState(
                paneId: "new",
                deviceId: "D",
                displayName: "iPhone",
                family: "phone"
            ),
            inTab: TabID(value: 1)
        )
        #expect(model.tab(id: TabID(value: 1))?.devicePanes.first?.sizePreset == .physical)
    }

    @Test
    func aPaneWithNoChosenPresetComesBackWithNone() {
        // The round trip must not invent one either: a pane that never had a
        // preset picked has to keep taking its family default, which is what
        // nil means downstream.
        let model = TabListViewModel()
        model.append(tab(1))
        model.addSimPane(
            SimPaneState(paneId: "old", udid: "A", displayName: "Watch", family: "watch"),
            toTab: TabID(value: 1)
        )
        model.replaceSimPaneWithPending(
            udid: "A",
            pending: PendingPaneState(
                id: PendingPaneID(value: 1),
                target: .sim(udid: "A"),
                displayName: "Watch",
                family: "watch",
                atIndex: 0
            ),
            inTab: TabID(value: 1)
        )
        mountRecovered(model, "A", 1)
        #expect(model.tab(id: TabID(value: 1))?.simPanes.first?.sizePreset == nil)
    }

    // MARK: - addTerminal placement (Split Right / Split Down)

    @Test
    func addTerminalWithoutAnchorAppendsAtRoot() {
        let model = TabListViewModel()
        model.append(tab(1))
        model.addTerminal(
            TerminalPaneState(id: TerminalPaneID(value: 2), sessionId: "S2", capability: "C2"),
            toTab: TabID(value: 1)
        )
        // No anchor → root split, both leaves side by side.
        let tree = model.tab(id: TabID(value: 1))?.paneTree
        #expect(tree == .split(
            axis: .horizontal,
            children: [.leaf(.terminal(TerminalPaneID(value: 1))), .leaf(.terminal(TerminalPaneID(value: 2)))],
            extents: [1, 1]
        ))
    }

    @Test
    func splitRightThenSplitDownNestsUnderClickedPane() {
        // The reported bug, at the view-model layer. Start with pane 1;
        // Split Right anchored on 1 (horizontal, add 2); Split Down
        // anchored on 1 again (vertical, add 3). Expect
        // `[[1 / 3] | 2]`, not three stacked rows.
        let model = TabListViewModel()
        model.append(tab(1))
        model.addTerminal(
            TerminalPaneState(id: TerminalPaneID(value: 2), sessionId: "S2", capability: "C2"),
            toTab: TabID(value: 1),
            anchor: .terminal(TerminalPaneID(value: 1)),
            axis: .horizontal
        )
        model.addTerminal(
            TerminalPaneState(id: TerminalPaneID(value: 3), sessionId: "S3", capability: "C3"),
            toTab: TabID(value: 1),
            anchor: .terminal(TerminalPaneID(value: 1)),
            axis: .vertical
        )
        let tree = model.tab(id: TabID(value: 1))?.paneTree
        #expect(tree == .split(
            axis: .horizontal,
            children: [
                .split(
                    axis: .vertical,
                    children: [.leaf(.terminal(TerminalPaneID(value: 1))), .leaf(.terminal(TerminalPaneID(value: 3)))],
                    extents: [1, 1]
                ),
                .leaf(.terminal(TerminalPaneID(value: 2)))
            ],
            extents: [1, 1]
        ))
    }

    @Test
    func addTerminalWithStaleAnchorFallsBackToRootAppend() {
        // A caller passing an anchor not in the tree (e.g. the pane
        // closed between right-click and dispatch) must not silently
        // drop the pane; it appends at root instead.
        let model = TabListViewModel()
        model.append(tab(1))
        model.addTerminal(
            TerminalPaneState(id: TerminalPaneID(value: 2), sessionId: "S2", capability: "C2"),
            toTab: TabID(value: 1),
            anchor: .terminal(TerminalPaneID(value: 99)),
            axis: .vertical
        )
        let leaves = model.tab(id: TabID(value: 1)).map { PaneTreeOps.leavesInOrder($0.paneTree) }
        #expect(leaves == [.terminal(TerminalPaneID(value: 1)), .terminal(TerminalPaneID(value: 2))])
    }

    @Test(arguments: [
        PaneSlot.sim(udid: "U"),
        PaneSlot.device(deviceId: "D")
    ], [SplitAxis.horizontal, .vertical])
    func addTerminalAnchorsBesideADevicePane(anchor: PaneSlot, axis: SplitAxis) {
        // ⌘D / ⇧⌘D with a device focused splits beside the device, so the
        // new terminal lands where the user is looking. The anchor has to
        // be a slot for that to be expressible at all: a `TerminalPaneID`
        // cannot name a sim or a device.
        let model = TabListViewModel()
        model.append(tab(1))
        switch anchor {
        case let .sim(udid):
            model.addSimPane(
                SimPaneState(paneId: "p", udid: udid, displayName: "iPhone", family: "phone"),
                toTab: TabID(value: 1),
                spawningTerminal: TerminalPaneID(value: 1)
            )

        default:
            model.addDevicePane(
                DevicePaneState(
                    paneId: "p",
                    deviceId: "D",
                    displayName: "iPhone",
                    family: "phone"
                ),
                toTab: TabID(value: 1),
                spawningTerminal: TerminalPaneID(value: 1)
            )
        }
        model.addTerminal(
            TerminalPaneState(id: TerminalPaneID(value: 2), sessionId: "S2", capability: "C2"),
            toTab: TabID(value: 1),
            anchor: anchor,
            axis: axis
        )
        // Anchored, so the new terminal joins the device rather than
        // appending at the root beside the original terminal. A vertical
        // split nests (the device's parent runs horizontally); a
        // horizontal one extends that parent in place.
        let tree = model.tab(id: TabID(value: 1))?.paneTree
        let expected: PaneNode = axis == .vertical
            ? .split(
                axis: .horizontal,
                children: [
                    .leaf(.terminal(TerminalPaneID(value: 1))),
                    .split(
                        axis: .vertical,
                        children: [.leaf(anchor), .leaf(.terminal(TerminalPaneID(value: 2)))],
                        extents: [1, 1]
                    )
                ],
                extents: [1, 1]
            )
            : .split(
                axis: .horizontal,
                children: [
                    .leaf(.terminal(TerminalPaneID(value: 1))),
                    .leaf(anchor),
                    .leaf(.terminal(TerminalPaneID(value: 2)))
                ],
                extents: [1, 1, 1]
            )
        #expect(tree == expected)
    }

    @Test
    func flipSplitAxisFlipsOnlyFocusedPanesParent() {
        // Build `[[1 / 3] | 2]`, then ⌃⇧D on pane 3 → `[[1 | 3] | 2]`.
        let model = TabListViewModel()
        model.append(tab(1))
        model.addTerminal(
            TerminalPaneState(id: TerminalPaneID(value: 2), sessionId: "S2", capability: "C2"),
            toTab: TabID(value: 1),
            anchor: .terminal(TerminalPaneID(value: 1)),
            axis: .horizontal
        )
        model.addTerminal(
            TerminalPaneState(id: TerminalPaneID(value: 3), sessionId: "S3", capability: "C3"),
            toTab: TabID(value: 1),
            anchor: .terminal(TerminalPaneID(value: 1)),
            axis: .vertical
        )
        model.flipSplitAxis(containing: .terminal(TerminalPaneID(value: 3)), inTab: TabID(value: 1))
        let tree = model.tab(id: TabID(value: 1))?.paneTree
        #expect(tree == .split(
            axis: .horizontal,
            children: [
                .split(
                    axis: .horizontal,
                    children: [.leaf(.terminal(TerminalPaneID(value: 1))), .leaf(.terminal(TerminalPaneID(value: 3)))],
                    extents: [1, 1]
                ),
                .leaf(.terminal(TerminalPaneID(value: 2)))
            ],
            extents: [1, 1]
        ))
    }

    // MARK: - Restoring several panes at once

    /// A tab holding three sim panes, each swapped for an attaching
    /// placeholder that remembers where it came from. The state a helper
    /// restart leaves behind while every pane re-attaches.
    private func modelRecoveringThreeSims() -> TabListViewModel {
        let model = TabListViewModel()
        model.append(tab(1))
        for (index, udid) in ["A", "B", "C"].enumerated() {
            model.addSimPane(
                SimPaneState(
                    paneId: "old-\(udid)",
                    udid: udid,
                    displayName: "iPhone \(udid)",
                    family: "phone"
                ),
                toTab: TabID(value: 1)
            )
            _ = index
        }
        for (index, udid) in ["A", "B", "C"].enumerated() {
            model.replaceSimPaneWithPending(
                udid: udid,
                pending: PendingPaneState(
                    id: PendingPaneID(value: index + 1),
                    target: .sim(udid: udid),
                    displayName: "iPhone \(udid)",
                    family: "phone",
                    atIndex: index,
                    resolvesName: true
                ),
                inTab: TabID(value: 1)
            )
        }
        return model
    }

    private func mountRecovered(_ model: TabListViewModel, _ udid: String, _ pendingValue: Int) {
        model.replacePendingWithSim(
            id: PendingPaneID(value: pendingValue),
            pane: SimPaneState(
                paneId: "new-\(udid)",
                udid: udid,
                displayName: "iPhone \(udid)",
                family: "phone"
            ),
            inTab: TabID(value: 1)
        )
    }

    @Test(arguments: [
        [("C", 3), ("B", 2), ("A", 1)],
        [("A", 1), ("C", 3), ("B", 2)],
        [("B", 2), ("C", 3), ("A", 1)],
        [("C", 3), ("A", 1), ("B", 2)],
        [("B", 2), ("A", 1), ("C", 3)]
    ])
    func panesRestoredOutOfOrderStillLandInTheirOriginalOrder(
        arrivals: [(String, Int)]
    ) {
        // Attaches finish in whatever order the daemon and the network of
        // suspensions produce, so every permutation has to rebuild the same
        // array. Clamping each recorded index to the current length does not:
        // reverse arrival puts an early-arriving later pane too far left, and
        // nothing afterwards moves it, which is how C, B, A became A, C, B.
        let model = modelRecoveringThreeSims()
        for (udid, pendingValue) in arrivals {
            mountRecovered(model, udid, pendingValue)
        }
        #expect(model.tab(id: TabID(value: 1))?.simPanes.map(\.udid) == ["A", "B", "C"])
    }

    @Test
    func aLoneRestoredPaneStillLandsAtItsRecordedIndex() {
        // The single-pane resurrect path: with no other pending pane ahead of
        // it, the pane returns to the position it recorded.
        let model = TabListViewModel()
        model.append(tab(1))
        for udid in ["A", "B"] {
            model.addSimPane(
                SimPaneState(paneId: "p-\(udid)", udid: udid, displayName: udid, family: "phone"),
                toTab: TabID(value: 1)
            )
        }
        model.replaceSimPaneWithPending(
            udid: "A",
            pending: PendingPaneState(
                id: PendingPaneID(value: 9),
                target: .sim(udid: "A"),
                displayName: "A",
                family: "phone",
                atIndex: 0
            ),
            inTab: TabID(value: 1)
        )
        #expect(model.tab(id: TabID(value: 1))?.simPanes.map(\.udid) == ["B"])
        mountRecovered(model, "A", 9)
        #expect(model.tab(id: TabID(value: 1))?.simPanes.map(\.udid) == ["A", "B"])
    }

    @Test
    func closingAPaneRenumbersAPlaceholderBehindIt() {
        // The numbering recovery hands out spans every sim the tab will hold,
        // so closing one leaves a gap the placeholders behind it are still
        // numbered against. Here B fails and keeps position 1 while A and C
        // mount; closing A has to pull B down to 0, or the next recovery
        // rebuilds the array around a position nothing vacated and lands
        // [C, B] instead of [B, C].
        let model = modelRecoveringThreeSims()
        mountRecovered(model, "A", 1)
        mountRecovered(model, "C", 3)
        #expect(model.tab(id: TabID(value: 1))?.simPanes.map(\.udid) == ["A", "C"])
        #expect(model.tab(id: TabID(value: 1))?.pendingPanes.map(\.atIndex) == [1])

        model.removeSimPane(udid: "A", fromTab: TabID(value: 1))
        #expect(
            model.tab(id: TabID(value: 1))?.pendingPanes.map(\.atIndex) == [0],
            "B held position 1 behind A, so A leaving moves it to 0"
        )
        #expect(model.tab(id: TabID(value: 1))?.simPanes.map(\.udid) == ["C"])
    }

    @Test
    func closingAPlaceholderRenumbersThePlaceholdersBehindIt() {
        // Same gap, opened from the other side: a placeholder the user closes
        // never mounts, so the positions behind it have to close up too.
        let model = modelRecoveringThreeSims()
        model.removePendingPane(id: PendingPaneID(value: 1), fromTab: TabID(value: 1))
        #expect(model.tab(id: TabID(value: 1))?.pendingPanes.map(\.atIndex) == [0, 1])
        mountRecovered(model, "C", 3)
        mountRecovered(model, "B", 2)
        #expect(model.tab(id: TabID(value: 1))?.simPanes.map(\.udid) == ["B", "C"])
    }
}
