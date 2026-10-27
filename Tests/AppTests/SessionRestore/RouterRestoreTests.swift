// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

private enum FakeRestoreError: Error { case refused }

private let udid = "6f9619ff-8b86-d011-b42d-00c04fc964ff"

private let notBootedRefusal = DaemonClientError.daemon(
    code: DaemonErrorCode.deviceNotBooted,
    message: "iPhone 17 Pro is shut down"
)

private func term(_ cwd: String? = nil, name: String? = nil) -> WorkspaceSnapshot.Node {
    .terminal(.init(cwd: cwd, name: name))
}

private func simLeaf(name: String? = nil) -> WorkspaceSnapshot.Node {
    .sim(.init(id: udid, displayName: "iPhone 17 Pro", name: name, family: "iphone", sizePreset: "pixelAccurate"))
}

private func snapshot(
    _ tabs: [WorkspaceSnapshot.Tab],
    selectedTab: Int? = nil,
    frame: WorkspaceSnapshot.Frame? = nil
) -> WorkspaceSnapshot {
    WorkspaceSnapshot(windows: [.init(frame: frame, tabs: tabs, selectedTab: selectedTab)], selectedWindow: 0)
}

/// The Router rebuilding a saved layout against a fake daemon.
@MainActor
struct RouterRestoreTests {
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func makeRouter(_ fake: FakeDaemonClient) -> (Router, WorkspaceViewModel) {
        let workspace = WorkspaceViewModel()
        let router = Router(workspace: workspace, daemon: fake, detectWorktreeName: { "worktree" })
        return (router, workspace)
    }

    private func tabs(_ workspace: WorkspaceViewModel) -> [TabState] {
        workspace.windows.flatMap(\.tabs.tabs)
    }

    @Test
    func rebuildsTheTreeWithFreshSessionsAndPlaceholders() async throws {
        let fake = FakeDaemonClient()
        fake.sessionSequence = [
            SessionCreateResponse(sessionId: "S1", capability: "C1"),
            SessionCreateResponse(sessionId: "S2", capability: "C2")
        ]
        // Refuse the attach so the placeholder remains available for the assertions.
        fake.attachFailure = { _, _ in notBootedRefusal }
        let (router, workspace) = makeRouter(fake)
        let saved = WorkspaceSnapshot.Tab(
            title: "Checkout",
            isPinned: true,
            layout: .split(
                axis: .horizontal,
                children: [
                    term("/"),
                    .split(axis: .vertical, children: [simLeaf(), term(name: "logs")], ratios: [3, 1])
                ],
                ratios: nil
            ),
            focusedLeaf: 2
        )
        await router.dispatchAndWait(
            .restoreWorkspace(snapshot([saved], frame: .init(x: 1, y: 2, width: 900, height: 700)))
        )
        #expect(workspace.windows.count == 1)
        #expect(workspace.windows[0].restoredFrame == CGRect(x: 1, y: 2, width: 900, height: 700))
        let tab = try #require(tabs(workspace).first)
        #expect(tab.isPinned)
        #expect(tab.name == "Checkout")
        #expect(tab.role == .agent)
        #expect(tab.terminals.map(\.sessionId) == ["S1", "S2"])
        #expect(tab.terminals.map(\.cwd) == ["/", NSHomeDirectory()])
        // Every session is new and joins the tab's cohort; the first, unnamed,
        // takes the worktree name as a new tab's would.
        #expect(fake.createSessionCalls.map(\.name) == ["worktree", "logs"])
        #expect(fake.createSessionCalls.allSatisfy { $0.tabId == tab.cohortId && $0.role == .agent })
        let pending = try #require(tab.pendingPanes.first)
        #expect(pending.target == .sim(udid: udid))
        #expect(pending.sizePreset == .pixelAccurate)
        #expect(
            tab.paneTree == .split(
                axis: .horizontal,
                children: [
                    .leaf(.terminal(tab.terminals[0].id)),
                    .split(
                        axis: .vertical,
                        children: [.leaf(.pending(pending.id)), .leaf(.terminal(tab.terminals[1].id))],
                        extents: [0.75, 0.25]
                    )
                ],
                extents: [0.5, 0.5]
            )
        )
        #expect(tab.lastFocusedPane == .terminal(tab.terminals[1].id))
        #expect(tab.lastFocusedTerminal == tab.terminals[1].id)
        #expect(
            tab.restoredPresentation == RestoredTabPresentation(
                manualTitle: "Checkout",
                ratios: [[1]: [0.75, 0.25]],
                simFitPaths: [.sim(udid: udid): [1, 0]]
            )
        )
    }

    @Test
    func aRestoredSimPaneBorrowsItsSimulator() async throws {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "iphone", target: .sim(udid: udid))
        let (router, workspace) = makeRouter(fake)
        let saved = WorkspaceSnapshot.Tab(
            title: nil,
            isPinned: false,
            layout: .split(axis: .horizontal, children: [term(), simLeaf(name: "checkout")], ratios: nil)
        )
        await router.dispatchAndWait(.restoreWorkspace(snapshot([saved])))
        await settle()
        #expect(fake.attachDeviceCalls.isEmpty)
        #expect(fake.createSimPaneCalls.map(\.udid) == [udid])
        // `pane.create` stamps no name, so the carried one is set after.
        #expect(fake.setPaneNameCalls == [.init(paneId: "P1", name: "checkout")])
        let tab = try #require(tabs(workspace).first)
        #expect(tab.simPanes.map(\.udid) == [udid])
        #expect(tab.simPanes.first?.name == "checkout")
        #expect(tab.simPanes.first?.sizePreset == .pixelAccurate)
        #expect(tab.pendingPanes.isEmpty)
    }

    @Test
    func aSimTheUserReattachedIsClaimedAndNotOpenedTwice() async throws {
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(paneId: "P1", scale: nil, family: "iphone", target: .sim(udid: udid))
        let (router, workspace) = makeRouter(fake)
        let orphan = OrphanRecord(
            sessionId: "OLD",
            sessionDir: NSTemporaryDirectory() + "deviceterm-restore-orphan-\(UUID().uuidString)",
            liveSims: [OrphanLiveSim(udid: udid.uppercased(), displayName: "iPhone 17 Pro")]
        )
        let saved = WorkspaceSnapshot.Tab(
            title: nil,
            isPinned: false,
            layout: .split(axis: .horizontal, children: [term(), simLeaf()], ratios: nil)
        )
        await router.dispatchAndWait(.restoreWorkspace(snapshot([saved]), reattach: [orphan]))
        await settle()
        #expect(fake.createSimPaneCalls.isEmpty)
        #expect(fake.attachDeviceCalls.map(\.udid) == [udid])
        #expect(try #require(tabs(workspace).first).simPanes.count == 1)
    }

    @Test
    func aShutDownSimComesBackOfferingBootInItsSlot() async throws {
        let fake = FakeDaemonClient()
        fake.attachFailure = { _, _ in notBootedRefusal }
        let (router, workspace) = makeRouter(fake)
        let saved = WorkspaceSnapshot.Tab(
            title: nil,
            isPinned: false,
            layout: .split(axis: .horizontal, children: [term(), simLeaf()], ratios: nil)
        )
        await router.dispatchAndWait(.restoreWorkspace(snapshot([saved])))
        await settle()
        let tab = try #require(tabs(workspace).first)
        let pending = try #require(tab.pendingPanes.first)
        #expect(pending.phase == .notBooted("iPhone 17 Pro is shut down"))
        #expect(PaneTreeOps.leavesInOrder(tab.paneTree).last == .pending(pending.id))
        #expect(fake.bootDeviceCalls.isEmpty)
    }

    @Test
    func aTerminalWhoseSessionFailsLeavesTheLayout() async throws {
        let fake = FakeDaemonClient()
        fake.createSessionFailures = [nil, FakeRestoreError.refused, nil]
        let (router, workspace) = makeRouter(fake)
        let saved = WorkspaceSnapshot.Tab(
            title: nil,
            isPinned: false,
            layout: .split(axis: .horizontal, children: [term("/"), term("/tmp"), term()], ratios: [1, 1, 1]),
            focusedLeaf: 2
        )
        await router.dispatchAndWait(.restoreWorkspace(snapshot([saved])))
        let tab = try #require(tabs(workspace).first)
        #expect(tab.lifecycle == .ready)
        #expect(tab.terminals.count == 2)
        #expect(tab.terminals.map(\.cwd) == ["/", NSHomeDirectory()])
        // The survivors keep their order, the split loses its proportions,
        // and focus follows the leaf it named.
        #expect(tab.paneTree == .split(
            axis: .horizontal,
            children: [.leaf(.terminal(tab.terminals[0].id)), .leaf(.terminal(tab.terminals[1].id))],
            extents: [0.5, 0.5]
        ))
        #expect(tab.restoredPresentation?.ratios.isEmpty == true)
        #expect(tab.lastFocusedPane == .terminal(tab.terminals[1].id))
    }

    @Test
    func aFirstTerminalWhoseSessionFailsFailsTheTab() async throws {
        let fake = FakeDaemonClient()
        fake.createSessionError = FakeRestoreError.refused
        let (router, workspace) = makeRouter(fake)
        let saved = WorkspaceSnapshot.Tab(title: "Build", isPinned: true, layout: term("/"))
        await router.dispatchAndWait(.restoreWorkspace(snapshot([saved])))
        let tab = try #require(tabs(workspace).first)
        #expect(tab.lifecycle == .failed)
        #expect(tab.isPinned)
        #expect(tab.name == "Build")
    }

    @Test
    func restoresTabOrderSelectionAndWindows() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        let first = WorkspaceSnapshot.Window(
            frame: nil,
            tabs: [
                .init(title: "a", isPinned: false, layout: term()),
                .init(title: "b", isPinned: false, layout: term())
            ],
            selectedTab: 0
        )
        let second = WorkspaceSnapshot.Window(
            frame: nil,
            tabs: [.init(title: "c", isPinned: false, layout: term())],
            selectedTab: 0
        )
        await router.dispatchAndWait(
            .restoreWorkspace(WorkspaceSnapshot(windows: [first, second], selectedWindow: 0))
        )
        #expect(workspace.windows.map { $0.tabs.tabs.map(\.name) } == [["a", "b"], ["c"]])
        #expect(workspace.windows[0].tabs.selectedTab?.name == "a")
        #expect(workspace.selectedWindowID == workspace.windows[0].id)
        // Recorded for the launch, which puts it back in front once AppKit has
        // made each window key in turn.
        #expect(router.restoredFrontWindow == workspace.windows[0].id)
    }

    @Test
    func theSavedWindowIsTheOneInFrontEvenWhenItIsNotTheLast() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        let window = WorkspaceSnapshot.Window(
            frame: nil,
            tabs: [.init(title: nil, isPinned: false, layout: term())],
            selectedTab: 0
        )
        await router.dispatchAndWait(
            .restoreWorkspace(WorkspaceSnapshot(windows: [window, window, window], selectedWindow: 1))
        )
        #expect(workspace.windows.count == 3)
        #expect(router.restoredFrontWindow == workspace.windows[1].id)
        #expect(workspace.selectedWindowID == workspace.windows[1].id)
    }

    @Test
    func aLayoutWithNothingToRestoreOpensOneNewWindow() async {
        let fake = FakeDaemonClient()
        let (router, workspace) = makeRouter(fake)
        let saved = WorkspaceSnapshot.Tab(title: nil, isPinned: false, layout: simLeaf())
        await router.dispatchAndWait(.restoreWorkspace(snapshot([saved])))
        #expect(workspace.windows.count == 1)
        #expect(tabs(workspace).count == 1)
        #expect(tabs(workspace).first?.restoredPresentation == nil)
        await router.dispatchAndWait(.restoreWorkspace(WorkspaceSnapshot(windows: [], selectedWindow: nil)))
        #expect(workspace.windows.count == 2)
    }
}
