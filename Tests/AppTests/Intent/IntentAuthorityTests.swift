// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

@MainActor
struct IntentAuthorityTests {
    private struct Harness {
        let dispatcher: IntentDispatcher
        let workspace: WorkspaceViewModel
        let fake: FakeDaemonClient
        let delegate: RecordingAuthorityDelegate
    }

    private func makeHarness(foreignProtected: Bool = false) -> Harness {
        let workspace = WorkspaceViewModel()
        let fake = FakeDaemonClient()
        let router = Router(workspace: workspace, daemon: fake)
        let delegate = RecordingAuthorityDelegate()
        let dispatcher = IntentDispatcher(
            workspace: workspace,
            router: router,
            actionDelegate: delegate
        )

        let ownTabs = TabListViewModel()
        ownTabs.append(
            TabState(
                id: TabID(value: 1),
                terminals: [terminal(1, "S-A")],
                simPanes: [],
                name: "own"
            )
        )
        ownTabs.append(
            TabState(
                id: TabID(value: 3),
                terminals: [terminal(3, "S-A"), terminal(30, "S-C")],
                simPanes: [
                    SimPaneState(
                        paneId: "P-shared-sim",
                        udid: "U-shared-sim",
                        displayName: "iPhone",
                        family: "iPhone"
                    )
                ],
                devicePanes: [
                    DevicePaneState(
                        paneId: "P-shared-device",
                        deviceId: "U-shared-device",
                        displayName: "iPhone",
                        family: "iPhone"
                    )
                ],
                name: "shared"
            )
        )
        workspace.addWindow(
            WindowState(id: WindowID(value: 1), tabs: ownTabs, name: "own-window")
        )

        let foreignTabs = TabListViewModel()
        foreignTabs.append(
            TabState(
                id: TabID(value: 2),
                terminals: [terminal(2, "S-B")],
                simPanes: [
                    SimPaneState(
                        paneId: "P-foreign",
                        udid: "U-foreign",
                        displayName: "iPhone",
                        family: "iPhone"
                    )
                ],
                isProtected: foreignProtected,
                name: "foreign"
            )
        )
        workspace.addWindow(
            WindowState(id: WindowID(value: 2), tabs: foreignTabs, name: "foreign-window")
        )
        workspace.select(id: WindowID(value: 1))

        return Harness(
            dispatcher: dispatcher,
            workspace: workspace,
            fake: fake,
            delegate: delegate
        )
    }

    private func terminal(_ id: Int, _ session: String) -> TerminalPaneState {
        TerminalPaneState(
            id: TerminalPaneID(value: id),
            sessionId: session,
            capability: "cap"
        )
    }

    private func origin(_ session: String = "S-A", granted: Bool = false) -> IntentOrigin {
        .external(sessionID: session, hasAutomationGrant: granted)
    }

    private func expectMutation(
        _ result: IntentResult,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .data(.workspaceMutation) = result else {
            Issue.record("expected a workspace mutation; got \(result)", sourceLocation: sourceLocation)
            return
        }
    }

    private func expectAutomationRequired(
        _ result: IntentResult,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case let .error(error) = result else {
            Issue.record("expected an authority refusal; got \(result)", sourceLocation: sourceLocation)
            return
        }
        #expect(error.code == "intent.automationRequired", sourceLocation: sourceLocation)
    }

    @Test
    func tabMutationsUseTabOwnershipAndGrantRules() async {
        var harness = makeHarness()
        expectMutation(
            await harness.dispatcher.dispatch(
                .workspaceTabRename("own", name: "mine"),
                origin: origin()
            )
        )
        #expect(harness.delegate.tabRenames == [TabID(value: 1)])

        harness = makeHarness()
        expectAutomationRequired(
            await harness.dispatcher.dispatch(
                .workspaceTabRename("foreign", name: "theirs"),
                origin: origin()
            )
        )

        harness = makeHarness()
        expectMutation(
            await harness.dispatcher.dispatch(
                .workspaceTabRename("foreign", name: "theirs"),
                origin: origin(granted: true)
            )
        )
    }

    @Test
    func tabAndWindowCloseProtectIndependentSessions() async {
        var harness = makeHarness()
        expectAutomationRequired(
            await harness.dispatcher.dispatch(
                .workspaceTabClose("shared", mode: .detach),
                origin: origin()
            )
        )
        #expect(harness.fake.closeSessionCalls.isEmpty)

        harness = makeHarness()
        expectAutomationRequired(
            await harness.dispatcher.dispatch(
                .workspaceWindowClose("foreign-window", mode: .detach),
                origin: origin()
            )
        )

        harness = makeHarness()
        expectMutation(
            await harness.dispatcher.dispatch(
                .workspaceWindowClose("foreign-window", mode: .detach),
                origin: origin(granted: true)
            )
        )
        #expect(harness.workspace.windows.count == 1)
    }

    @Test("sibling terminal mutations require a grant", arguments: [
        RouteIntent.workspacePaneClose("S-C", mode: nil),
        RouteIntent.workspacePaneRename("S-C", name: "sibling")
    ])
    func siblingTerminalMutationsRequireAGrant(intent: RouteIntent) async {
        let harness = makeHarness()

        let result = await harness.dispatcher.dispatch(intent, origin: origin())

        expectAutomationRequired(result)
        #expect(harness.fake.closeSessionCalls.isEmpty)
        #expect(harness.delegate.paneRenames.isEmpty)
    }

    @Test
    func terminalPaneOwnerOrGrantMayMutateTheTarget() async {
        var harness = makeHarness()
        expectMutation(
            await harness.dispatcher.dispatch(
                .workspacePaneRename("S-C", name: "mine"),
                origin: origin("S-C")
            )
        )
        #expect(harness.delegate.paneRenames == [.terminal(TerminalPaneID(value: 30))])

        harness = makeHarness()
        expectMutation(
            await harness.dispatcher.dispatch(
                .workspacePaneClose("S-C", mode: nil),
                origin: origin(granted: true)
            )
        )
        #expect(harness.fake.closeSessionCalls.map(\.sessionId) == ["S-C"])
    }

    @Test("mirrored panes retain tab ownership", arguments: [
        RouteIntent.workspacePaneRename("P-shared-sim", name: "sim"),
        RouteIntent.workspacePaneRename("P-shared-device", name: "device")
    ])
    func mirroredPanesRetainTabOwnership(intent: RouteIntent) async {
        let harness = makeHarness()

        expectMutation(await harness.dispatcher.dispatch(intent, origin: origin()))

        #expect(harness.delegate.paneRenames.count == 1)
    }

    @Test
    func aGrantWidensAuthorityWithoutWideningVisibility() async {
        let harness = makeHarness(foreignProtected: true)

        let result = await harness.dispatcher.dispatch(
            .workspacePaneClose("P-foreign", mode: nil),
            origin: origin(granted: true)
        )

        guard case let .error(error) = result else {
            Issue.record("a grant reached a foreign protected tab: \(result)")
            return
        }
        #expect(error.code == "intent.notFound")
    }
}

@MainActor
private final class RecordingAuthorityDelegate: IntentActionDelegate {
    private(set) var tabRenames: [TabID] = []
    private(set) var paneRenames: [PaneSlot] = []

    func renameTab(window: WindowID, tab: TabID, to name: String?) {
        tabRenames.append(tab)
    }

    func renamePane(
        window: WindowID,
        tab: TabID,
        slot: PaneSlot,
        daemonPaneId: String?,
        to name: String?
    ) {
        paneRenames.append(slot)
    }

    func sendInput(
        window: WindowID,
        tab: TabID,
        terminal: TerminalPaneID,
        text: String,
        typeDelayMillis: Int?
    ) {}

    func captureTerminal(
        window: WindowID,
        tab: TabID,
        terminal: TerminalPaneID,
        ansi: Bool
    ) -> String { "" }

    func moveTabAcrossWindows(_ tab: TabID, from: WindowID, to destination: WindowID, atIndex: Int) {}
    func raiseWindow(_ window: WindowID) {}
}
