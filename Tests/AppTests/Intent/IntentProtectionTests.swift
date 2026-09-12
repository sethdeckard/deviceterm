// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

@MainActor
struct IntentProtectionTests {
    private struct Harness {
        let dispatcher: IntentDispatcher
        let workspace: WorkspaceViewModel
        let fake: FakeDaemonClient
    }

    private func tab(
        id: Int,
        session: String,
        name: String,
        isProtected: Bool = false,
        panes: [SimPaneState] = [],
        devicePanes: [DevicePaneState] = []
    ) -> TabState {
        TabState(
            id: TabID(value: id),
            terminals: [
                TerminalPaneState(
                    id: TerminalPaneID(value: id),
                    sessionId: session,
                    capability: "cap"
                )
            ],
            simPanes: panes,
            devicePanes: devicePanes,
            isProtected: isProtected,
            name: name
        )
    }

    private func workspace(_ windows: [[TabState]], keyIndex: Int = 0) -> WorkspaceViewModel {
        let workspace = WorkspaceViewModel()
        var ids: [WindowID] = []
        for (index, tabs) in windows.enumerated() {
            let list = TabListViewModel()
            tabs.forEach(list.append)
            let id = WindowID(value: index + 1)
            ids.append(id)
            workspace.addWindow(
                WindowState(id: id, tabs: list, name: "window-\(index + 1)")
            )
        }
        if ids.indices.contains(keyIndex) {
            workspace.select(id: ids[keyIndex])
        }
        return workspace
    }

    private func makeHarness(_ windows: [[TabState]]) -> Harness {
        let workspace = workspace(windows)
        let fake = FakeDaemonClient()
        let dispatcher = IntentDispatcher(
            workspace: workspace,
            router: Router(workspace: workspace, daemon: fake),
            actionDelegate: nil
        )
        return Harness(dispatcher: dispatcher, workspace: workspace, fake: fake)
    }

    @Test
    func protectedTabsAreOpaqueExceptToTheirOwnerAndInProcess() throws {
        let publicTab = tab(id: 1, session: "S-public", name: "public")
        let privateTab = tab(
            id: 2,
            session: "S-private",
            name: "private",
            isProtected: true
        )
        let workspace = workspace([[publicTab, privateTab]])
        let outsider = IntentResolver(
            workspace: workspace,
            origin: .external(sessionID: "S-public", hasAutomationGrant: true)
        )
        let owner = IntentResolver(
            workspace: workspace,
            origin: .external(sessionID: "S-private", hasAutomationGrant: false)
        )
        let inProcess = IntentResolver(workspace: workspace, origin: .inProcess)

        #expect(throws: IntentError.self) { try outsider.resolveTab("private") }
        #expect(try owner.resolveTab("private").tabID == TabID(value: 2))
        #expect(try inProcess.resolveTab("private").tabID == TabID(value: 2))
    }

    @Test
    func protectedMatchesNeverInflateAmbiguity() throws {
        let visible = tab(id: 1, session: "S-visible", name: "shared")
        let hidden = tab(
            id: 2,
            session: "S-hidden",
            name: "shared",
            isProtected: true
        )
        let workspace = workspace([[visible, hidden]])
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .external(sessionID: "S-visible", hasAutomationGrant: false)
        )

        #expect(try resolver.resolveTab("shared").tabID == TabID(value: 1))
    }

    @Test
    func panesAndWindowsInsideProtectedTabsAreOpaque() throws {
        let pane = SimPaneState(
            paneId: "P-private",
            udid: "U-private",
            displayName: "iPhone",
            family: "phone"
        )
        let publicTab = tab(id: 1, session: "S-public", name: "public")
        let privateTab = tab(
            id: 2,
            session: "S-private",
            name: "private",
            isProtected: true,
            panes: [pane]
        )
        let workspace = workspace([[publicTab], [privateTab]])
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .external(sessionID: "S-public", hasAutomationGrant: true)
        )

        #expect(throws: IntentError.self) { try resolver.resolveWorkspacePane("P-private") }
        #expect(throws: IntentError.self) { try resolver.resolveWindow("window-2") }
        #expect(resolver.visibleWindowStates().map(\.id) == [WindowID(value: 1)])
    }

    @Test
    func workspaceWindowListOmitsProtectedOnlyWindows() async {
        let publicTab = tab(id: 1, session: "S-public", name: "public")
        let privateTab = tab(
            id: 2,
            session: "S-private",
            name: "private",
            isProtected: true
        )
        let harness = makeHarness([[publicTab], [privateTab]])

        let result = await harness.dispatcher.dispatch(
            .workspaceWindowList(all: true),
            origin: .external(sessionID: "S-public", hasAutomationGrant: true)
        )

        guard case let .data(.workspaceWindows(windows)) = result else {
            Issue.record("expected workspace window list; got \(result)")
            return
        }
        #expect(windows.count == 1)
        #expect(windows[0].name == "window-1")
    }

    @Test
    func ownerCanUnprotectButGrantCannotReachForeignProtectedTab() async {
        var harness = makeHarness([
            [
                tab(id: 1, session: "S-private", name: "private", isProtected: true)
            ]
        ])
        let ownerResult = await harness.dispatcher.dispatch(
            .workspaceTabProtect("private", protected: false),
            origin: .external(sessionID: "S-private", hasAutomationGrant: false)
        )
        guard case .data(.workspaceMutation) = ownerResult else {
            Issue.record("owner could not unprotect its tab: \(ownerResult)")
            return
        }
        #expect(harness.fake.setProtectedBatchCalls.count == 1)

        harness = makeHarness([
            [
                tab(id: 1, session: "S-public", name: "public"),
                tab(id: 2, session: "S-private", name: "private", isProtected: true)
            ]
        ])
        let grantedResult = await harness.dispatcher.dispatch(
            .workspaceTabProtect("private", protected: false),
            origin: .external(sessionID: "S-public", hasAutomationGrant: true)
        )
        guard case let .error(error) = grantedResult else {
            Issue.record("grant reached a foreign protected tab: \(grantedResult)")
            return
        }
        #expect(error.code == "intent.notFound")
    }

    @Test
    func attachScansDoNotLeakProtectedPaneIdentity() async {
        let udid = "7db632b6-86d3-437d-b567-36a80e59788b"
        let hiddenPane = SimPaneState(
            paneId: "P-hidden",
            udid: udid,
            displayName: "iPhone",
            family: "phone"
        )
        let harness = makeHarness([
            [
                tab(id: 1, session: "S-public", name: "public"),
                tab(
                    id: 2,
                    session: "S-private",
                    name: "private",
                    isProtected: true,
                    panes: [hiddenPane]
                )
            ]
        ])

        let result = await harness.dispatcher.dispatch(
            .paneAttach(udid: udid),
            origin: .external(sessionID: "S-public", hasAutomationGrant: false)
        )

        guard case let .data(.workspaceMutation(receipt)) = result else {
            Issue.record("protected identity blocked attach: \(result)")
            return
        }
        #expect(receipt.pane?.simulator?.udid == udid)
    }
}
