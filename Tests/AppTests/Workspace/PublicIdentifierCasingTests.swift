// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

// Casing of the identifiers a workspace projection publishes, driven from
// daemon responses through the Router rather than from fixtures.
//
// `WorkspaceProjectionContractTests` and `PublicJSONContractTests` build
// their objects from hand-written literals, so they pin encoder key order and
// shape rather than casing. These run a real UUID down the production path.

@MainActor
struct PublicIdentifierCasingTests {
    private struct Harness {
        let dispatcher: IntentDispatcher
        let workspace: WorkspaceViewModel
        let router: Router
    }

    /// Non-canonical spellings, to prove the projection publishes one
    /// alphabet whatever casing reaches it.
    private static let uppercaseSession = "550E8400-E29B-41D4-A716-446655440000"
    private static let uppercasePane = "F3A61C00-3F4B-44F0-8898-18544176A338"

    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    /// One window, its primary terminal, and one attached sim pane, with the
    /// fake answering both creates in the uppercase spelling.
    private func makeHarness() async -> Harness {
        let workspace = WorkspaceViewModel()
        let fake = FakeDaemonClient()
        fake.sessionToReturn = SessionCreateResponse(
            sessionId: Self.uppercaseSession,
            capability: "C",
            shortId: "abc123"
        )
        fake.attachResult = PaneCreateResponse(
            paneId: Self.uppercasePane,
            scale: nil,
            family: "phone",
            shortId: "def456",
            target: .sim(udid: "1d464fbe-56ba-4a49-8d73-277a7e8a0e92")
        )
        let router = Router(workspace: workspace, daemon: fake)
        let dispatcher = IntentDispatcher(
            workspace: workspace,
            router: router,
            actionDelegate: nil
        )
        router.dispatch(.openWindow())
        await settle()
        router.dispatch(
            .attachSimPane(
                tab: TabID(value: 1),
                udid: "1d464fbe-56ba-4a49-8d73-277a7e8a0e92",
                displayName: "iPhone"
            )
        )
        await settle()
        return Harness(dispatcher: dispatcher, workspace: workspace, router: router)
    }

    private func panes(_ harness: Harness) async -> [WorkspacePane] {
        let result = await harness.dispatcher.dispatch(
            .workspacePaneList(tab: nil, all: true),
            origin: .inProcess
        )
        guard case let .data(.workspacePanes(rows)) = result else {
            Issue.record("expected .data(.workspacePanes); got \(result)")
            return []
        }
        return rows
    }

    @Test
    func everyIdentifierOnAPaneRowIsLowercase() async {
        // Every UUID field on one row shares an alphabet, `id` and
        // `terminal.sessionId` included, whatever casing the daemon response
        // that produced them used.
        for pane in await panes(await makeHarness()) {
            for (field, value) in [
                ("id", pane.id),
                ("tabId", pane.tabId),
                ("windowId", pane.windowId)
            ] {
                #expect(value == value.lowercased(), "\(pane.kind) \(field) is not lowercase: \(value)")
            }
            if let sessionId = pane.terminal?.sessionId {
                #expect(sessionId == sessionId.lowercased())
            }
        }
    }

    @Test
    func aTerminalRowPublishesTheSessionIdAsItsOwnId() async {
        // A consumer compares `pane.id` against `$DEVICETERM_SESSION`. Both
        // read `TerminalPaneState.sessionId` (the env through
        // `SessionEnvironment`, the row through the projection), so the
        // self-compare holds only while the two stay one string.
        let rows = await panes(await makeHarness())
        let terminals = rows.filter { $0.kind == .terminal }
        #expect(!terminals.isEmpty)
        for terminal in terminals {
            #expect(terminal.id == terminal.terminal?.sessionId)
            #expect(terminal.id == Self.uppercaseSession.lowercased())
        }
    }

    @Test
    func aSimPaneRowPublishesTheLowercasedDaemonPaneId() async {
        let rows = await panes(await makeHarness())
        let sims = rows.filter { $0.kind == .simulator }
        #expect(sims.map(\.id) == [Self.uppercasePane.lowercased()])
    }

    /// The GUI stores canonical ids for the pane it mounted. The surface
    /// side-band join compares that stored pane id as a string, so what is
    /// stored, not just what is projected, has to be canonical.
    @Test
    func theStoredPaneStateHoldsTheCanonicalSpelling() async {
        let harness = await makeHarness()
        let tab = harness.workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))
        #expect(tab?.simPanes.map(\.paneId) == [Self.uppercasePane.lowercased()])
        #expect(tab?.terminals.map(\.sessionId) == [Self.uppercaseSession.lowercased()])
    }
}
