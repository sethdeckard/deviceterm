// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// The cross-tab verbs, gated.
///
/// Every verb that can reach outside the caller's own tab gets both of
/// its cases here, allowed and refused, because a row with only one of
/// the two proves nothing about the gate. The refusal is deliberately
/// `automationRequired` rather than `notFound`: resolution runs first, so
/// anything reaching the gate is a tab the caller can already see in
/// `tabs list` and naming the reason leaks nothing.
///
/// Protection is the other axis and is not this suite's subject, except
/// for the one case where they meet: a grant must widen authority without
/// widening visibility.
@MainActor
struct IntentAuthorityTests {
    private struct Harness {
        let dispatcher: IntentDispatcher
        let workspace: WorkspaceViewModel
        let fake: FakeDaemonClient
        let actionDelegate: RecordingAuthorityDelegate
    }

    // MARK: - Fixtures

    /// Window 1 holds the caller's own tab (`S-A`) and a split tab
    /// (`S-A` + `S-C`). Window 2 holds a foreign tab (`S-B`) with a sim
    /// pane, so the pane verbs have a cross-tab target.
    private func makeHarness(foreignTabProtected: Bool = false) -> Harness {
        let workspace = WorkspaceViewModel()
        let fake = FakeDaemonClient()
        let router = Router(workspace: workspace, daemon: fake)
        let delegate = RecordingAuthorityDelegate()
        let dispatcher = IntentDispatcher(
            workspace: workspace,
            router: router,
            actionDelegate: delegate
        )

        let ownWindow = TabListViewModel()
        ownWindow.append(
            TabState(
                id: TabID(value: 1),
                terminals: [terminal(1, "S-A")],
                simPanes: []
            )
        )
        ownWindow.append(
            TabState(
                id: TabID(value: 3),
                terminals: [terminal(3, "S-A"), terminal(30, "S-C")],
                simPanes: []
            )
        )
        workspace.addWindow(WindowState(id: WindowID(value: 1), tabs: ownWindow))

        let foreignWindow = TabListViewModel()
        foreignWindow.append(
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
                isProtected: foreignTabProtected
            )
        )
        workspace.addWindow(
            WindowState(id: WindowID(value: 2), tabs: foreignWindow)
        )

        return Harness(
            dispatcher: dispatcher,
            workspace: workspace,
            fake: fake,
            actionDelegate: delegate
        )
    }

    private func terminal(_ id: Int, _ session: String) -> TerminalPaneState {
        TerminalPaneState(
            id: TerminalPaneID(value: id),
            sessionId: session,
            capability: "cap"
        )
    }

    private func ungranted(_ session: String? = "S-A") -> IntentOrigin {
        .external(sessionID: session, hasAutomationGrant: false)
    }

    private func granted(_ session: String? = "S-A") -> IntentOrigin {
        .external(sessionID: session, hasAutomationGrant: true)
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    /// Assert the dispatch was refused for want of a grant, and say so
    /// with the actual result when it wasn't.
    private func expectAutomationRequired(
        _ result: IntentResult,
        _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case let .error(error) = result else {
            Issue.record("\(comment): expected a refusal; got \(result)", sourceLocation: sourceLocation)
            return
        }
        #expect(
            error.code == "intent.automationRequired",
            comment,
            sourceLocation: sourceLocation
        )
    }

    // MARK: - Close a tab

    @Test
    func closingYourOwnSoleTerminalTabNeedsNoGrant() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closeTab(.sessionId("S-A"), mode: .detach), origin: ungranted()
        )
        await settle()
        #expect(result == .ok)
    }

    @Test
    func closingAForeignTabIsRefusedWithoutAGrant() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closeTab(.sessionId("S-B"), mode: .detach), origin: ungranted()
        )
        await settle()
        expectAutomationRequired(result, "tab close reached another session's tab")
        #expect(harness.fake.closeSessionCalls.isEmpty)
    }

    @Test
    func closingASplitTabYouShareIsRefusedWithoutAGrant() async {
        // `S-A` owns a terminal in tab 3, but so does `S-C`. Closing it
        // would end `S-C`'s work without its consent.
        let harness = makeHarness()
        // Naming `S-C` resolves the split tab, which `S-A` also holds a
        // terminal in, so this is the owns-it-but-shares-it case.
        let result = await harness.dispatcher.dispatch(
            .closeTab(.sessionId("S-C"), mode: .detach), origin: ungranted()
        )
        await settle()
        expectAutomationRequired(result, "tab close destroyed a sibling session's work")
        #expect(harness.fake.closeSessionCalls.isEmpty)
    }

    @Test
    func aGrantClosesAForeignTab() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closeTab(.sessionId("S-B"), mode: .detach), origin: granted()
        )
        await settle()
        #expect(result == .ok)
    }

    // MARK: - Close a window

    @Test
    func closingAWindowOfForeignTabsIsRefusedWithoutAGrant() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closeWindow(.index(2), mode: .detach), origin: ungranted()
        )
        await settle()
        expectAutomationRequired(result, "window close tore down another session's tab")
        #expect(harness.workspace.windows.count == 2)
    }

    @Test
    func aGrantClosesAWindowOfForeignTabs() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closeWindow(.index(2), mode: .detach), origin: granted()
        )
        await settle()
        #expect(result == .ok)
    }

    @Test
    func closingYourOwnWindowIsRefusedWhileItHoldsASplitTab() async {
        // Window 1 holds the caller's own sole-terminal tab *and* the
        // split tab. A window close takes both, so the split tab's rule
        // decides the whole window.
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closeWindow(.index(1), mode: .detach), origin: ungranted()
        )
        await settle()
        expectAutomationRequired(result, "window close took a shared tab with it")
        #expect(harness.workspace.windows.count == 2)
    }

    // MARK: - The authorized membership has to survive the queue

    @Test
    func aTerminalArrivingAfterAuthorizationAbandonsTheClose() async {
        // Authorization runs on the main actor when the verb arrives;
        // the close runs later on the Router's drain. Between the two,
        // an `openTerminalPane` suspended in `createSession` appends its
        // terminal, so a caller cleared to close its own sole-terminal
        // tab would otherwise destroy a session that arrived after it
        // was cleared and that nobody authorized touching.
        let harness = makeHarness()
        let tabID = TabID(value: 1)
        let result = await harness.dispatcher.dispatch(
            .closeTab(.sessionId("S-A"), mode: .detach), origin: ungranted()
        )
        #expect(result == .ok)
        // Stand in for the racing create landing before the drain picks
        // the close up: the queued route carries the one-terminal
        // membership it was authorized over.
        harness.workspace.window(id: WindowID(value: 1))?.tabs.addTerminal(
            TerminalPaneState(
                id: TerminalPaneID(value: 99),
                sessionId: "S-LATE",
                capability: "cap"
            ),
            toTab: tabID
        )
        await settle()
        #expect(
            harness.workspace.window(id: WindowID(value: 1))?.tabs.tab(id: tabID) != nil,
            "the close ran against membership it was never authorized over"
        )
        #expect(harness.fake.closeSessionCalls.isEmpty)
    }

    @Test
    func anUnchangedTabStillCloses() async {
        // The re-check must not refuse the ordinary case; nothing moved.
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closeTab(.sessionId("S-A"), mode: .detach), origin: ungranted()
        )
        await settle()
        #expect(result == .ok)
        #expect(
            harness.workspace.window(id: WindowID(value: 1))?
                .tabs.tab(id: TabID(value: 1)) == nil
        )
    }

    @Test
    func aGrantedCloseIsNotMembershipFenced() async {
        // A grant doesn't rest on which sessions the tab holds, so its
        // close carries no membership and a late arrival can't strand
        // it. Pins that the fence is scoped to the callers that need it.
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closeTab(.sessionId("S-C"), mode: .detach), origin: granted()
        )
        #expect(result == .ok)
        harness.workspace.window(id: WindowID(value: 1))?.tabs.addTerminal(
            TerminalPaneState(
                id: TerminalPaneID(value: 98),
                sessionId: "S-LATE",
                capability: "cap"
            ),
            toTab: TabID(value: 3)
        )
        await settle()
        #expect(
            harness.workspace.window(id: WindowID(value: 1))?
                .tabs.tab(id: TabID(value: 3)) == nil
        )
    }

    // MARK: - Rename a tab

    @Test
    func renamingYourOwnTabNeedsNoGrant() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .renameTab(.sessionId("S-A"), name: "mine"), origin: ungranted()
        )
        #expect(result == .ok)
        #expect(harness.actionDelegate.renames.count == 1)
    }

    @Test
    func renamingAForeignTabIsRefusedWithoutAGrant() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .renameTab(.sessionId("S-B"), name: "yours"), origin: ungranted()
        )
        expectAutomationRequired(result, "tab rename retitled another session's tab")
        #expect(harness.actionDelegate.renames.isEmpty)
    }

    @Test
    func aGrantRenamesAForeignTab() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .renameTab(.sessionId("S-B"), name: "yours"), origin: granted()
        )
        #expect(result == .ok)
        #expect(harness.actionDelegate.renames.count == 1)
    }

    // MARK: - Open a terminal pane

    @Test
    func openingAPaneInYourOwnTabNeedsNoGrant() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .openPaneTerminal(inTab: .sessionId("S-A"), cwd: nil, cmd: nil),
            origin: ungranted()
        )
        await settle()
        #expect(result == .ok)
    }

    @Test
    func openingAPaneInAForeignTabIsRefusedWithoutAGrant() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .openPaneTerminal(inTab: .sessionId("S-B"), cwd: nil, cmd: nil),
            origin: ungranted()
        )
        await settle()
        expectAutomationRequired(result, "pane open landed in another session's tab")
    }

    @Test
    func omittingTheTabRefStaysInYourOwnTab() async {
        // With `--tab` omitted the resolver returns the caller's own tab,
        // so the ownership predicate passes by construction. Pinned so a
        // future change to `.current` resolution can't quietly turn the
        // default form into a cross-tab write.
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .openPaneTerminal(inTab: nil, cwd: nil, cmd: nil),
            origin: ungranted()
        )
        await settle()
        #expect(result == .ok)
    }

    // MARK: - Close a pane

    @Test
    func closingAPaneInAForeignTabIsRefusedWithoutAGrant() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closePane(.paneId("P-foreign"), mode: .detach), origin: ungranted()
        )
        await settle()
        expectAutomationRequired(result, "pane close reached into another session's tab")
    }

    @Test
    func aGrantClosesAPaneInAForeignTab() async {
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closePane(.paneId("P-foreign"), mode: .detach), origin: granted()
        )
        await settle()
        #expect(result == .ok)
    }

    // MARK: - A grant widens authority, never visibility

    @Test("a grant does not reach a foreign protected tab", arguments: [
        RouteIntent.closeTab(.sessionId("S-B"), mode: .detach),
        RouteIntent.renameTab(.sessionId("S-B"), name: "yours"),
        RouteIntent.openPaneTerminal(inTab: .sessionId("S-B"), cwd: nil, cmd: nil),
        RouteIntent.closePane(.paneId("P-foreign"), mode: .detach),
        RouteIntent.setTabProtected(.sessionId("S-B"), isProtected: false)
    ])
    func aGrantDoesNotWidenVisibility(intent: RouteIntent) async {
        // A grant never reaches a protected tab.
        // The refusal has to stay `notFound` too, not `automationRequired`:
        // resolution runs first, so a granted caller learns nothing about
        // whether that tab exists.
        let harness = makeHarness(foreignTabProtected: true)
        let result = await harness.dispatcher.dispatch(intent, origin: granted())
        await settle()
        guard case let .error(error) = result else {
            Issue.record("a grant reached a protected tab: \(result)")
            return
        }
        #expect(error.code == "intent.notFound")
    }

    // MARK: - The human is never gated

    @Test
    func inProcessClosesASplitTabWithoutAGrant() async {
        // The tab strip's own close button runs `.inProcess`. Gating it
        // would break closing a split tab from the GUI.
        let harness = makeHarness()
        let result = await harness.dispatcher.dispatch(
            .closeTab(.sessionId("S-C"), mode: .detach), origin: .inProcess
        )
        await settle()
        #expect(result == .ok)
    }
}

// MARK: - Helpers

/// Records the delegate calls this suite asserts on. Separate from
/// `IntentDispatcherTests`' recorder because that one is file-private to
/// its own suite.
@MainActor
private final class RecordingAuthorityDelegate: IntentActionDelegate {
    private(set) var renames: [TabID] = []
    private(set) var raises: [WindowID] = []

    func renameTab(window: WindowID, tab: TabID, to name: String?) {
        renames.append(tab)
    }

    func sendInput(
        window: WindowID,
        tab: TabID,
        text: String,
        typeDelayMillis: Int?
    ) {}

    func captureTab(window: WindowID, tab: TabID) -> String { "" }

    func moveTabAcrossWindows(_ tab: TabID, from: WindowID, to destination: WindowID, atIndex: Int) {}

    func raiseWindow(_ window: WindowID) {
        raises.append(window)
    }
}
