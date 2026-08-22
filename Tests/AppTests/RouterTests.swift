// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Router driving the nav model against a fake daemon. Routes
// dispatch onto the serial drain, so each test settles before asserting
// nav state + recorded daemon calls. Window/tab ids are allocated
// monotonically from 1, so a sequence dispatched at once is predictable.

@testable import App
import DaemonProtocol
import Foundation
import Testing

private enum FakeDaemonError: Error { case attachFailed }

@MainActor
struct RouterTests {
    /// Let the serial drain process queued routes (fake daemon is instant).
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    }

    private func makeTempDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deviceterm-router-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir.path
    }

    private func makeRouter(
        _ fake: FakeDaemonClient,
        rpcPerformance: RPCPerformanceDiagnostics? = nil,
        detectWorktreeName: @escaping @MainActor () -> String? = { nil }
    ) -> (Router, WorkspaceViewModel) {
        let workspace = WorkspaceViewModel()
        let router = Router(
            workspace: workspace,
            daemon: fake,
            rpcPerformance: rpcPerformance,
            detectWorktreeName: detectWorktreeName
        )
        return (router, workspace)
    }

    @Test
    func openWindowCreatesWindowAndInitialTab() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        #expect(workspace.windows.count == 1)
        #expect(workspace.selectedWindowID == WindowID(value: 1))
        #expect(workspace.windows.first?.tabs.tabs.count == 1)
        #expect(
            fake.createSessionCalls == [
            .init(label: nil, name: nil, role: .agent, initialPrivate: false)
            ]
            )
    }

    @Test
    func openWindowPropagatesWorktreeName() async {
        // Regression guard: a Router-injected name detector
        // (production: WorktreeName.detect on the GUI's CWD) lands
        // on the session.create call. The detector returning a value
        // populates the tab's `name` so the GUI's tabs strip + CLI
        // tabs list auto-label with the branch.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake, detectWorktreeName: { "feature-branch" })
        router.dispatch(.openWindow())
        await settle()
        #expect(
            fake.createSessionCalls == [
            .init(label: nil, name: "feature-branch", role: .agent, initialPrivate: false)
            ]
            )
    }

    @Test
    func openWindowDefaultsToAgentRole() async {
        // Regression guard: the standard openWindow path mints
        // `.agent` sessions. Only the GUI's "Open Orchestrator Tab"
        // menu opens an `.orchestrator` session, and it'll come in
        // via a different Route. If a future change silently flipped
        // this default, multi-agent isolation would break (every tab
        // would bypass linkage).
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        #expect(fake.createSessionCalls.first?.role == .agent)
    }

    @Test
    func openOrchestratorTabMintsOrchestratorSession() async {
        // The "Open Orchestrator Tab" menu's route MUST end up at
        // `session.create(role: .orchestrator)`. Without this, the
        // menu would silently mint agent sessions and the user-grant
        // signal in the tab strip would be a lie.
        let fake = FakeDaemonClient()
        fake.sessionToReturn = SessionCreateResponse(
            sessionId: "ORCH",
            capability: "C",
            role: .orchestrator
        )
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.openOrchestratorTab(WindowID(value: 1)))
        await settle()
        // Two session.create calls: the initial agent tab from
        // openWindow, then the orchestrator tab.
        #expect(fake.createSessionCalls.count == 2)
        #expect(fake.createSessionCalls[1].role == .orchestrator)
        // Tab state reflects the role for the strip marker + future
        // linkage check.
        let tabs = workspace.window(id: WindowID(value: 1))?.tabs.tabs
        #expect(tabs?.count == 2)
        #expect(tabs?.last?.role == .orchestrator)
    }

    @Test
    func openOrchestratorTabRespectsDaemonRoleResponse() async {
        // The daemon's response is the source of truth: if it sends
        // a different role back (e.g. a future policy demotes
        // orchestrator requests in certain modes), the tab records
        // what the daemon actually granted, not what we asked for.
        let fake = FakeDaemonClient()
        fake.sessionToReturn = SessionCreateResponse(
            sessionId: "S",
            capability: "C",
            role: .agent
        )
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.openOrchestratorTab(WindowID(value: 1)))
        await settle()
        let tabs = workspace.window(id: WindowID(value: 1))?.tabs.tabs
        #expect(tabs?.last?.role == .agent)
    }

    @Test
    func dispatchedRoutesDrainInOrder() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        // The first window is deterministically WindowID(1), so the two
        // newTabs can be queued alongside openWindow without reading state.
        router.dispatch(.openWindow())
        router.dispatch(.newTab(WindowID(value: 1)))
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        let tabs = workspace.window(id: WindowID(value: 1))?.tabs
        #expect(tabs?.tabs.map(\.id) == [TabID(value: 1), TabID(value: 2), TabID(value: 3)])
        #expect(tabs?.selectedIndex == 2)
        #expect(fake.createSessionCalls.count == 3)
    }

    @Test
    func reorderTabMovesWithinWindow() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        router.dispatch(.newTab(WindowID(value: 1)))
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        // Move the first tab to the end.
        router.dispatch(.reorderTab(WindowID(value: 1), TabID(value: 1), toIndex: 2))
        await settle()
        let tabs = workspace.window(id: WindowID(value: 1))?.tabs
        #expect(tabs?.tabs.map(\.id) == [TabID(value: 2), TabID(value: 3), TabID(value: 1)])
    }

    @Test
    func queuedRelativeSelectionsEachAdvanceOneTab() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        router.dispatch(.newTab(WindowID(value: 1)))
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        let tabs = workspace.window(id: WindowID(value: 1))?.tabs
        #expect(tabs?.selectedIndex == 2)

        // Queued without settling, to model repeated presses arriving while
        // a slower route occupies the drain. Resolving the offset at
        // dispatch time would read the same selection for both and collapse
        // them into a single step; resolving it in the handler reads what
        // the preceding route committed.
        router.dispatch(.selectRelativeTab(WindowID(value: 1), delta: -1))
        router.dispatch(.selectRelativeTab(WindowID(value: 1), delta: -1))
        await settle()
        #expect(tabs?.selectedIndex == 0)
    }

    @Test
    func relativeSelectionWrapsPastEitherEnd() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        router.dispatch(.newTab(WindowID(value: 1)))
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        let tabs = workspace.window(id: WindowID(value: 1))?.tabs

        router.dispatch(.selectRelativeTab(WindowID(value: 1), delta: +1))
        await settle()
        #expect(tabs?.selectedIndex == 0)

        router.dispatch(.selectRelativeTab(WindowID(value: 1), delta: -1))
        await settle()
        #expect(tabs?.selectedIndex == 2)
    }

    @Test
    func queuedTabMovesEachShiftOneSlot() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        router.dispatch(.newTab(WindowID(value: 1)))
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        let tabs = workspace.window(id: WindowID(value: 1))?.tabs
        // The newest tab is selected, so it starts at the end.
        #expect(tabs?.selectedIndex == 2)

        // Same queuing hazard as relative selection: resolving a
        // destination at dispatch time would give both presses the same
        // target and shift the tab one slot in total.
        router.dispatch(.moveTabRelative(WindowID(value: 1), TabID(value: 3), delta: -1))
        router.dispatch(.moveTabRelative(WindowID(value: 1), TabID(value: 3), delta: -1))
        await settle()
        #expect(tabs?.tabs.map(\.id) == [TabID(value: 3), TabID(value: 1), TabID(value: 2)])
        #expect(tabs?.selectedIndex == 0, "selection follows the moved tab")
    }

    @Test
    func movingTheSelectedTabStopsAtTheEnds() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        let tabs = workspace.window(id: WindowID(value: 1))?.tabs
        #expect(tabs?.selectedIndex == 1)

        router.dispatch(.moveTabRelative(WindowID(value: 1), TabID(value: 2), delta: +1))
        await settle()
        #expect(tabs?.tabs.map(\.id) == [TabID(value: 1), TabID(value: 2)])
        #expect(tabs?.selectedIndex == 1)
    }

    @Test
    func movingATabActsOnTheTabNamedNotTheOneNowSelected() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        let tabs = workspace.window(id: WindowID(value: 1))?.tabs
        #expect(tabs?.selectedIndex == 1)

        // A route draining between the press and the move can change the
        // selection: `newTab` selects its new tab once `createSession`
        // returns. Resolving the mover from the selection at that point
        // would shift tab 3, which the user never pointed at.
        router.dispatch(.newTab(WindowID(value: 1)))
        router.dispatch(.moveTabRelative(WindowID(value: 1), TabID(value: 2), delta: -1))
        await settle()
        #expect(tabs?.tabs.map(\.id) == [TabID(value: 2), TabID(value: 1), TabID(value: 3)])
    }

    @Test
    func movingAClosedTabIsANoOp() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        let tabs = workspace.window(id: WindowID(value: 1))?.tabs
        router.dispatch(.moveTabRelative(WindowID(value: 1), TabID(value: 99), delta: -1))
        await settle()
        #expect(tabs?.tabs.map(\.id) == [TabID(value: 1), TabID(value: 2)])
    }

    @Test
    func relativeSelectionIgnoresAnUnknownWindow() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.selectRelativeTab(WindowID(value: 99), delta: +1))
        await settle()
        #expect(workspace.window(id: WindowID(value: 1))?.tabs.selectedIndex == 0)
    }

    @Test
    func attachSimPaneAttachesOnceIdempotently() async {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "phone"
        )
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(.attachSimPane(tab: tabID, udid: "U", displayName: "iPhone"))
        router.dispatch(.attachSimPane(tab: tabID, udid: "U", displayName: "iPhone"))
        await settle()
        let pane = workspace.window(id: WindowID(value: 1))?.tabs.tab(id: tabID)?.simPanes
        #expect(pane?.map(\.udid) == ["U"])
        #expect(pane?.first?.paneId == "P1")
        #expect(pane?.first?.family == "phone")
        #expect(fake.attachDeviceCalls.count == 1)               // idempotent
        #expect(fake.attachDeviceCalls.first?.sessionId == "S")
    }

    @Test
    func attachSimPaneWithNilDisplayNameLooksUpDeviceName() async {
        // `deviceterm device attach` doesn't have the device name in
        // hand and asks Router to resolve via `daemon.deviceList`:
        // without the lookup the chrome would render the UDID-
        // prefix placeholder ("Sim 1d464fbe") instead of the
        // device's real name ("CrownsGambit" for a custom watchOS
        // sim, "iPhone 17 Pro" for a stock device).
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "watch"
        )
        fake.deviceListResult = [
            DeviceListEntry(
            udid: "1D464FBE-56BA-4A49-8D73-277A7E8A0E92",
            name: "CrownsGambit",
            state: "Booted",
            ownedBySession: nil
        )
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(
            .attachSimPane(
            tab: tabID,
            udid: "1D464FBE-56BA-4A49-8D73-277A7E8A0E92",
            displayName: nil
        )
            )
        await settle()
        let pane = workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: tabID)?.simPanes.first
        #expect(pane?.displayName == "CrownsGambit")
    }

    @Test
    func attachSimPaneFallsBackToPlaceholderWhenLookupFails() async {
        // Defensive: if `device.list` returns no match (sim was
        // shut down between the CLI's claim and the Router's
        // lookup, or some daemon-side oddity), the pane still
        // mounts with the UDID-prefix placeholder so the user
        // sees something rather than the attach silently failing.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "phone"
        )
        fake.deviceListResult = []  // no match
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(
            .attachSimPane(
            tab: tabID,
            udid: "7db632b6-1234-1234-1234-123456789abc",
            displayName: nil
        )
            )
        await settle()
        let pane = workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: tabID)?.simPanes.first
        #expect(pane?.displayName == "Sim 7db632b6")
    }

    @Test
    func attachSimPaneSkipsLookupWhenDisplayNameSupplied() async {
        // Discovery / shim-intercept / resurrect already have the
        // real name in hand and pass it through. The Router must
        // NOT re-fetch: it'd be wasted RPC and could race the
        // sim's lifecycle (a shutdown event arriving between the
        // attach and the lookup would surface a stale name).
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "phone"
        )
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        let initialDeviceListCallCount = fake.deviceListCalls.count
        router.dispatch(
            .attachSimPane(
            tab: tabID,
            udid: "U",
            displayName: "iPhone 17 Pro"
        )
            )
        await settle()
        let pane = workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: tabID)?.simPanes.first
        #expect(pane?.displayName == "iPhone 17 Pro")
        #expect(fake.deviceListCalls.count == initialDeviceListCallCount)
    }

    @Test
    func attachSimPaneComposesNameAndDeviceTypeWhenDistinct() async {
        // Custom-named watch sim: device.list `name` is the user's
        // chosen name ("CrownsGambit"); attach response's
        // `deviceType` is the CoreSimulator deviceType name
        // ("Apple Watch Ultra 3 (49mm)"). Chrome shows both, middot-
        // separated, so the user can identify the hardware behind
        // the custom name.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "watch",
            deviceType: "Apple Watch Ultra 3 (49mm)"
        )
        fake.deviceListResult = [
            DeviceListEntry(
            udid: "1D464FBE-56BA-4A49-8D73-277A7E8A0E92",
            name: "CrownsGambit",
            state: "Booted",
            ownedBySession: nil
        )
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(
            .attachSimPane(
            tab: tabID,
            udid: "1D464FBE-56BA-4A49-8D73-277A7E8A0E92",
            displayName: nil
        )
            )
        await settle()
        let pane = workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: tabID)?.simPanes.first
        #expect(
            pane?.displayName ==
            "CrownsGambit · Apple Watch Ultra 3 (49mm)"
            )
    }

    @Test
    func attachSimPaneCollapsesNameWhenEqualToDeviceType() async {
        // Stock un-renamed iPhone: device.list `name` equals the
        // deviceType ("iPhone 17 Pro"). The chrome shows just the
        // name: no "iPhone 17 Pro · iPhone 17 Pro" duplication.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "phone",
            deviceType: "iPhone 17 Pro"
        )
        fake.deviceListResult = [
            DeviceListEntry(
            udid: "AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111",
            name: "iPhone 17 Pro",
            state: "Booted",
            ownedBySession: nil
        )
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(
            .attachSimPane(
            tab: tabID,
            udid: "AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111",
            displayName: nil
        )
            )
        await settle()
        let pane = workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: tabID)?.simPanes.first
        #expect(pane?.displayName == "iPhone 17 Pro")
    }

    @Test
    func attachSimPaneFallsBackToBareNameWhenDeviceTypeMissing() async {
        // Older daemon that doesn't expose `deviceType` on the wire
        // (or a bridge call that failed): compose falls back to
        // bare name. The skew-tolerant Optional decoding keeps the
        // attach path working; the chrome just renders without the
        // type suffix.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "watch"
        )  // deviceType omitted (nil)
        fake.deviceListResult = [
            DeviceListEntry(
            udid: "1D464FBE-56BA-4A49-8D73-277A7E8A0E92",
            name: "CrownsGambit",
            state: "Booted",
            ownedBySession: nil
        )
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(
            .attachSimPane(
            tab: tabID,
            udid: "1D464FBE-56BA-4A49-8D73-277A7E8A0E92",
            displayName: nil
        )
            )
        await settle()
        let pane = workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: tabID)?.simPanes.first
        #expect(pane?.displayName == "CrownsGambit")
    }

    @Test
    func detachSimPaneRemovesPaneAndCloses() async {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "phone"
        )
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(.attachSimPane(tab: tabID, udid: "U", displayName: "iPhone"))
        await settle()
        router.dispatch(.detachSimPane(tab: tabID, udid: "U", mode: .detach))
        await settle()
        #expect(
            workspace.window(id: WindowID(value: 1))?.tabs.tab(id: tabID)?
            .simPanes.isEmpty == true
            )
        #expect(fake.closePaneCalls == [.init(paneId: "P1", mode: .detach)])
    }

    @Test
    func detachSimPaneRefusesWhenThePaneWasReplaced() async {
        // `dispatch` enqueues, so a resurrect can swap the tab's pane for
        // this udid before the close drains. The close carries the paneId
        // the user was asked about; resolving the udid to the replacement
        // and closing that instead would apply their answer, `.shutdown`
        // included, to a pane they never saw.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(.attachSimPane(tab: tabID, udid: "U", displayName: "iPhone"))
        await settle()
        // Stand in for the resurrect: the same udid now carries a new pane.
        router.dispatch(.detachSimPane(tab: tabID, udid: "U", mode: .detach))
        await settle()
        fake.attachResult = PaneCreateResponse(paneId: "P2", scale: nil, family: "phone")
        router.dispatch(.attachSimPane(tab: tabID, udid: "U", displayName: "iPhone"))
        await settle()
        // The detach above is the only close so far; the fenced one must add
        // nothing to it.
        let closesBefore = fake.closePaneCalls

        router.dispatch(
            .detachSimPane(
                tab: tabID,
                udid: "U",
                mode: .shutdown,
                expecting: PaneAdmission(paneId: "P1", attachment: nil)
            )
        )
        await settle()

        #expect(fake.closePaneCalls == closesBefore)
        let survivors = workspace.window(id: WindowID(value: 1))?.tabs.tab(id: tabID)?.simPanes
        #expect(survivors?.map(\.paneId) == ["P2"])
    }

    @Test
    func detachSimPaneRefusesWhenOnlyTheAttachmentMoved() async {
        // A re-attach keeps the daemon's record and its id, bumping only
        // `attachment`. The paneId therefore still matches while naming a
        // different admission, so a paneId-only fence would let the old
        // decision through onto the new one.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            attachment: 7,
            family: "phone"
        )
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(.attachSimPane(tab: tabID, udid: "U", displayName: "iPhone"))
        await settle()
        let closesBefore = fake.closePaneCalls

        router.dispatch(
            .detachSimPane(
                tab: tabID,
                udid: "U",
                mode: .shutdown,
                expecting: PaneAdmission(paneId: "P1", attachment: 6)
            )
        )
        await settle()

        #expect(fake.closePaneCalls == closesBefore)
    }

    @Test
    func detachSimPaneClosesWhenThePaneIdStillMatches() async {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "phone")
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(.attachSimPane(tab: tabID, udid: "U", displayName: "iPhone"))
        await settle()

        router.dispatch(
            .detachSimPane(
                tab: tabID,
                udid: "U",
                mode: .shutdown,
                expecting: PaneAdmission(paneId: "P1", attachment: nil)
            )
        )
        await settle()

        #expect(fake.closePaneCalls == [.init(paneId: "P1", mode: .shutdown)])
        #expect(
            workspace.window(id: WindowID(value: 1))?.tabs.tab(id: tabID)?
            .simPanes.isEmpty == true
            )
    }

    @Test
    func attachDevicePaneAttachesOnceIdempotently() async {
        // physicalDevice.attach is threaded the tab's primary-terminal
        // session (the GUI-trusted attribution path) and is idempotent
        // by deviceId: a second attach for the same connected device
        // is a no-op, not a second daemon call / duplicate pane.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "DP1",
            scale: nil,
            family: "phone"
        )
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(.attachDevicePane(tab: tabID, deviceId: "fd00::1", displayName: "iPhone 16 Pro"))
        router.dispatch(.attachDevicePane(tab: tabID, deviceId: "fd00::1", displayName: "iPhone 16 Pro"))
        await settle()
        let panes = workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: tabID)?.devicePanes
        #expect(panes?.map(\.deviceId) == ["fd00::1"])
        #expect(panes?.first?.paneId == "DP1")
        #expect(panes?.first?.displayName == "iPhone 16 Pro")
        #expect(fake.attachPhysicalDeviceCalls.count == 1)             // idempotent
        #expect(fake.attachPhysicalDeviceCalls.first?.sessionId == "S")
        #expect(fake.attachPhysicalDeviceCalls.first?.deviceId == "fd00::1")
        // The leaf is in the layout tree, not just the typed array.
        let tree = workspace.window(id: WindowID(value: 1))?.tabs.tab(id: tabID)?.paneTree
        #expect(tree.map { PaneTreeOps.leavesInOrder($0) }?
            .contains(.device(deviceId: "fd00::1")) == true)
    }

    @Test
    func attachDevicePaneComposesNameAndDeviceTypeWhenDistinct() async {
        // A picker-supplied name plus a distinct deviceType from the
        // attach response compose middot-separated, mirroring the sim
        // chrome label rule.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "DP1",
            scale: nil,
            family: "phone",
            deviceType: "iPhone 16 Pro"
        )
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(.attachDevicePane(tab: tabID, deviceId: "fd00::1", displayName: "Jane's iPhone"))
        await settle()
        let pane = workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: tabID)?.devicePanes.first
        #expect(pane?.displayName == "Jane's iPhone · iPhone 16 Pro")
    }

    @Test
    func attachDevicePaneFallsBackToResponseNameWhenDisplayNameNil() async {
        // No picker name in hand → use the attach response's `name`
        // (the physical roster carries the marketing name; there's no
        // `device.list` lookup like the sim path).
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "DP1",
            scale: nil,
            family: "phone",
            name: "iPad Pro"
        )
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(.attachDevicePane(tab: tabID, deviceId: "fd00::2", displayName: nil))
        await settle()
        let pane = workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: tabID)?.devicePanes.first
        #expect(pane?.displayName == "iPad Pro")
    }

    @Test
    func attachDevicePaneFallsBackToPlaceholderWhenNameless() async {
        // Defensive: neither a picker name nor a response name → a
        // deviceId-prefix placeholder so the pane still mounts visibly.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "DP1",
            scale: nil,
            family: "phone"
        )  // no name, no deviceType
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(.attachDevicePane(tab: tabID, deviceId: "fd00cafe::99", displayName: nil))
        await settle()
        let pane = workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: tabID)?.devicePanes.first
        #expect(pane?.displayName == "Device fd00cafe")
    }

    @Test
    func detachDevicePaneRemovesPaneAndCloses() async {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "DP1",
            scale: nil,
            family: "phone"
        )
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let tabID = TabID(value: 1)
        router.dispatch(.attachDevicePane(tab: tabID, deviceId: "fd00::1", displayName: "iPhone"))
        await settle()
        router.dispatch(.detachDevicePane(tab: tabID, deviceId: "fd00::1", mode: .detach))
        await settle()
        #expect(
            workspace.window(id: WindowID(value: 1))?.tabs.tab(id: tabID)?
            .devicePanes.isEmpty == true
            )
        #expect(fake.closePaneCalls == [.init(paneId: "DP1", mode: .detach)])
        // The leaf is also gone from the layout tree.
        let tree = workspace.window(id: WindowID(value: 1))?.tabs.tab(id: tabID)?.paneTree
        #expect(tree.map { PaneTreeOps.leavesInOrder($0) }?
            .contains(.device(deviceId: "fd00::1")) == false)
    }

    @Test
    func closeTabClosesDevicePanes() async {
        // Tab close tears down the daemon pane record for every device
        // pane (same as sims), so the IOSurface stream + tunnel-backed
        // pane don't leak. The physical device itself is never powered
        // off: closePane just drops the mirror.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "DP1",
            scale: nil,
            family: "phone"
        )
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachDevicePane(tab: TabID(value: 1), deviceId: "fd00::1", displayName: "iPhone"))
        await settle()
        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .detach))
        await settle()
        #expect(fake.closePaneCalls.contains(.init(paneId: "DP1", mode: .detach)))
    }

    @Test
    func closeTabShutsDownSessionAndOwnedSims() async {
        let fake = FakeDaemonClient()
        fake.deviceListResult = [
            DeviceListEntry(
            udid: "D",
            name: "iPhone",
            state: "Booted",
            ownedBySession: "S"
        )
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .shutdown))
        await settle()
        #expect(workspace.window(id: WindowID(value: 1))?.tabs.tabs.isEmpty == true)
        #expect(
            fake.closeSessionCalls == [
            .init(sessionId: "S", capability: "C", mode: .shutdown)
            ]
            )
        #expect(fake.shutdownDeviceCalls == ["D"])
    }

    @Test
    func reattachMountsAndCleansOrphanDirOnFullSuccess() async throws {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "phone"
        )
        let (router, workspace) = makeRouter(fake)
        let dir = try makeTempDir()
        let orphan = OrphanRecord(
            sessionId: "old",
            sessionDir: dir,
            liveSims: [OrphanLiveSim(udid: "U", displayName: "iPhone")]
        )
        router.dispatch(.openWindow(reattach: [orphan]))
        await settle()
        let panes = workspace.window(id: WindowID(value: 1))?.tabs
            .tab(id: TabID(value: 1))?.simPanes
        #expect(panes?.map(\.udid) == ["U"])
        #expect(fake.attachDeviceCalls.count == 1)
        // All sims attached → the adopted orphan dir is cleaned up.
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test
    func openTerminalPaneMintsAdditionalSession() async {
        // Multi-terminal-pane: dispatching openTerminalPane against an
        // existing tab fires a second session.create and appends a
        // TerminalPaneState to TabState.terminals. The primary's
        // session stays in place; the new terminal carries its own
        // session+cap.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        let tab = workspace.window(id: WindowID(value: 1))?.tabs.tab(id: TabID(value: 1))
        #expect(tab?.terminals.count == 2)
        #expect(tab?.terminals.map(\.sessionId) == ["S1", "S2"])
        #expect(tab?.terminals.map(\.capability) == ["C1", "C2"])
        #expect(fake.createSessionCalls.count == 2)
        // The added terminal inherits the tab's role at create-time.
        #expect(fake.createSessionCalls[1].role == .agent)
    }

    @Test
    func openTerminalPaneInheritsOrchestratorRole() async {
        // The role on the added terminal's session.create call mirrors
        // the tab's role: orchestrator tabs spawn orchestrator
        // terminals, agent tabs spawn agent terminals. Role is a
        // tab-wide property in the locked design.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(
                sessionId: "O1",
                capability: "OC1",
                role: .orchestrator
            ),
            SessionCreateResponse(
                sessionId: "O2",
                capability: "OC2",
                role: .orchestrator
            )
        ]
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.openOrchestratorTab(WindowID(value: 1)))
        await settle()
        router.dispatch(.openTerminalPane(tab: TabID(value: 2)))
        await settle()
        // session.create calls: initial agent tab, orchestrator tab,
        // additional terminal in the orchestrator tab.
        #expect(fake.createSessionCalls.count == 3)
        #expect(fake.createSessionCalls[2].role == .orchestrator)
    }

    @Test
    func closeTerminalPaneClosesSessionAndDropsEntry() async {
        // closeTerminalPane authenticates the right session+cap pair,
        // then drops the entry from TabState.terminals. The remaining
        // terminal (the primary) stays put.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        let addedID = workspace.window(id: WindowID(value: 1))?.tabs
            .tab(id: TabID(value: 1))?.terminals.last?.id
        guard let addedID else {
            Issue.record("expected a second terminal pane to be added")
            return
        }
        router.dispatch(
            .closeTerminalPane(
            tab: TabID(value: 1),
            terminal: addedID,
            mode: .detach
        )
            )
        await settle()
        let tab = workspace.window(id: WindowID(value: 1))?.tabs.tab(id: TabID(value: 1))
        #expect(tab?.terminals.count == 1)
        #expect(tab?.terminals.first?.sessionId == "S1")
        #expect(
            fake.closeSessionCalls == [
            .init(sessionId: "S2", capability: "C2", mode: .detach)
            ]
            )
    }

    @Test
    func closeTerminalPaneRefusesLastTerminal() async {
        // Last-terminal guard: closing the only terminal must be a
        // no-op so the tab doesn't end up empty. (Last-terminal close
        // routes through closeTab in the GUI; the terminal-exit
        // handler in TabStripViewController picks the right route
        // based on count.)
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        let primaryID = workspace.window(id: WindowID(value: 1))?.tabs
            .tab(id: TabID(value: 1))?.primaryTerminal.id
        guard let primaryID else {
            Issue.record("expected an initial terminal pane")
            return
        }
        router.dispatch(
            .closeTerminalPane(
            tab: TabID(value: 1),
            terminal: primaryID,
            mode: .detach
        )
            )
        await settle()
        let tab = workspace.window(id: WindowID(value: 1))?.tabs.tab(id: TabID(value: 1))
        #expect(tab?.terminals.count == 1)
        // No session.close fired: the guard short-circuits before
        // the daemon call.
        #expect(fake.closeSessionCalls.isEmpty)
    }

    @Test
    func closeTabClosesAllTerminalSessions() async {
        // Multi-terminal tab close: every terminal's session is
        // closed (cap-authenticated), not just the primary. Owned-sim
        // fan-out covers sims attributed to ANY terminal session.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        router.dispatch(
            .closeTab(
            WindowID(value: 1),
            TabID(value: 1),
            mode: .detach
        )
            )
        await settle()
        #expect(Set(fake.closeSessionCalls.map(\.sessionId)) == ["S1", "S2"])
    }

    @Test
    func setTabPrivateBatchesAllTerminalsAndMirrorsState() async {
        // Multi-terminal tab: setTabPrivate flips every terminal
        // session in ONE atomic `session.setPrivateBatch` (not a
        // per-terminal loop), and the GUI mirror updates only on a
        // successful ack.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        // Exactly one batch, carrying both terminal sessions.
        #expect(fake.setPrivateBatchCalls.count == 1)
        #expect(Set(fake.setPrivateBatchCalls.first?.sessionIds ?? []) == ["S1", "S2"])
        #expect(fake.setPrivateBatchCalls.first?.isPrivate == true)
        #expect(
            workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.isPrivate == true
            )
    }

    @Test
    func openTerminalPaneInheritsTabPrivacyAtCreate() async {
        // Adding a terminal to a private tab must seed the new
        // session's privacy atomically at create time via
        // `initialPrivate: true`, not a follow-up toggle, which
        // would race the create's own persist/publish and leave the
        // new session briefly visible on `tabs.list`.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        // The toggle batched only the primary (S1): the second
        // terminal didn't exist yet.
        #expect(fake.setPrivateBatchCalls.count == 1)
        #expect(fake.setPrivateBatchCalls.first?.sessionIds == ["S1"])
        // The added terminal (S2) was created private at the source;
        // no second batch fired for it.
        #expect(fake.createSessionCalls.last?.initialPrivate == true)
    }

    @Test
    func openTerminalPaneCreatesPublicOnPublicTab() async {
        // A public tab adding a terminal creates the new session
        // public (`initialPrivate: false`) and emits NO privacy
        // batch: the inheritance is gated on the tab's own state.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        #expect(fake.setPrivateBatchCalls.isEmpty)
        #expect(fake.createSessionCalls.last?.initialPrivate == false)
    }

    private func privacyState(
        _ workspace: WorkspaceViewModel,
        tab: TabID = TabID(value: 1)
    ) -> TabPrivacyState? {
        workspace.window(id: WindowID(value: 1))?.tabs.tab(id: tab)?.privacyState
    }

    @Test
    func setTabPrivateHidesImmediatelyBeforeAck() async {
        // Fail-closed: a public→private transition hides the tab the
        // instant the user acts: before the daemon confirms. The tab is
        // `.pendingPrivate` (effectively hidden, not yet committed) while
        // the batch is in flight, and commits to `.privateHidden` on ack.
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.armSetPrivateBatchBarrier()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        // Hidden before the ack, but not yet committed private.
        #expect(privacyState(workspace) == .pendingPrivate)
        #expect(
            workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.isEffectivelyHidden == true
            )
        #expect(fake.setPrivateBatchCalls.count == 1)
        fake.releaseSetPrivateBatch()
        await settle()
        #expect(privacyState(workspace) == .privateHidden)
    }

    @Test
    func setTabPrivateDefiniteRejectionReconcilesToConfirmedPublic() async {
        // A standalone DEFINITE pre-commit rejection means this batch never
        // mutated the daemon. The rejection itself doesn't confirm the state.
        // The reconcile SNAPSHOT establishes it: here it finds the daemon
        // still public, so the GUI reconciles the `.pendingPrivate` tab back
        // to public (honest) and reports the failure, rather than leaving a
        // misleading "private" façade. It does not retry, and this is NOT a
        // request-time snapshot restore: the daemon's state is read, not
        // guessed.
        let fake = FakeDaemonClient()
        fake.setPrivateBatchFailures = [
            DaemonClientError.daemon(code: -32_001, message: "nope")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(privacyState(workspace) == .publicVisible)
        #expect(
            workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.isEffectivelyHidden == false
            )
        #expect(fake.setPrivateBatchCalls.count == 1)  // no retry
    }

    @Test
    func terminalCreatedDuringPrivateToPublicIsMintedPrivate() async {
        // Inverse of `transitionWaitsForInFlightTerminalCreate`: a terminal
        // opened while a private→public transition is pending must be minted
        // PRIVATE (fail-closed from the still-hidden tab), not declassified
        // to the transition's public target: otherwise it would be
        // daemon-public and exposed via tabs.list before the tab commits.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        // Commit private first.
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        #expect(privacyState(workspace) == .privateHidden)
        // Begin a private→public transition, held so it stays pending.
        fake.armSetPrivateBatchBarrier()
        async let outcome = router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: false)
        await settle()
        #expect(privacyState(workspace) == .privateHidden)  // still hidden, unacked
        // Open a terminal while pending: it inherits the hidden state.
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        #expect(fake.createSessionCalls.last?.initialPrivate == true)  // NOT declassified
        fake.releaseSetPrivateBatch()
        _ = await outcome
        await settle()
        // Everything publicizes together only once the transition commits.
        #expect(privacyState(workspace) == .publicVisible)
    }

    @Test
    func idempotentSetPrivateRejectionKeepsTabPrivate() async {
        // A redundant set-private true on an already-private tab that is
        // definitely rejected must revert to the ACTUAL prior state
        // (private), never toggle toward public, so the tab stays hidden.
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        #expect(privacyState(workspace) == .privateHidden)
        fake.setPrivateBatchFailures = [
            DaemonClientError.daemon(code: -32_602, message: "bad"),
            DaemonClientError.daemon(code: -32_602, message: "bad")
        ]
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        // Reverted toward the prior committed state (private), stayed hidden.
        #expect(privacyState(workspace) == .privateHidden)
    }

    @Test
    func definiteRejectionFromPublicReconcilesToPublic() async {
        // A definite rejection (invalidParams, the daemon is reachable and
        // validated, but refused this batch) of a standalone public→private
        // request. The rejection alone doesn't confirm the state; the reconcile
        // SNAPSHOT does: it finds the daemon still public (the refused mutation
        // never landed) and reconciles the tab back to public, reporting the
        // failure, instead of a misleading `.pendingPrivate`. (Smoke, where
        // the snapshot ALSO roleViolations, is covered separately by
        // `signatureRejectionLeavesTabFailClosedHidden`.)
        let fake = FakeDaemonClient()
        fake.setPrivateBatchFailures = [
            DaemonClientError.daemon(code: -32_602, message: "bad")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        let tab = workspace.window(id: WindowID(value: 1))?.tabs.tab(id: TabID(value: 1))
        #expect(privacyState(workspace) == .publicVisible)
        #expect(tab?.isEffectivelyHidden == false)
        #expect(tab?.isPrivate == false)
    }

    @Test
    func definiteRejectionMultiTerminalReconcilesToPublic() async {
        // Same on a multi-terminal tab: a standalone definite refusal
        // reconciles the whole tab to public.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        fake.setPrivateBatchFailures = [
            DaemonClientError.daemon(code: -32_602, message: "bad")
        ]
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        let tab = workspace.window(id: WindowID(value: 1))?.tabs.tab(id: TabID(value: 1))
        #expect(privacyState(workspace) == .publicVisible)
        #expect(tab?.isEffectivelyHidden == false)
        #expect(tab?.isPrivate == false)
    }

    @Test
    func terminalCreateClosesOrphanedSessionWhenTabVanishes() async {
        // A cross-window `tab move` (or a close) can relocate/remove the tab
        // while `openTerminalPane` is suspended in `createSession`. The fresh
        // session must not be stranded: if the tab is gone when the create
        // returns, the Router closes the orphaned session rather than leaking
        // a live, unreferenced session the privacy fence never covers.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S-primary", capability: "C1"),
            SessionCreateResponse(sessionId: "S-orphan", capability: "C2")
        ]
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        // Hold the second createSession so the tab can vanish mid-flight.
        fake.armCreateSessionBarrier()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        // The tab closes while its new session is still being created.
        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .shutdown))
        await settle()
        fake.releaseCreateSession()
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // The orphaned session is shut down, not leaked.
        #expect(fake.closeSessionCalls.contains { $0.sessionId == "S-orphan" })
    }

    @Test
    func oppositeSupersessionReportsRejectedNotConverging() async {
        // An awaited set-private that's superseded by the OPPOSITE toggle
        // before it resolves reports `.rejected` (its requested state was
        // abandoned) rather than a misleading "converging toward your
        // value."
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        // The faithful fake fences by (epoch, revision): the make-public (sent
        // second, higher revision) applies; the stalled make-private, released
        // later, is stale → applied:false.
        // Stall only the make-private send; the opposite make-public passes,
        // COMMITS, and CLEARS its transition first. The superseded make-private
        // must still report `.rejected` (not `.pending`): its outcome comes
        // from the target recorded at supersession, not the now-cleared
        // winner. This is the winner-clears-first ordering the earlier test
        // avoided.
        fake.armSetPrivateBatchStallFirstOnly()
        async let outcomeTask = router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: true)
        await settle()  // make-private suspended on the barrier
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: false))
        await settle()  // make-public supersedes, commits, and clears
        fake.releaseSetPrivateBatch()  // now let the superseded make-private resolve
        let outcome = await outcomeTask
        #expect(outcome == .rejected)
    }

    @Test
    func rejectedSuccessorReconcilesToPublicAfterPredecessorCommitted() async {
        // A make-public predecessor commits (daemon public), then a
        // make-private successor is DEFINITELY rejected. With no older send
        // still in flight, the GUI reconciles to public (the confirmed
        // daemon state) and reports the failure: it does not leave a
        // misleading `.pendingPrivate` while the daemon exposes the tab.
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        _ = await router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: true)
        await settle()
        #expect(privacyState(workspace) == .privateHidden)
        _ = await router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: false)
        await settle()
        #expect(privacyState(workspace) == .publicVisible)   // predecessor committed
        // Successor: make private, definitely rejected.
        fake.setPrivateBatchFailures = [
            DaemonClientError.daemon(code: -32_602, message: "bad")
        ]
        let outcome = await router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: true)
        await settle()
        #expect(outcome == .rejected)                        // failure reported
        #expect(privacyState(workspace) == .publicVisible)   // reconciled, honest
    }

    @Test
    func stalledPredecessorMakePublicIsFencedOutBySnapshot() async {
        // A make-public predecessor stalls in flight; a make-private successor
        // is then definitely rejected, and its reconcile snapshot fences the
        // sessions' ordering key. When the stalled predecessor finally arrives
        // at the daemon it is STALE (its revision no longer dominates the
        // fence) → `applied: false`, so it can't expose the tab. The GUI stays
        // at the reconciled state (private, the daemon never went public),
        // and the stale reply's superseded revision is below the last commit,
        // so it schedules no reconcile.
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        _ = await router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: true)
        await settle()
        #expect(privacyState(workspace) == .privateHidden)
        // Predecessor make-public parks in flight.
        fake.armSetPrivateBatchStallFirstOnly()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: false))
        await settle()
        // Successor make-private passes the gate and is definitely rejected;
        // its reconcile snapshot fences the key.
        fake.setPrivateBatchFailures = [
            DaemonClientError.daemon(code: -32_602, message: "bad")
        ]
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(privacyState(workspace) == .privateHidden)
        // The stalled predecessor arrives: now stale (fenced out), so it
        // can't override the reconciled private state.
        fake.releaseSetPrivateBatch()
        await settle()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(privacyState(workspace) == .privateHidden)
    }

    @Test
    func indeterminateLossRetriesWithFreshRevisionThenCommits() async {
        // A lost response (indeterminate transport error) keeps the tab
        // fail-closed and retries with a FRESH revision (reusing one would
        // look stale to the daemon) converging to committed once a send
        // acks.
        let fake = FakeDaemonClient()
        fake.setPrivateBatchFailures = [DaemonClientError.transport("dropped")]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        try? await Task.sleep(nanoseconds: 400_000_000)      // let the retry land
        #expect(privacyState(workspace) == .privateHidden)   // converged
        #expect(fake.setPrivateBatchCalls.count >= 2)         // retried
        let revisions = fake.setPrivateBatchCalls.map(\.revision)
        #expect(Set(revisions).count == revisions.count)      // all distinct
    }

    @Test
    func membershipExpansionResendsWithFreshRevision() async {
        // A terminal added while a batch is in flight expands membership;
        // the transition re-sends over the new set with a fresh revision
        // (the daemon would reject a reused one), and the final batch covers
        // both sessions so none is left in the opposite state.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.armSetPrivateBatchBarrier()                     // hold the first batch
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))  // expand membership
        await settle()
        fake.releaseSetPrivateBatch()
        await settle()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(privacyState(workspace) == .privateHidden)
        #expect(fake.setPrivateBatchCalls.last.map { Set($0.sessionIds) } == Set(["S1", "S2"]))
        let revisions = fake.setPrivateBatchCalls.map(\.revision)
        #expect(Set(revisions).count == revisions.count)      // fresh revision per send
    }

    @Test
    func successorCommitsWhilePredecessorPermanentlyStalled() async {
        // A permanently stalled predecessor (its RPC never returns) must not
        // prevent the successor from committing. The GUI sends the successor
        // immediately; daemon ordering fences a stalled predecessor, and the
        // superseded predecessor is guarded out even if its send eventually
        // resolves.
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.armSetPrivateBatchStallFirstOnly()              // only the 1st send parks
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        #expect(fake.setPrivateBatchCalls.count == 1)         // predecessor stalled
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: false))
        await settle()
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Successor committed public despite the predecessor being stuck.
        #expect(privacyState(workspace) == .publicVisible)
        #expect(fake.setPrivateBatchCalls.count == 2)
        fake.releaseSetPrivateBatch()                         // clean up the parked one
    }

    @Test
    func makePublicAckWhileMakePrivatePendingDoesNotExpose() async {
        // The over-correction guard: an older make-public reply that applies
        // while a NEWER make-private is still pending must NOT expose the tab
        // (it commits nothing, superseded). The tab stays fail-closed hidden
        // until the make-private resolves.
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        _ = await router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: true)  // private
        await settle()
        #expect(privacyState(workspace) == .privateHidden)
        fake.armSetPrivateBatchBarrier()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: false))  // predecessor parks
        await settle()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))   // successor parks
        await settle()
        fake.releaseFirstSetPrivateBatch()   // predecessor make-public applies
        await settle()
        try? await Task.sleep(nanoseconds: 150_000_000)
        // Not exposed: the newer make-private is still pending.
        #expect(privacyState(workspace) == .privateHidden)
        #expect(workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.isEffectivelyHidden == true)
        fake.releaseSetPrivateBatch()        // successor make-private applies
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(privacyState(workspace) == .privateHidden)   // make-private won
    }

    @Test
    func rejectionReconcilesToPrivateWhenSnapshotIsPrivate() async {
        // A make-public rejected while the daemon is actually PRIVATE (an
        // older make-private committed): the fenced snapshot reports private,
        // so the tab reconciles to hidden, not exposed.
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        _ = await router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: true)
        await settle()
        #expect(privacyState(workspace) == .privateHidden)
        // Make public, definitely rejected. Daemon stays private → snapshot
        // (reflecting the fake's applied state) is private → stays hidden.
        fake.setPrivateBatchFailures = [DaemonClientError.daemon(code: -32_602, message: "bad")]
        _ = await router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: false)
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(privacyState(workspace) == .privateHidden)   // reconciled private
        #expect(fake.privacySnapshotCalls.isEmpty == false)  // reconcile ran
    }

    @Test
    func reconcileMixedSnapshotStaysHidden() async {
        // A fenced but MIXED snapshot (one session public, one private) is
        // unresolved: the tab stays hidden, never exposed.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        // Snapshot will report S1 public, S2 private → mixed.
        fake.privacySnapshotStates = ["S1": .publicState, "S2": .privateState]
        fake.setPrivateBatchFailures = [DaemonClientError.daemon(code: -32_602, message: "bad")]
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        try? await Task.sleep(nanoseconds: 150_000_000)
        // Mixed → unresolved → hidden (never exposed).
        #expect(workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.isEffectivelyHidden == true)
    }

    @Test
    func staleSnapshotResponseDoesNotExposeAfterNewerMakePrivate() async {
        // Finding: a reconcile snapshot captures public, but a newer
        // make-private commits (and clears) before the delayed snapshot
        // response arrives. The stale snapshot (older revision) must be
        // discarded by the revision guard: never expose the now-private tab.
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        // Make-public on the (public) tab is rejected → triggers a reconcile;
        // hold its snapshot in flight.
        fake.armPrivacySnapshotBarrier()
        fake.setPrivateBatchFailures = [DaemonClientError.daemon(code: -32_602, message: "bad")]
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: false))
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // A newer make-private completes while the snapshot is parked.
        _ = await router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: true)
        await settle()
        #expect(privacyState(workspace) == .privateHidden)
        fake.releasePrivacySnapshot()   // stale public snapshot (older rev) returns
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Discarded: the tab stays private, not re-exposed.
        #expect(privacyState(workspace) == .privateHidden)
    }

    @Test
    func reconcileRetriesAfterSnapshotTransportFailure() async {
        // Finding: a lost snapshot reply must not abandon reconciliation. It
        // retries with a fresh revision until authoritative. The daemon is
        // public here (the make-private was rejected), so it reconciles to
        // public once a read succeeds.
        let fake = FakeDaemonClient()
        fake.privacySnapshotFailures = [DaemonClientError.transport("dropped")]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.setPrivateBatchFailures = [DaemonClientError.daemon(code: -32_602, message: "bad")]
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        try? await Task.sleep(nanoseconds: 500_000_000)  // past the first backoff
        #expect(privacyState(workspace) == .publicVisible)   // retried past the loss
        #expect(fake.privacySnapshotCalls.count >= 2)
    }

    @Test
    func reconcileRetriesUnfencedUntilFenced() async {
        // Finding: an unfenced result (not yet authoritative) keeps the tab
        // hidden AND retries: it doesn't abandon the tab. Once a snapshot
        // fences, it reconciles (public here, the make-private was rejected).
        let fake = FakeDaemonClient()
        fake.privacySnapshotFencedQueue = [false, false]  // then default true
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.setPrivateBatchFailures = [DaemonClientError.daemon(code: -32_602, message: "bad")]
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        // Hidden while unfenced.
        #expect(workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.isEffectivelyHidden == true)
        try? await Task.sleep(nanoseconds: 900_000_000)  // past two backoffs → fenced
        #expect(privacyState(workspace) == .publicVisible)
        #expect(fake.privacySnapshotCalls.count >= 3)
    }

    @Test
    func reconcileDiscardedWhenNewerTransitionStartsDuringSnapshot() async {
        // A snapshot response is discarded if a newer transition took over
        // while it was in flight: the newer transition drives the tab.
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        // Make-private rejected → triggers a reconcile; hold the snapshot.
        fake.armPrivacySnapshotBarrier()
        fake.setPrivateBatchFailures = [DaemonClientError.daemon(code: -32_602, message: "bad")]
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // A newer make-private starts while the snapshot is parked.
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        fake.releasePrivacySnapshot()        // stale snapshot returns, discarded
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // The newer transition drives; tab is hidden (make-private).
        #expect(workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.isEffectivelyHidden == true)
    }

    @Test
    func stalePredecessorReplyDoesNotDemoteCommittedPublicTab() async {
        // Fix for the regression the synchronous mark introduced: a superseded
        // predecessor's late reply must NOT schedule a reconcile (which would
        // synchronously demote to `.pendingPrivate`) once a newer transition
        // committed a higher-revision state. The reply's revision is below the
        // last commit, so it's ignored.
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        // A make-private predecessor parks in flight.
        fake.armSetPrivateBatchStallFirstOnly()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        // A make-public successor commits at a higher revision.
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: false))
        await settle()
        #expect(privacyState(workspace) == .publicVisible)
        // The stale predecessor arrives: superseded and below the last
        // commit → no reconcile, no demote.
        fake.releaseSetPrivateBatch()
        await settle()
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(privacyState(workspace) == .publicVisible)
    }

    @Test
    func windowReservedClosingSynchronouslyOnDispatch() async {
        // The reservation must be SYNCHRONOUS with accepting the close, before
        // the drain handles it: otherwise a transfer during the enqueue gap
        // slips a foreign tab in that the handler's snapshot then destroys. So
        // `isWindowClosing` is true immediately after `dispatch`, with NO
        // settle, and stays true across the teardown, clearing when done.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.armCloseSessionBarrier()
        router.dispatch(.closeWindow(WindowID(value: 1), mode: .shutdown))
        // No settle: the reservation must already hold the instant the close
        // is accepted (closing the enqueue-to-handler gap).
        #expect(router.isWindowClosing(WindowID(value: 1)))
        await settle()
        #expect(router.isWindowClosing(WindowID(value: 1)))          // during teardown
        fake.releaseCloseSession()
        await settle()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(router.isWindowClosing(WindowID(value: 1)) == false) // cleared after
    }

    @Test
    func inboundMoveDuringWindowCloseLeavesForeignTabIntact() async {
        // If a tab is moved INTO a closing window (simulating a transfer that
        // bypassed the coordinator freeze), it must NOT be torn down: the
        // close is authorized only for the ORIGINAL membership. The Router
        // closes the snapshot set and leaves the straggler intact; the window
        // is not removed while it holds one.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),  // W1/T1
            SessionCreateResponse(sessionId: "S2", capability: "C2")   // W2/T2
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())   // window 1, tab 1 (S1)
        await settle()
        router.dispatch(.openWindow())   // window 2, tab 2 (S2)
        await settle()
        // Close window 1, stalling closeSession so its teardown lingers.
        fake.armCloseSessionBarrier()
        router.dispatch(.closeWindow(WindowID(value: 1), mode: .shutdown))
        await settle()
        // Move tab 2 into the closing window 1 (bypassing the coordinator).
        if let state = workspace.window(id: WindowID(value: 2))?.tabs.detach(id: TabID(value: 2)) {
            workspace.window(id: WindowID(value: 1))?.tabs.insert(state, at: 0)
        }
        fake.releaseCloseSession()
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // The original tab was closed; the moved-in (unauthorized) tab was NOT
        // destroyed, and it keeps the window alive.
        #expect(fake.closeSessionCalls.contains { $0.sessionId == "S1" })
        #expect(fake.closeSessionCalls.contains { $0.sessionId == "S2" } == false)
        #expect(workspace.window(id: WindowID(value: 1))?.tabs.tab(id: TabID(value: 2)) != nil)
    }

    @Test
    func signatureRejectionLeavesTabFailClosedHidden() async {
        // `-32011` is a STABLE signature rejection: definite and terminal on
        // either transport (retrying a cached verdict can't succeed): the smoke
        // UDS structural refusal AND a genuine XPC signature mismatch. The write
        // must NOT retry-storm; the tab stays fail-closed hidden and unresolved.
        // (The transient, retryable outcome is -32002, tested separately.)
        let fake = FakeDaemonClient()
        fake.setPrivateBatchFailures = [DaemonClientError.daemon(code: -32_011, message: "no")]
        fake.privacySnapshotFailures = [DaemonClientError.daemon(code: -32_011, message: "no")]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(privacyState(workspace) == .pendingPrivate)   // fail-closed hidden
        #expect(fake.setPrivateBatchCalls.count == 1)          // terminal: no retry
        #expect(fake.privacySnapshotCalls.count == 1)          // reconcile, no storm
    }

    @Test
    func closeDuringCrossWindowMoveRemovesTabFromLiveWindow() async {
        // A tab closed in window 1 but relocated to window 2 during its
        // teardown awaits must be removed from its LIVE window (2), not the
        // stale captured source: else it survives with its sessions closed
        // and, once the tombstone drops, a late privacy reply resurrects a
        // reconcile there.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())   // window 1, tab 1 (S1)
        await settle()
        router.dispatch(.openWindow())   // window 2, tab 2 (S2)
        await settle()
        // Tab 1: a make-private batch parks in flight.
        fake.armSetPrivateBatchBarrier()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        // Close tab 1, stalling closeSession so its teardown lingers.
        fake.armCloseSessionBarrier()
        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .shutdown))
        await settle()
        // Cross-window move during the stalled teardown (as the AppDelegate
        // coordinator does): relocate tab 1 from window 1 to window 2.
        if let state = workspace.window(id: WindowID(value: 1))?.tabs.detach(id: TabID(value: 1)) {
            workspace.window(id: WindowID(value: 2))?.tabs.insert(state, at: 0)
        }
        // Let the teardown finish → the close re-resolves and removes tab 1
        // from window 2. Then the parked privacy reply returns (tombstone now
        // dropped).
        fake.releaseCloseSession()
        await settle()
        fake.releaseSetPrivateBatch()
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Removed from its live window, not left a zombie, and no reconcile.
        #expect(workspace.window(id: WindowID(value: 2))?.tabs.tab(id: TabID(value: 1)) == nil)
        #expect(fake.privacySnapshotCalls.isEmpty)
    }

    @Test
    func lateReplyDuringMultiTabWindowCloseDoesNotResurrectReconcile() async {
        // Multi-tab window close: tab 1's teardown completes (its tombstone
        // dropped) while tab 2's teardown is still stalled. Tab 1 must already
        // be removed from the workspace, or its late privacy reply (arriving
        // during tab 2's stall) would resurrect a reconcile.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())                 // tab 1 (S1)
        await settle()
        router.dispatch(.newTab(WindowID(value: 1)))   // tab 2 (S2)
        await settle()
        // Tab 1: a make-private batch parks in flight.
        fake.armSetPrivateBatchBarrier()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        // Close the WINDOW; tab 1's closeSession passes, tab 2's stalls, so
        // tab 1 is fully torn down (and removed) while tab 2 lingers.
        fake.armCloseSessionBarrierExceptFirst()
        router.dispatch(.closeWindow(WindowID(value: 1), mode: .shutdown))
        await settle()
        // Tab 1's parked batch returns while tab 2's close is stalled.
        fake.releaseSetPrivateBatch()
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.privacySnapshotCalls.isEmpty)  // no reconcile resurrected
        fake.releaseCloseSession()                   // let tab 2's close finish
        await settle()
    }

    @Test
    func lateReplyDuringTabCloseDoesNotResurrectReconcile() async {
        // Close-in-progress window: `closeTabRecords` cancels privacy work then
        // awaits daemon teardown (here a stalled `closeSession`) while the tab
        // is STILL in the workspace. A cancelled transition's late reply during
        // that window must not resurrect a reconcile: the closing tombstone
        // blocks it even though the tab still appears present.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.armSetPrivateBatchBarrier()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        // Close the tab, stalling closeSession so the tab lingers in the
        // workspace through the teardown awaits.
        fake.armCloseSessionBarrier()
        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .shutdown))
        await settle()
        // The parked batch returns during the close (cancelled transition).
        fake.releaseSetPrivateBatch()
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.privacySnapshotCalls.isEmpty)  // no reconcile resurrected
        fake.releaseCloseSession()                   // let the close complete
        await settle()
    }

    @Test
    func lateReplyAfterShutdownDoesNotResurrectReconcile() async {
        // Cleanup is authoritative: a cancelled transition's late RPC reply,
        // returning after `shutdown()`, must not resurrect a reconcile task
        // (the `isShutdown` tombstone stops `scheduleReconcile`).
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.armSetPrivateBatchBarrier()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        await router.shutdown()          // cancels the transition, sets the tombstone
        fake.releaseSetPrivateBatch()    // the parked batch returns post-shutdown
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.privacySnapshotCalls.isEmpty)  // no reconcile resurrected
    }

    @Test
    func appliedFalseMarksTabPendingSynchronously() async {
        // An idempotent make-public returning applied:false (a higher key
        // won, the daemon may now be private) must fail-closed SYNCHRONOUSLY,
        // not stay `.publicVisible` until the async snapshot responds. Hold
        // the snapshot and assert the tab is already hidden.
        let fake = FakeDaemonClient()
        fake.setPrivateBatchApplied = [false]  // make-public loses the race
        fake.armPrivacySnapshotBarrier()        // hold the reconcile snapshot
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        #expect(privacyState(workspace) == .publicVisible)
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: false))
        await settle()
        // Marked pending synchronously, before the held snapshot responds.
        #expect(privacyState(workspace) == .pendingPrivate)
        #expect(workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.isEffectivelyHidden == true)
        fake.releasePrivacySnapshot()
    }

    @Test
    func reconcileRetriesTransientValidationUnavailable() async {
        // `-32002` is the TRANSIENT validation-unavailable outcome (distinct
        // from the terminal `-32011` signature rejection). The reconcile must
        // retry it (two transient failures then a success), never stranding the
        // tab; here the daemon is public, so it converges to public.
        let fake = FakeDaemonClient()
        fake.privacySnapshotFailures = [
            DaemonClientError.daemon(code: -32_002, message: "unavailable"),
            DaemonClientError.daemon(code: -32_002, message: "unavailable")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.setPrivateBatchFailures = [DaemonClientError.daemon(code: -32_602, message: "bad")]
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        // Hidden while the transient failures retry.
        #expect(workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.isEffectivelyHidden == true)
        try? await Task.sleep(nanoseconds: 900_000_000)  // past two backoffs
        #expect(privacyState(workspace) == .publicVisible)   // converged, not stranded
        #expect(fake.privacySnapshotCalls.count >= 3)
    }

    @Test
    func addingTerminalToPendingPrivateTabDoesNotReveal() async {
        // A tab left hidden-but-unresolved (`.pendingPrivate`, no active
        // transition) must not be revealed by adding a split terminal. The
        // openTerminalPane reconcile compares EFFECTIVE-hidden (not committed
        // `isPrivate`), so a hidden tab matches a terminal minted hidden and
        // is not kicked toward public.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        // Make-private rejected → tab left `.pendingPrivate` with the
        // reconcile snapshot held, so no transition is active.
        fake.armPrivacySnapshotBarrier()
        fake.setPrivateBatchFailures = [DaemonClientError.daemon(code: -32_602, message: "bad")]
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(privacyState(workspace) == .pendingPrivate)
        // Add a split terminal: must NOT reveal the hidden tab.
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        #expect(workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.isEffectivelyHidden == true)
        fake.releasePrivacySnapshot()
    }

    @Test
    func supersededSendDoesNotBlockOnStalledPredecessor() async {
        // Daemon-side `(epoch, revision)` ordering: the GUI sends the
        // successor immediately; daemon ordering fences a stalled
        // predecessor. A later privacy change sends its own batch immediately
        // even while a predecessor's batch is stalled in flight. The stale
        // predecessor loses the race daemon-side, so it can't reorder, and a
        // permanently stalled predecessor can never wedge the successor.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.armSetPrivateBatchBarrier()                 // stall every batch
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        #expect(fake.setPrivateBatchCalls.count == 1)    // first batch in flight
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: false))
        try? await Task.sleep(nanoseconds: 200_000_000)
        // The successor sent its own batch without waiting for the stalled
        // predecessor: no wedge.
        #expect(fake.setPrivateBatchCalls.count == 2)
        fake.releaseSetPrivateBatch()
    }

    @Test
    func stalledPrivacyRPCReportsPendingWithoutBlocking() async {
        // A stalled setPrivateBatch must not wedge the command drain: the
        // awaited outcome reports `.pending` at the deadline while the
        // transition keeps converging in the background.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.privacyOutcomeDeadlineNanos = 50_000_000  // 50ms
        fake.armSetPrivateBatchBarrier()                 // stall forever
        let outcome = await router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: true)
        #expect(outcome == .pending)
        fake.releaseSetPrivateBatch()
    }

    @Test
    func terminalAddedDuringTransitionIsReconciled() async {
        // A terminal created while a private transition's batch is in
        // flight is folded in: it's created private (from the still-hidden
        // tab), and the transition reconverges over the new membership so
        // the committed batch covers both sessions: no session is left in
        // the opposite daemon state when the tab commits.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        // Hold the first batch so a terminal can be added mid-flight.
        fake.armSetPrivateBatchBarrier()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        #expect(privacyState(workspace) == .pendingPrivate)
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        // The added terminal was created private at the source.
        #expect(fake.createSessionCalls.last?.initialPrivate == true)
        fake.releaseSetPrivateBatch()
        await settle()
        // Converged: a batch covering both sessions acked, and the tab is
        // committed private.
        #expect(privacyState(workspace) == .privateHidden)
        let coveredBoth = fake.setPrivateBatchCalls.contains {
            Set($0.sessionIds) == ["S1", "S2"] && $0.isPrivate
        }
        #expect(coveredBoth)
    }

    @Test
    func transitionWaitsForInFlightTerminalCreate() async {
        // The exposure race, closed by per-tab ordering: a terminal create
        // is suspended in `createSession` (its session id unknown) when a
        // public→private transition begins off the route drain (via
        // `applyTabPrivacy`). The transition must WAIT for that create
        // rather than batch over {S1} alone: otherwise the new session
        // would be minted public and stranded exposed under a
        // committed-private tab until a later reconcile.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.armCreateSessionBarrier()
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        #expect(fake.createSessionsWaiting == 1)  // S2 mint suspended, in flight
        // Privacy change begins off-drain while the create is in flight.
        async let outcome = router.applyTabPrivacy(tab: TabID(value: 1), isPrivate: true)
        await settle()
        // Fail-closed hidden while waiting, but NO premature batch.
        #expect(privacyState(workspace) == .pendingPrivate)
        #expect(fake.setPrivateBatchCalls.isEmpty)
        // Let the create finish; the transition's batch now covers both.
        fake.releaseCreateSession()
        let result = await outcome
        await settle()
        #expect(result == .committed)
        #expect(privacyState(workspace) == .privateHidden)
        #expect(fake.setPrivateBatchCalls.contains {
            Set($0.sessionIds) == ["S1", "S2"] && $0.isPrivate
        })
        // Never committed over {S1} alone (which would have exposed S2).
        #expect(!fake.setPrivateBatchCalls.contains {
            Set($0.sessionIds) == ["S1"] && $0.isPrivate
        })
    }

    @Test
    func setTabPrivateRetriesIndeterminateThenCommits() async {
        // An indeterminate transport loss is retried with the same
        // idempotent batch until it acks: the tab stays hidden across the
        // retry and only commits once the daemon answers.
        let fake = FakeDaemonClient()
        fake.setPrivateBatchFailures = [
            DaemonClientError.transport("dropped")
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        // First attempt throws transport; the loop backs off ~200ms then
        // retries and acks. Wait past that.
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(fake.setPrivateBatchCalls.count >= 2)
        #expect(privacyState(workspace) == .privateHidden)
    }

    @Test
    func setTabPrivateLastTransitionWins() async {
        // Ordering: a rapid private→public converges on the last requested
        // state, and the superseded transition's late resolution can't
        // resurrect the opposite one. Ordering is daemon-enforced by
        // `(epoch, revision)` last-write-wins, not GUI serialization: a
        // stale older write loses at the daemon.
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        fake.armSetPrivateBatchBarrier()
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: true))
        await settle()
        // Supersede with a public transition while the private one is
        // still suspended on the barrier.
        router.dispatch(.setTabPrivate(tab: TabID(value: 1), isPrivate: false))
        await settle()
        fake.releaseSetPrivateBatch()
        await settle()
        #expect(privacyState(workspace) == .publicVisible)
        #expect(fake.setPrivateBatchCalls.count == 2)
        #expect(fake.setPrivateBatchCalls.last?.isPrivate == false)
    }

    // MARK: - Pending panes (optimistic insert / failure / retry / cancel)

    private func pendingPanes(
        _ workspace: WorkspaceViewModel,
        tab: TabID = TabID(value: 1)
    ) -> [PendingPaneState] {
        workspace.window(id: WindowID(value: 1))?.tabs.tab(id: tab)?.pendingPanes ?? []
    }

    private func simPanes(
        _ workspace: WorkspaceViewModel,
        tab: TabID = TabID(value: 1)
    ) -> [SimPaneState] {
        workspace.window(id: WindowID(value: 1))?.tabs.tab(id: tab)?.simPanes ?? []
    }

    private func leaves(
        _ workspace: WorkspaceViewModel,
        tab: TabID = TabID(value: 1)
    ) -> [PaneSlot] {
        guard let tree = workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: tab)?.paneTree else { return [] }
        return PaneTreeOps.leavesInOrder(tree)
    }

    @Test
    func attachInsertsPendingPaneBeforeRPCResolves() async {
        // The whole point: the placeholder appears the instant the user
        // acts, before the (slow) attach returns. With the barrier armed
        // the attach is suspended, so after settling we must already see
        // a `.attaching` pending pane + a `.pending` leaf, and no real
        // sim pane yet.
        let fake = FakeDaemonClient()
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        #expect(pendingPanes(workspace).count == 1)
        #expect(pendingPanes(workspace).first?.phase == .attaching)
        #expect(simPanes(workspace).isEmpty)
        #expect(fake.attachDeviceCalls.count == 1)   // RPC is in flight…
        #expect(fake.attachesWaiting == 1)           // …and suspended
        #expect(leaves(workspace).contains { if case .pending = $0 { return true }; return false })
        // Releasing the barrier lets the attach finish and swap in.
        fake.releaseAttach()
        await settle()
        #expect(pendingPanes(workspace).isEmpty)
        #expect(simPanes(workspace).map(\.udid) == ["U"])
        #expect(leaves(workspace).contains(.sim(udid: "U")))
    }

    @Test
    func attachFailureShowsFailedPendingThenRetrySucceeds() async {
        // A thrown attach lands the placeholder in `.failed` (with the
        // error), not silent stderr; Retry re-runs the attach and, on
        // success, swaps in the real pane.
        let fake = FakeDaemonClient()
        fake.attachError = FakeDaemonError.attachFailed
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        #expect(simPanes(workspace).isEmpty)
        #expect(pendingPanes(workspace).count == 1)
        guard let pendingId = pendingPanes(workspace).first?.id,
            case .failed = pendingPanes(workspace).first?.phase else {
            Issue.record("expected a failed pending pane")
            return
        }
        // The `.pending` leaf stays in the tree so the pane keeps its slot.
        #expect(leaves(workspace).contains(.pending(pendingId)))
        // Retry now succeeds.
        fake.attachError = nil
        router.dispatch(.retryPendingPane(tab: TabID(value: 1), pendingId: pendingId))
        await settle()
        #expect(pendingPanes(workspace).isEmpty)
        #expect(simPanes(workspace).map(\.udid) == ["U"])
        #expect(fake.attachDeviceCalls.count == 2)   // first try + retry
    }

    @Test
    func routeDrainAdvancesWhileAttachBlocked() async {
        // The core regression: a slow attach must not freeze the serial
        // route drain. With the attach barrier held, a route dispatched
        // afterward (open a terminal pane) is fully processed *before*
        // the attach completes.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        router.dispatch(.openTerminalPane(tab: TabID(value: 1)))
        await settle()
        // The terminal was added even though the attach is still blocked.
        let tab = workspace.window(id: WindowID(value: 1))?.tabs.tab(id: TabID(value: 1))
        #expect(tab?.terminals.count == 2)
        #expect(fake.attachesWaiting == 1)                 // attach still suspended
        #expect(pendingPanes(workspace).first?.phase == .attaching)
        fake.releaseAttach()
        await settle()
        #expect(simPanes(workspace).map(\.udid) == ["U"])
    }

    @Test
    func attachDedupesAgainstFailedPending() async {
        // A second attach for a target that already has a *failed*
        // pending pane is a no-op: discovery / menu / CLI can't stack
        // duplicate failed placeholders or re-fire the RPC. Case-
        // insensitive on the sim UDID, like the mounted-pane dedup.
        let fake = FakeDaemonClient()
        fake.attachError = FakeDaemonError.attachFailed
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "abcUDID", displayName: "iPhone"))
        await settle()
        #expect(pendingPanes(workspace).count == 1)
        // Same target, different case → deduped against the failed pending.
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "ABCUDID", displayName: "iPhone"))
        await settle()
        #expect(pendingPanes(workspace).count == 1)
        #expect(fake.attachDeviceCalls.count == 1)
    }

    @Test
    func twoConcurrentAttachesBothMount() async {
        let fake = FakeDaemonClient()
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "A", displayName: "iPhone A"))
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "B", displayName: "iPhone B"))
        await settle()
        #expect(pendingPanes(workspace).count == 2)
        #expect(fake.attachesWaiting == 2)
        fake.releaseAttach()
        await settle()
        #expect(Set(simPanes(workspace).map(\.udid)) == ["A", "B"])
        #expect(fake.attachDeviceCalls.count == 2)
    }

    @Test
    func cancelPendingClosesPaneThatMaterializesAfterCancel() async {
        // Cancel (or tab close) while the attach is in flight drops the
        // placeholder; when the attach then returns a pane id (it
        // materialized after teardown), the Task closes it so the daemon
        // pane + IOSurface stream don't leak.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "LEAK", scale: nil, family: "phone")
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        guard let pendingId = pendingPanes(workspace).first?.id else {
            Issue.record("expected a pending pane")
            return
        }
        router.dispatch(.cancelPendingPane(tab: TabID(value: 1), pendingId: pendingId, mode: .detach))
        await settle()
        #expect(pendingPanes(workspace).isEmpty)
        // Now the attach returns: the pane materialized after cancel.
        fake.releaseAttach()
        await settle()
        #expect(simPanes(workspace).isEmpty)
        #expect(fake.closePaneCalls == [.init(paneId: "LEAK", mode: .detach)])
    }

    @Test
    func closingTabWhileAttachBlockedClosesMaterializedPane() async {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "LEAK", scale: nil, family: "phone")
        fake.armAttachBarrier()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .detach))
        await settle()
        fake.releaseAttach()
        await settle()
        #expect(fake.closePaneCalls.contains(.init(paneId: "LEAK", mode: .detach)))
    }

    @Test
    func closingWindowWhileAttachBlockedClosesMaterializedPane() async {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "LEAK", scale: nil, family: "phone")
        fake.armAttachBarrier()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        router.dispatch(.closeWindow(WindowID(value: 1), mode: .detach))
        await settle()
        fake.releaseAttach()
        await settle()
        #expect(fake.closePaneCalls.contains(.init(paneId: "LEAK", mode: .detach)))
    }

    @Test
    func attachResumingDuringTabTeardownClosesPaneNotMounts() async {
        // The race: a tab closed while an attach is in flight cancels the
        // attach task but leaves the pending record until the close RPCs
        // finish awaiting. Suspend `closeSession` so the teardown is
        // mid-flight, then let the attach resume: it must close the pane
        // it materialized, NOT mount it into the tearing-down tab (which
        // closeTabRecords' simPanes snapshot would never close → leak).
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "LEAK", scale: nil, family: "phone")
        fake.armAttachBarrier()
        fake.armCloseSessionBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        // Close the tab: teardown suspends at closeSession with the
        // pending pane still in nav state and the tab not yet removed.
        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .detach))
        await settle()
        #expect(fake.closeSessionsWaiting == 1)            // teardown mid-flight
        #expect(pendingPanes(workspace).count == 1)        // pending still present
        // Attach resumes *now*, while the tab is mid-teardown.
        fake.releaseAttach()
        await settle()
        // It closed the materialized pane instead of mounting it.
        #expect(fake.closePaneCalls.contains(.init(paneId: "LEAK", mode: .detach)))
        #expect(simPanes(workspace).isEmpty)
        // Let the teardown finish.
        fake.releaseCloseSession()
        await settle()
        #expect(workspace.window(id: WindowID(value: 1))?.tabs.tabs.isEmpty == true)
    }

    @Test
    func attachSuccessPreservesTreePosition() async {
        // The pending leaf occupies index 1 (after the primary
        // terminal); the success swap replaces it in place, so the real
        // sim leaf lands at the same position rather than being appended
        // elsewhere.
        let fake = FakeDaemonClient()
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        let pendingLeaves = leaves(workspace)
        #expect(pendingLeaves.count == 2)
        guard case .pending = pendingLeaves[1] else {
            Issue.record("expected the pending leaf at index 1")
            return
        }
        fake.releaseAttach()
        await settle()
        #expect(leaves(workspace)[1] == .sim(udid: "U"))
    }

    @Test
    func reattachPreservesOrphanDirWhenAttachFails() async throws {
        let fake = FakeDaemonClient()
        fake.attachError = FakeDaemonError.attachFailed
        let (router, workspace) = makeRouter(fake)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let orphan = OrphanRecord(
            sessionId: "old",
            sessionDir: dir,
            liveSims: [OrphanLiveSim(udid: "U", displayName: "iPhone")]
        )
        router.dispatch(.openWindow(reattach: [orphan]))
        await settle()
        #expect(
            workspace.window(id: WindowID(value: 1))?.tabs
            .tab(id: TabID(value: 1))?.simPanes.isEmpty == true
            )
        // Attach failed → dir is preserved so the orphan re-surfaces.
        #expect(FileManager.default.fileExists(atPath: dir))
    }

    @Test
    func reattachDoesNotHoldTheRouteDrain() async throws {
        // Orphan reattach runs off the route drain, so a stalled attach
        // doesn't block later routes, tab switching included.
        let fake = FakeDaemonClient()
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let orphan = OrphanRecord(
            sessionId: "old",
            sessionDir: dir,
            liveSims: [OrphanLiveSim(udid: "U", displayName: "iPhone")]
        )
        router.dispatch(.openWindow(reattach: [orphan]))
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        #expect(workspace.window(id: WindowID(value: 1))?.tabs.tabs.count == 2)
        #expect(fake.attachesWaiting == 1)
        #expect(pendingPanes(workspace).first?.phase == .attaching)
        // The dir survives while the batch is unsettled: cleanup is the last
        // attach's decision, not the drain's.
        #expect(FileManager.default.fileExists(atPath: dir))
        fake.releaseAttach()
        await settle()
        #expect(simPanes(workspace).map(\.udid) == ["U"])
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test
    func reattachPreservesOrphanDirWhenOnlySomeSimsMount() async throws {
        // Partial adoption is not adoption: one sim of the record mounts,
        // the other fails, and the dir stays so the survivor is re-offered
        // next launch rather than silently dropped.
        let fake = FakeDaemonClient()
        fake.attachFailure = { udid, _ in
            udid == "U2" ? FakeDaemonError.attachFailed : nil
        }
        let (router, workspace) = makeRouter(fake)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let orphan = OrphanRecord(
            sessionId: "old",
            sessionDir: dir,
            liveSims: [
                OrphanLiveSim(udid: "U1", displayName: "iPhone"),
                OrphanLiveSim(udid: "U2", displayName: "iPad")
            ]
        )
        router.dispatch(.openWindow(reattach: [orphan]))
        await settle()
        #expect(simPanes(workspace).map(\.udid) == ["U1"])
        #expect(pendingPanes(workspace).count == 1)  // U2's failed placeholder
        #expect(FileManager.default.fileExists(atPath: dir))
    }

    @Test
    func closingTheTabMidReattachPreservesTheOrphanDir() async throws {
        // The batch owner outlives the drain, so it needs its own tombstone:
        // a tab closed while its attaches are still in flight must not have
        // its record cleaned up when they finally settle.
        let fake = FakeDaemonClient()
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let orphan = OrphanRecord(
            sessionId: "old",
            sessionDir: dir,
            liveSims: [OrphanLiveSim(udid: "U", displayName: "iPhone")]
        )
        router.dispatch(.openWindow(reattach: [orphan]))
        await settle()
        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .detach))
        await settle()
        fake.releaseAttach()
        await settle()
        #expect(workspace.window(id: WindowID(value: 1))?.tabs.tabs.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: dir))
    }

    @Test
    func closingAPendingPaneLeavesTheAttachRunningSoItCanCleanUp() async {
        // Closing the placeholder doesn't cancel the attach, so the reply
        // still reaches the post-await guard and the pane it names is
        // detached. (Cancelling wouldn't strand it either, since the late
        // cleanup would take it, but it would split replies across two paths
        // for nothing.)
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "LEAK", scale: nil, family: "phone")
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        guard let pendingId = pendingPanes(workspace).first?.id else {
            Issue.record("expected a pending pane")
            return
        }
        router.dispatch(.cancelPendingPane(tab: TabID(value: 1), pendingId: pendingId, mode: .detach))
        await settle()
        // The escape is immediate: the leaf is gone before the daemon answers.
        #expect(pendingPanes(workspace).isEmpty)
        #expect(fake.attachesWaiting == 1)
        fake.releaseAttach()
        await settle()
        #expect(simPanes(workspace).isEmpty)
        #expect(fake.closePaneCalls == [.init(paneId: "LEAK", mode: .detach)])
    }

    @Test
    func aClosedAttachDoesNotTearDownTheAttachThatReplacedIt() async {
        // Closing a placeholder frees its target, so another attach for the
        // same target can start (discovery re-offers a booted sim every couple
        // of seconds) while the first request is still running. The daemon
        // hands the owning session back its existing pane, so both land on the
        // same paneId, and the first one's cleanup would otherwise close the
        // pane the second just mounted, leaving a live-looking pane whose
        // daemon side is gone.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "SHARED", scale: nil, family: "phone")
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        guard let firstPending = pendingPanes(workspace).first?.id else {
            Issue.record("expected a pending pane")
            return
        }
        router.dispatch(
            .cancelPendingPane(tab: TabID(value: 1), pendingId: firstPending, mode: .detach)
        )
        await settle()
        // Second attach for the same target, while the first is still parked.
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        #expect(fake.attachesWaiting == 2)
        fake.releaseAttach()
        await settle()
        #expect(simPanes(workspace).map(\.paneId) == ["SHARED"])
        #expect(fake.closePaneCalls.isEmpty, "the surviving pane must not be closed")
    }

    @Test
    func everyCloseCarriesTheAdmissionItWasIssuedAgainst() async {
        // The GUI-side half of the close fence: whatever the attach response
        // said, the close echoes it back, so the daemon can refuse a close
        // whose admission has been superseded. Covers the two paths that close
        // a pane the GUI mounted and the one that closes a pane it never did.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, attachment: 42, family: "phone")
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        #expect(simPanes(workspace).first?.attachment == 42)
        router.dispatch(.detachSimPane(tab: TabID(value: 1), udid: "U", mode: .detach))
        await settle()
        #expect(fake.closePaneCalls == [.init(paneId: "P1", mode: .detach, attachment: 42)])
    }

    @Test
    func anUnclaimedPaneIsClosedAgainstItsOwnAdmission() async {
        // The reconciliation path: the pane the GUI never mounted is closed
        // against the admission the attach that produced it was given, not
        // against whatever admission the record holds by then.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "LEAK",
            scale: nil,
            attachment: 7,
            family: "phone"
        )
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        guard let pendingId = pendingPanes(workspace).first?.id else {
            Issue.record("expected a pending pane")
            return
        }
        router.dispatch(.cancelPendingPane(tab: TabID(value: 1), pendingId: pendingId, mode: .detach))
        await settle()
        fake.releaseAttach()
        await settle()
        #expect(fake.closePaneCalls == [.init(paneId: "LEAK", mode: .detach, attachment: 7)])
    }

    @Test
    func anAttachWaitsOutADetachAlreadyInFlightForItsTarget() async {
        // The claim check that authorizes a detach is synchronous, but the
        // close itself suspends. An attach sent into that gap finds the target
        // free, and because daemon dispatch is non-FIFO it can be handed the
        // record being closed and mount it just in time to watch it die. So
        // the attach waits for the close instead of racing it.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "DOOMED", scale: nil, family: "phone")
        fake.armAttachBarrier()
        fake.armClosePaneBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        guard let pendingId = pendingPanes(workspace).first?.id else {
            Issue.record("expected a pending pane")
            return
        }
        // Close the placeholder, then let the attach land: nothing claims the
        // target, so it detaches, and the close parks.
        router.dispatch(.cancelPendingPane(tab: TabID(value: 1), pendingId: pendingId, mode: .detach))
        await settle()
        fake.releaseAttach()
        await settle()
        #expect(fake.closePanesWaiting == 1)
        // A new attach for the same target, sent while the close is parked.
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        #expect(
            fake.attachDeviceCalls.count == 1,
            "the second attach must not reach the daemon until the detach lands"
            )
        fake.releaseClosePane()
        await settle()
        // Once the close is done the attach goes out and mounts normally.
        #expect(fake.attachDeviceCalls.count == 2)
        #expect(simPanes(workspace).map(\.udid) == ["U"])
    }

    @Test
    func closingATabDoesNotDetachAPaneAnotherTabAdopted() async {
        // Closing a tab kills its session, and a dead owner is exactly what
        // lets another tab's in-flight attach adopt the same record: the
        // daemon transfers the pane rather than refusing. So the closing tab's
        // own late reply must not detach it. Its placeholder is discounted
        // (it's the one going away); the other tab's claim is honored.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        // Both attaches land on one record, which is what adoption looks like
        // from here.
        fake.attachResult = PaneCreateResponse(paneId: "ADOPTED", scale: nil, family: "phone")
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        // Second tab attaches the same sim while the first is still parked.
        router.dispatch(.attachSimPane(tab: TabID(value: 2), udid: "U", displayName: "iPhone"))
        await settle()
        // Park the teardown at `closeSession`, so the first tab is still
        // mid-close (its placeholder present, its tombstone set) when its
        // attach resumes. That's the window this guard covers.
        fake.armCloseSessionBarrier()
        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .detach))
        await settle()
        #expect(fake.closeSessionsWaiting == 1)
        fake.releaseAttach()
        await settle()
        let adopted = simPanes(workspace, tab: TabID(value: 2)).map(\.paneId)
        #expect(adopted == ["ADOPTED"])
        #expect(fake.closePaneCalls.isEmpty, "the adopting tab's pane must survive")
        fake.releaseCloseSession()
        await settle()
    }

    @Test
    func anAdopterThatFailsReleasesTheClosingTabsPane() async {
        // The other half of the adoption case. The closing tab's pane is
        // deferred behind the adopter's attach, and then that attach fails.
        // Nothing else will ever ask again: the closing tab's placeholder
        // survives in nav state until its teardown finishes, and removing the
        // tab fires no reconciliation. So the closing tab's placeholder must
        // not count as a claim while its tab is being torn down, or the pane
        // stays alive and invisible.
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        fake.attachResult = PaneCreateResponse(paneId: "ORPHAN", scale: nil, family: "phone")
        fake.armAttachBarrier()
        // The closing tab's attach lands; the would-be adopter is refused.
        fake.attachFailure = { _, index in index == 0 ? nil : FakeDaemonError.attachFailed }
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 2), udid: "U", displayName: "iPhone"))
        await settle()
        fake.armCloseSessionBarrier()
        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .detach))
        await settle()
        #expect(fake.closeSessionsWaiting == 1)
        fake.releaseAttach()
        await settle()
        // Tab 2's attach failed, so nothing shows the target and the pane the
        // closing tab produced is detached rather than deferred forever.
        #expect(simPanes(workspace, tab: TabID(value: 2)).isEmpty)
        #expect(fake.closePaneCalls == [.init(paneId: "ORPHAN", mode: .detach)])
        fake.releaseCloseSession()
        await settle()
    }

    @Test
    func aReplacementThatFailsReleasesThePaneItWasProtecting() async {
        // The claim that defers a detach is a bet, not a fact: the newer
        // attach may be refused (another tab's session already owns the
        // target). If a failed replacement kept deferring, the pane the first
        // attach created would stay alive with nothing showing it and nothing
        // left to reconcile it.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "SHARED", scale: nil, family: "phone")
        fake.armAttachBarrier()
        // The first attach succeeds; the replacement is rejected.
        fake.attachFailure = { _, index in index == 0 ? nil : FakeDaemonError.attachFailed }
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        guard let firstPending = pendingPanes(workspace).first?.id else {
            Issue.record("expected a pending pane")
            return
        }
        router.dispatch(
            .cancelPendingPane(tab: TabID(value: 1), pendingId: firstPending, mode: .detach)
        )
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        fake.releaseAttach()
        await settle()
        // The replacement failed, so nothing claims the target and the pane
        // the first attach left behind is detached after all.
        #expect(simPanes(workspace).isEmpty)
        #expect(fake.closePaneCalls == [.init(paneId: "SHARED", mode: .detach)])
    }

    @Test
    func anAttachPastItsDeadlineFailsThePlaceholderAndDetachesTheLatePane() async {
        // The deadline ends the wait, not the daemon's work. The placeholder
        // flips to failed with Retry immediately, and the pane that shows up
        // afterwards is detached rather than left owned and invisible.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "LATE", scale: nil, family: "phone")
        fake.armAttachBarrier()
        let diagnostics = RPCPerformanceDiagnostics(automaticallyEmitSummaries: false)
        let (router, workspace) = makeRouter(fake, rpcPerformance: diagnostics)
        router.attachDeadlineNanos = 10_000_000
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        await settle()
        guard case let .failed(message) = pendingPanes(workspace).first?.phase else {
            Issue.record("expected the deadline to fail the placeholder")
            return
        }
        #expect(message.contains("timed out"))
        #expect(
            diagnostics.bucketsForTesting()["control:device.attach"]?.timeouts == 1
        )
        // The daemon finishes long after the client stopped waiting.
        fake.releaseAttach()
        await settle()
        #expect(simPanes(workspace).isEmpty)
        #expect(fake.closePaneCalls == [.init(paneId: "LATE", mode: .detach)])
    }

    @Test
    func aTimedOutAttachConvergesOnOnePaneWhenRetried() async {
        // A timeout abandons the wait, not the work: the daemon may have
        // finished the attach and be holding a pane this GUI never saw.
        // Retry is what converges that, because the daemon hands the owning
        // session its existing pane back for the same target. The GUI's half
        // of that contract is what's pinned here: one pane, and no close of
        // a pane it never mounted.
        let fake = FakeDaemonClient()
        fake.attachFailure = { _, index in
            index == 0
                ? DaemonClientError.timedOut(method: RPCMethod.deviceAttach.rawValue)
                : nil
        }
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil)
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        guard let pendingId = pendingPanes(workspace).first?.id,
            case let .failed(message) = pendingPanes(workspace).first?.phase else {
            Issue.record("expected a failed pending pane")
            return
        }
        #expect(message.contains("timed out"))
        router.dispatch(.retryPendingPane(tab: TabID(value: 1), pendingId: pendingId))
        await settle()
        #expect(simPanes(workspace).map(\.paneId) == ["P1"])
        #expect(pendingPanes(workspace).isEmpty)
        #expect(fake.closePaneCalls.isEmpty)
    }

    // MARK: - Recovering panes after a helper restart

    /// A workspace with one tab holding a mounted sim pane, which is the
    /// starting state every recovery test needs. The second attach of the
    /// same target returns a different pane id, because a restarted helper
    /// mints a new record rather than handing back the one it lost.
    private func makeRecoveryFixture(
        _ fake: FakeDaemonClient
    ) async -> (Router, WorkspaceViewModel) {
        fake.attachResponse = { _, index in
            PaneCreateResponse(paneId: index == 0 ? "P1" : "P2", scale: nil, family: "phone")
        }
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        return (router, workspace)
    }

    @Test
    func recoverPanesReattachesAMountedSimUnderAFreshPaneId() async {
        // Pane records live only in the helper's memory, so a helper that
        // restarted holds none of them. Nothing else re-creates them: the
        // restore batch covers sessions and terminal anchors, and the pane
        // subscription's own retry loop can only rejoin a record that still
        // exists. Without this the pane stays on screen bound to an id the
        // helper never had.
        let fake = FakeDaemonClient()
        let (router, workspace) = await makeRecoveryFixture(fake)
        #expect(simPanes(workspace).map(\.paneId) == ["P1"])
        router.dispatch(.recoverPanes)
        await settle()
        #expect(simPanes(workspace).map(\.paneId) == ["P2"])
        #expect(pendingPanes(workspace).isEmpty)
        #expect(fake.attachDeviceCalls.count == 2)
    }

    @Test
    func recoverPanesKeepsThePaneInItsSlot() async {
        // Recovery goes through a placeholder, so the leaf is rewritten
        // twice. Both rewrites are in-place replacements, which is what keeps
        // the pane where the user left it and (because divider proportions
        // are keyed by tree position, not by slot) keeps the split where they
        // left it too.
        let (router, workspace) = await makeRecoveryFixture(FakeDaemonClient())
        router.dispatch(
            .openTerminalPane(tab: TabID(value: 1), anchor: .sim(udid: "U"), side: .after)
        )
        await settle()
        let before = leaves(workspace)
        #expect(before.firstIndex(of: .sim(udid: "U")) == 1)
        router.dispatch(.recoverPanes)
        await settle()
        // The pane id proves the round trip happened, so an unchanged leaf
        // order means the slot survived it rather than that nothing ran.
        #expect(simPanes(workspace).map(\.paneId) == ["P2"])
        #expect(leaves(workspace) == before)
    }

    @Test
    func recoverPanesDoesNotCloseTheRecordItIsReplacing() async {
        // The old pane id names a record that died with the helper that held
        // it, so a close would be addressed to a helper that never had it.
        let fake = FakeDaemonClient()
        let (router, workspace) = await makeRecoveryFixture(fake)
        router.dispatch(.recoverPanes)
        await settle()
        #expect(fake.closePaneCalls.isEmpty)
        #expect(simPanes(workspace).count == 1)
    }

    @Test
    func recoverPanesLeavesAnUnreachableSimAsAFailedPlaceholder() async {
        // A sim shut down while the helper was dead can't come back, and the
        // honest outcome is the pane saying so where it was, with Retry and
        // Close, rather than disappearing out of the layout.
        let fake = FakeDaemonClient()
        let (router, workspace) = await makeRecoveryFixture(fake)
        fake.attachError = FakeDaemonError.attachFailed
        router.dispatch(.recoverPanes)
        await settle()
        #expect(simPanes(workspace).isEmpty)
        #expect(pendingPanes(workspace).count == 1)
        guard case .failed = pendingPanes(workspace).first?.phase else {
            Issue.record("expected the unreachable sim to fail in place")
            return
        }
        #expect(leaves(workspace).contains { if case .pending = $0 { true } else { false } })
    }

    @Test
    func aRecoveredPlaceholderKeepsTheLabelThePaneWasShowing() async {
        // The placeholder is on screen for as long as the attach takes, and
        // falling back to a UDID stub would rename the slot mid-recovery for
        // a pane the user can already see is theirs.
        let fake = FakeDaemonClient()
        fake.armAttachBarrier()
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        fake.releaseAttach()
        await settle()
        fake.armAttachBarrier()
        router.dispatch(.recoverPanes)
        await settle()
        #expect(pendingPanes(workspace).first?.displayName == "iPhone")
        fake.releaseAttach()
        await settle()
    }

    @Test
    func aRecoveredSimResolvesItsNameRatherThanReusingTheComposedOne() async {
        // The mounted label is already the composed "Name · Type" form.
        // Handing it back as the bare name would compose the type onto it
        // again on every restart, so recovery resolves the name from scratch
        // the way the first mount did.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "phone",
            deviceType: "iPhone 17 Pro"
        )
        fake.deviceListResult = [
            DeviceListEntry(udid: "U", name: "Blue", state: "Booted", ownedBySession: nil)
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: nil))
        await settle()
        #expect(simPanes(workspace).first?.displayName == "Blue · iPhone 17 Pro")
        router.dispatch(.recoverPanes)
        await settle()
        #expect(simPanes(workspace).first?.displayName == "Blue · iPhone 17 Pro")
    }

    @Test
    func retryingAFailedRecoveryDoesNotComposeTheDeviceTypeTwice() async {
        // The placeholder shows the composed label the pane already had, and
        // a Retry that handed that back as the bare name would compose the
        // type onto it again, once more per restart.
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "phone",
            deviceType: "iPhone 17 Pro"
        )
        fake.deviceListResult = [
            DeviceListEntry(udid: "U", name: "Blue", state: "Booted", ownedBySession: nil)
        ]
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: nil))
        await settle()
        #expect(simPanes(workspace).first?.displayName == "Blue · iPhone 17 Pro")
        fake.attachError = FakeDaemonError.attachFailed
        router.dispatch(.recoverPanes)
        await settle()
        guard let pendingId = pendingPanes(workspace).first?.id else {
            Issue.record("expected the failed recovery to leave a placeholder")
            return
        }
        #expect(pendingPanes(workspace).first?.displayName == "Blue · iPhone 17 Pro")
        fake.attachError = nil
        router.dispatch(.retryPendingPane(tab: TabID(value: 1), pendingId: pendingId))
        await settle()
        #expect(simPanes(workspace).first?.displayName == "Blue · iPhone 17 Pro")
    }

    @Test
    func aRecoveredDevicePaneKeepsThePickersName() async {
        // The device path has no name to resolve from: the response's `name`
        // is a human-set pane name the daemon leaves nil, so passing nil back
        // would rename the pane to a deviceId stub on every restart. Nothing
        // composes a device type onto a physical pane's label either, so the
        // picker's name is both the right thing to show and safe to reuse.
        let fake = FakeDaemonClient()
        fake.attachResponse = { _, index in
            PaneCreateResponse(paneId: index == 0 ? "P1" : "P2", scale: nil)
        }
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(
            .attachDevicePane(tab: TabID(value: 1), deviceId: "D1", displayName: "Test iPhone")
        )
        await settle()
        let tab = { workspace.window(id: WindowID(value: 1))?.tabs.tab(id: TabID(value: 1)) }
        #expect(tab()?.devicePanes.first?.displayName == "Test iPhone")
        router.dispatch(.recoverPanes)
        await settle()
        #expect(tab()?.devicePanes.map(\.paneId) == ["P2"])
        #expect(tab()?.devicePanes.first?.displayName == "Test iPhone")
    }

    @Test
    func recoveringSeveralPanesRecordsEachOriginalIndex() async {
        // The index is what the typed array's order is rebuilt from, and it
        // has to be each pane's own. `TabListViewModelTests` covers what
        // happens when the attaches then finish out of order, which this
        // can't drive: the fake's barrier releases in dispatch order.
        let fake = FakeDaemonClient()
        fake.attachResponse = { udid, _ in
            PaneCreateResponse(paneId: "pane-\(udid)", scale: nil, family: "phone")
        }
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        for udid in ["A", "B", "C"] {
            router.dispatch(
                .attachSimPane(tab: TabID(value: 1), udid: udid, displayName: "iPhone \(udid)")
            )
            await settle()
        }
        #expect(simPanes(workspace).map(\.udid) == ["A", "B", "C"])
        fake.armAttachBarrier()
        router.dispatch(.recoverPanes)
        await settle()
        #expect(pendingPanes(workspace).map(\.atIndex) == [0, 1, 2])
        fake.releaseAttach()
        await settle()
        #expect(simPanes(workspace).map(\.udid) == ["A", "B", "C"])
    }

    @Test
    func recoverPanesRetriesAPlaceholderAnInterruptedRecoveryLeftFailed() async {
        // A second restart while recovery is running fails the attaches it
        // started, and those panes are no longer mounted, so a sweep over
        // mounted panes alone can't see them. They would sit as failed
        // placeholders waiting for a click, which is the promise holding for
        // the first restart and not the second.
        let fake = FakeDaemonClient()
        fake.attachResponse = { udid, _ in
            PaneCreateResponse(paneId: "pane-\(udid)", scale: nil, family: "phone")
        }
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()
        // First recovery, onto a helper that is already gone again.
        fake.attachError = FakeDaemonError.attachFailed
        router.dispatch(.recoverPanes)
        await settle()
        #expect(simPanes(workspace).isEmpty)
        guard case .failed = pendingPanes(workspace).first?.phase else {
            Issue.record("expected the interrupted recovery to fail the placeholder")
            return
        }
        // The next reconnect reaches a healthy helper.
        fake.attachError = nil
        router.dispatch(.recoverPanes)
        await settle()
        #expect(pendingPanes(workspace).isEmpty)
        #expect(simPanes(workspace).map(\.udid) == ["U"])
    }

    @Test
    func aSecondRecoveryRenumbersAroundAPlaceholderTheFirstLeftFailed() async {
        // The mixed state: one pane recovered, one didn't. The typed array has
        // compacted around the survivor, so enumerating it would hand the
        // survivor index 0 while the failed placeholder still carries the 0 it
        // was minted with, and the two would land on top of each other.
        // Keeping the failed placeholder's claimed position and filling what
        // is left from the mounted panes is what keeps them distinct.
        let fake = FakeDaemonClient()
        fake.attachResponse = { udid, _ in
            PaneCreateResponse(paneId: "pane-\(udid)", scale: nil, family: "phone")
        }
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        for udid in ["A", "B"] {
            router.dispatch(
                .attachSimPane(tab: TabID(value: 1), udid: udid, displayName: "iPhone \(udid)")
            )
            await settle()
        }
        #expect(simPanes(workspace).map(\.udid) == ["A", "B"])
        let treeBefore = leaves(workspace)
        // First recovery: A can't come back, B can.
        fake.attachFailure = { udid, _ in
            udid == "A" ? FakeDaemonError.attachFailed : nil
        }
        router.dispatch(.recoverPanes)
        await settle()
        #expect(simPanes(workspace).map(\.udid) == ["B"])
        #expect(pendingPanes(workspace).count == 1)
        // Second recovery, everything reachable. A is retried and B is
        // re-enumerated. Hold both attaches so the recorded positions can be
        // read while they're still placeholders: those are what the array's
        // order is rebuilt from, and asserting the finished array instead
        // would prove nothing, because the fake completes in spawn order,
        // which is the order that comes out right either way.
        fake.attachFailure = nil
        fake.armAttachBarrier()
        router.dispatch(.recoverPanes)
        await settle()
        let recorded = pendingPanes(workspace).reduce(into: [String: Int?]()) { acc, pending in
            if case let .sim(udid) = pending.target { acc[udid] = pending.atIndex }
        }
        #expect(recorded == ["A": 0, "B": 1])
        fake.releaseAttach()
        await settle()
        #expect(pendingPanes(workspace).isEmpty)
        #expect(simPanes(workspace).map(\.udid) == ["A", "B"])
        // The tree is the other ordering, and it never moved: every
        // placeholder replaced its own leaf in place, twice over.
        #expect(leaves(workspace) == treeBefore)
    }

    @Test
    func recoverPanesRecoversEveryTabsPanes() async {
        // Recovery is per connection, not per tab: a helper restart takes out
        // every pane in the workspace, so anything that walked only the
        // selected tab would leave the rest dead.
        let fake = FakeDaemonClient()
        fake.attachResponse = { udid, _ in
            PaneCreateResponse(paneId: "pane-\(udid)", scale: nil, family: "phone")
        }
        let (router, workspace) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.newTab(WindowID(value: 1)))
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "A", displayName: "iPhone A"))
        router.dispatch(.attachSimPane(tab: TabID(value: 2), udid: "B", displayName: "iPhone B"))
        await settle()
        router.dispatch(.recoverPanes)
        await settle()
        #expect(simPanes(workspace, tab: TabID(value: 1)).map(\.udid) == ["A"])
        #expect(simPanes(workspace, tab: TabID(value: 2)).map(\.udid) == ["B"])
        #expect(fake.attachDeviceCalls.map(\.udid) == ["A", "B", "A", "B"])
    }

    // MARK: - Restoring ownership of sims no pane carries

    /// One owned, booted sim as the app-wide discovery snapshot reports it.
    private func ownedEntry(_ udid: String, session: String?) -> DeviceListEntry {
        DeviceListEntry(udid: udid, name: "iPhone", state: "Booted", ownedBySession: session)
    }

    /// One discovery snapshot: claim the ordering token first, as the coordinator does,
    /// then hand the answer back under it.
    private func pollOwned(
        _ router: Router,
        _ entries: [DeviceListEntry],
        generation: Int
    ) {
        guard let token = router.beginOwnedSimsRead() else {
            Issue.record("the roster read slot should be free between polls")
            return
        }
        router.noteOwnedSims(entries, generation: generation, read: token)
        router.endOwnedSimsRead(token)
    }

    @Test
    func recoveryRestoresOwnershipOfASimNoPaneCarries() async {
        // The sim the user detached: still running, still ours, and with no
        // pane to bring it back through a re-attach. A replacement helper
        // would otherwise treat it as somebody else's and drop it from the
        // running-sim count and the shut-down prompts.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        pollOwned(router, [ownedEntry("U", session: "S")], generation: 0)

        router.noteConnectionReplaced(generation: 1)
        router.dispatch(.recoverPanes)
        await settle()

        #expect(
            fake.restoreOwnershipCalls == [
                [RestoredSimOwnership(udid: "u", sessionId: "S")]
            ]
        )
    }

    @Test
    func recoveryRestoresOwnershipOfMountedAndDetachedSimsAlike() async {
        // The mirror doesn't distinguish them, and shouldn't: re-asserting a
        // sim whose pane is also being re-attached is an idempotent no-op the
        // helper reports as restored, and leaving it out would depend on the
        // pane recovery having already landed.
        let fake = FakeDaemonClient()
        let (router, _) = await makeRecoveryFixture(fake)
        pollOwned(
            router,
            [ownedEntry("U", session: "S"), ownedEntry("detached", session: "S")],
            generation: 0
        )

        router.noteConnectionReplaced(generation: 1)
        router.dispatch(.recoverPanes)
        await settle()

        #expect(fake.restoreOwnershipCalls.first?.map(\.udid) == ["detached", "u"])
    }

    @Test
    func anUnlinkedSimIsRestoredUnattributed() async {
        // The already-demoted form of an Unlinked sim: the helper reports it
        // in the owned roster with no session, and the status item lists it
        // that way. It has to survive a restart the way a pane-detached sim
        // does. (A closed session's UUID can also linger in the map and only
        // resolve as Unlinked; nil is what an explicit demotion leaves.)
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        pollOwned(router, [ownedEntry("U", session: nil)], generation: 0)

        router.noteConnectionReplaced(generation: 1)
        router.dispatch(.recoverPanes)
        await settle()

        #expect(
            fake.restoreOwnershipCalls == [
                [RestoredSimOwnership(udid: "u", sessionId: nil)]
            ]
        )
    }

    @Test
    func shuttingASimDownWithItsPaneDropsItsClaim() async {
        // Production retires a pane-backed sim through the pane close, which
        // stops it and disowns it daemon-side before anything reads the owned
        // roster again. A mirror still holding the claim is one recovery would
        // re-assert against a sim something else may have booted since.
        let fake = FakeDaemonClient()
        let (router, _) = await makeRecoveryFixture(fake)
        fake.deviceListResult = [ownedEntry("U", session: "S")]

        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .shutdown))
        await settle()
        router.noteConnectionReplaced(generation: 1)
        router.dispatch(.recoverPanes)
        await settle()

        #expect(fake.closePaneCalls.map(\.mode) == [.shutdown])
        // The pane close already took it out of the owned roster, so the sweep
        // that follows finds nothing. That ordering is why the claim has to be
        // dropped here rather than off the sweep.
        #expect(fake.shutdownDeviceCalls.isEmpty)
        #expect(fake.restoreOwnershipCalls.isEmpty)
    }

    @Test
    func shuttingDownADetachedSimDropsItsClaim() async {
        // The sweep's own case: a sim this tab's session owns with no pane
        // carrying it, so no pane close retires it.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        pollOwned(router, [ownedEntry("detached", session: "S")], generation: 0)
        fake.deviceListResult = [ownedEntry("detached", session: "S")]

        router.dispatch(.closeTab(WindowID(value: 1), TabID(value: 1), mode: .shutdown))
        await settle()
        router.noteConnectionReplaced(generation: 1)
        router.dispatch(.recoverPanes)
        await settle()

        #expect(fake.shutdownDeviceCalls == ["detached"])
        #expect(fake.restoreOwnershipCalls.isEmpty)
    }

    @Test
    func aRestoreStopsRetryingWhenItsWindowCloses() async {
        // Silence is the only thing worth repeating, and even that is bounded:
        // a helper that starts answering long after the restart would be
        // answering about whatever holds those udids by then.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.restoreRetryBaseNanos = 1_000_000
        router.restoreWindow = .milliseconds(20)
        fake.restoreOwnershipError = FakeDaemonError.attachFailed
        router.dispatch(.openWindow())
        await settle()
        pollOwned(router, [ownedEntry("U", session: "S")], generation: 0)

        router.noteConnectionReplaced(generation: 1)
        router.dispatch(.recoverPanes)
        await settle()
        let attempts = fake.restoreOwnershipCalls.count
        #expect(attempts > 1)

        await settle()
        #expect(fake.restoreOwnershipCalls.count == attempts)
    }

    @Test
    func aClaimSurvivesAHelperReplacedDuringTheAttach() async {
        // The attach recorded ownership on the helper that answered it.
        // Naming the current connection afterward would credit a replacement
        // installed in between, and the mirror would go on to believe that
        // helper's empty roster and drop the claim before recovery could
        // re-assert it.
        let fake = FakeDaemonClient()
        fake.armAttachBarrier()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(.attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone"))
        await settle()

        fake.simulateReconnect()
        fake.releaseAttach()
        await settle()
        // The replacement answers the next poll with nothing owned.
        pollOwned(router, [], generation: 1)

        router.noteConnectionReplaced(generation: 1)
        router.dispatch(.recoverPanes)
        await settle()

        #expect(fake.restoreOwnershipCalls.first?.map(\.udid) == ["u"])
    }

    @Test
    func aSimAttachedAndDetachedBetweenPollsIsStillRestored() async {
        // The window a two-second poll can't cover. The attach records
        // ownership daemon-side, the detach takes the pane away, and if the
        // mirror only ever learned from polls there would be nothing left
        // anywhere that remembers the sim is DeviceTerm's.
        let fake = FakeDaemonClient()
        let (router, workspace) = await makeRecoveryFixture(fake)
        router.dispatch(.detachSimPane(tab: TabID(value: 1), udid: "U", mode: .detach))
        await settle()
        #expect(simPanes(workspace).isEmpty)

        router.noteConnectionReplaced(generation: 1)
        router.dispatch(.recoverPanes)
        await settle()

        #expect(fake.restoreOwnershipCalls.first?.map(\.udid) == ["u"])
    }

    @Test
    func aHelperThatWasNeverReplacedIsToldNothing() async {
        // Recovery dispatched with no connection-replacement notification
        // behind it: nothing has told the mirror to hold its claims, so there
        // is no window open and nothing to re-assert. Production notifies on
        // every reconnect, so this is the shape of a recovery run for some
        // other reason rather than of an ordinary reconnect.
        let fake = FakeDaemonClient()
        let (router, _) = await makeRecoveryFixture(fake)
        pollOwned(router, [ownedEntry("U", session: "S")], generation: 0)

        router.dispatch(.recoverPanes)
        await settle()

        #expect(fake.restoreOwnershipCalls.isEmpty)
        // Recovery ran; it just had nothing to re-assert. Without this the
        // test would also pass if the whole route did nothing.
        #expect(fake.attachDeviceCalls.count == 2)
    }

    @Test
    func aReplacementHelpersEmptyRosterDoesNotEraseWhatItIsOwed() async {
        // The poll runs every couple of seconds and the new helper answers it
        // correctly with "nothing is owned". Believing that before recovery
        // has run would erase the only claim recovery has for the detached
        // sim.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.dispatch(.openWindow())
        await settle()
        pollOwned(router, [ownedEntry("U", session: "S")], generation: 0)
        router.noteConnectionReplaced(generation: 1)

        pollOwned(router, [], generation: 1)
        router.dispatch(.recoverPanes)
        await settle()

        #expect(fake.restoreOwnershipCalls.first?.map(\.udid) == ["u"])
    }

    @Test
    func aRestoreThatKeepsFailingStaysOwedRatherThanDiscardingTheClaims() async {
        // Settling on a failure hands the mirror to a helper that was never
        // told what it owns, and the empty poll behind that discards the claims
        // for good. Staying owed while the recovery window is open is what lets
        // a helper that resumes answering inside it still be told.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.restoreRetryBaseNanos = 1_000_000
        router.dispatch(.openWindow())
        await settle()
        pollOwned(router, [ownedEntry("U", session: "S")], generation: 0)
        router.noteConnectionReplaced(generation: 1)
        fake.restoreOwnershipError = FakeDaemonError.attachFailed
        router.dispatch(.recoverPanes)
        await settle()

        // Still owed while the window is open, and the claim is intact, so a
        // helper that resumes answering inside it still gets told.
        #expect(fake.restoreOwnershipCalls.count > 1)
        fake.restoreOwnershipError = nil
        await settle()
        #expect(fake.restoreOwnershipCalls.last?.map(\.udid) == ["u"])
        await router.shutdown()
    }

    @Test
    func aCliShutdownOfOneSimDropsItsClaim() async {
        // `deviceterm pane close --mode shutdown` and the in-pane action reach
        // detachPane, which shuts the sim down without going near the tab-close
        // fan-out. Same stale-claim exposure, so it drops the claim too.
        let fake = FakeDaemonClient()
        let (router, _) = await makeRecoveryFixture(fake)

        router.dispatch(.detachSimPane(tab: TabID(value: 1), udid: "U", mode: .shutdown))
        await settle()
        router.noteConnectionReplaced(generation: 1)
        router.dispatch(.recoverPanes)
        await settle()

        #expect(fake.closePaneCalls.map(\.mode) == [.shutdown])
        #expect(fake.restoreOwnershipCalls.isEmpty)
    }

    @Test
    func aClaimTheHelperDeclinesIsNotRetried() async {
        // The helper reports no reason, so "declined" covers a sim that shut
        // down as well as one still Booting. Re-asking puts the same claim to
        // whatever holds that udid later, which is how another tool's boot gets
        // claimed as DeviceTerm's. Losing the claim is the lesser failure.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.restoreRetryBaseNanos = 1_000_000
        fake.restoreOwnershipUnresolved = .max
        router.dispatch(.openWindow())
        await settle()
        pollOwned(router, [ownedEntry("U", session: "S")], generation: 0)

        router.noteConnectionReplaced(generation: 1)
        router.dispatch(.recoverPanes)
        await settle()

        #expect(fake.restoreOwnershipCalls.map { $0.map(\.udid) } == [["u"]])
    }

    @Test
    func aRestoreThatFailsOnceIsRetriedRatherThanSettled() async {
        // Settling on a failed call starts the mirror believing a helper that
        // was never told anything, and the next empty poll then discards the
        // claims for good.
        let fake = FakeDaemonClient()
        let (router, _) = makeRouter(fake)
        router.restoreRetryBaseNanos = 1_000_000
        fake.restoreOwnershipFailures = [FakeDaemonError.attachFailed]
        router.dispatch(.openWindow())
        await settle()
        pollOwned(router, [ownedEntry("U", session: "S")], generation: 0)

        router.noteConnectionReplaced(generation: 1)
        router.dispatch(.recoverPanes)
        await settle()

        #expect(fake.restoreOwnershipCalls.map { $0.map(\.udid) } == [["u"], ["u"]])
    }
}
