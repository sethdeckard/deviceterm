// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// The origin-aware opacity boundary: a foreign
/// protected tab is unreachable and unlistable to an external caller,
/// across every resolver family (tab / pane / window / listing) and the
/// `set-protected` owner gate. In-process callers (the human) see
/// everything.
///
/// A leak in any one path is as bad as a leak in `capture`, so the suite
/// covers a representative path per family, plus the ambiguity and
/// `.current` fail-closed cases that a naive post-filter gets wrong.
@MainActor
struct IntentProtectionTests {
    private struct Harness {
        let dispatcher: IntentDispatcher
        let workspace: WorkspaceViewModel
        let fake: FakeDaemonClient
    }

    // MARK: - Fixtures

    private func tab(
        id: Int,
        session: String,
        name: String? = nil,
        isProtected: Bool = false,
        panes: [SimPaneState] = []
    ) -> TabState {
        let primary = TerminalPaneState(
            id: TerminalPaneID(value: id),
            sessionId: session,
            capability: "cap",
            shortId: nil,
            name: name
        )
        return TabState(
            id: TabID(value: id),
            terminals: [primary],
            simPanes: panes,
            isProtected: isProtected
        )
    }

    private func pane(paneId: String, udid: String) -> SimPaneState {
        SimPaneState(paneId: paneId, udid: udid, displayName: "iPhone", family: "iPhone")
    }

    /// One window per element (so a window can hold only a foreign-protected
    /// tab and thereby disappear from an external caller's window list).
    private func workspace(windows: [[TabState]], keyIndex: Int = 0) -> WorkspaceViewModel {
        let space = WorkspaceViewModel()
        var ids: [WindowID] = []
        for (index, tabs) in windows.enumerated() {
            let list = TabListViewModel()
            for tab in tabs { list.append(tab) }
            let id = WindowID(value: index + 1)
            ids.append(id)
            space.addWindow(WindowState(id: id, tabs: list))
        }
        if ids.indices.contains(keyIndex) { space.select(id: ids[keyIndex]) }
        return space
    }

    private func resolver(
        _ space: WorkspaceViewModel,
        _ origin: IntentOrigin
    ) -> IntentResolver {
        IntentResolver(workspace: space, origin: origin)
    }

    // MARK: - Tab resolution

    @Test
    func foreignProtectedTabIsNotFoundBySessionID() {
        let pub = tab(id: 1, session: "S-pub")
        let priv = tab(id: 2, session: "S-priv", isProtected: true)
        let res = resolver(workspace(windows: [[pub, priv]]), .external(sessionID: "S-pub", hasAutomationGrant: false))
        #expect(throws: IntentError.self) {
            try res.resolveTab(.sessionId("S-priv"))
        }
    }

    @Test
    func ownerReachesOwnProtectedTab() throws {
        let pub = tab(id: 1, session: "S-pub")
        let priv = tab(id: 2, session: "S-priv", isProtected: true)
        let res = resolver(workspace(windows: [[pub, priv]]), .external(sessionID: "S-priv", hasAutomationGrant: false))
        let resolved = try res.resolveTab(.sessionId("S-priv"))
        #expect(resolved.tabID == TabID(value: 2))
    }

    @Test
    func inProcessSeesProtectedTab() throws {
        let priv = tab(id: 2, session: "S-priv", isProtected: true)
        let res = resolver(workspace(windows: [[priv]]), .inProcess)
        let resolved = try res.resolveTab(.sessionId("S-priv"))
        #expect(resolved.tabID == TabID(value: 2))
    }

    @Test
    func ambiguousNameDoesNotLeakForeignProtectedTab() throws {
        // A name shared by a visible tab and a foreign-protected tab must
        // resolve to the visible one, never `.ambiguous`, which would
        // reveal the protected tab and a match count.
        let pub = tab(id: 1, session: "S-pub", name: "shared")
        let priv = tab(id: 2, session: "S-priv", name: "shared", isProtected: true)
        let res = resolver(workspace(windows: [[pub, priv]]), .external(sessionID: "S-pub", hasAutomationGrant: false))
        let resolved = try res.resolveTab(.name("shared"))
        #expect(resolved.tabID == TabID(value: 1))
    }

    @Test
    func externalNilSessionCurrentFailsClosed() {
        // An external caller with no session must not borrow the key
        // window's selected tab: `.current` resolves nothing.
        let only = tab(id: 1, session: "S-A")
        let res = resolver(workspace(windows: [[only]]), .external(sessionID: nil, hasAutomationGrant: false))
        #expect(throws: IntentError.self) {
            try res.resolveTab(.current)
        }
    }

    // MARK: - Pane resolution

    @Test
    func foreignProtectedTabPaneIsNotFound() {
        let pub = tab(id: 1, session: "S-pub")
        let priv = tab(
            id: 2,
            session: "S-priv",
            isProtected: true,
            panes: [pane(paneId: "P-priv", udid: "U-priv")]
        )
        let res = resolver(workspace(windows: [[pub, priv]]), .external(sessionID: "S-pub", hasAutomationGrant: false))
        #expect(throws: IntentError.self) { try res.resolveSimPane(.paneId("P-priv")) }
        #expect(throws: IntentError.self) { try res.resolveSimPane(.udid("U-priv")) }
    }

    // MARK: - Window resolution

    @Test
    func windowWithOnlyForeignProtectedTabDisappearsFromIndex() throws {
        // Window 2 holds only a foreign-protected tab, so it isn't counted
        // in an external caller's index space.
        let winA = [tab(id: 1, session: "S-pub")]
        let winB = [tab(id: 2, session: "S-priv", isProtected: true)]
        let res = resolver(workspace(windows: [winA, winB]), .external(sessionID: "S-pub", hasAutomationGrant: false))
        let first = try res.resolveWindow(.index(1))
        #expect(first == WindowID(value: 1))
        #expect(throws: IntentError.self) { try res.resolveWindow(.index(2)) }
    }

    @Test
    func externalCurrentWindowIsCallersNotKeyWindow() throws {
        // Key window is window 1; the external caller lives in window 2.
        // `.current` resolves to the caller's own window.
        let winA = [tab(id: 1, session: "S-A")]
        let winB = [tab(id: 2, session: "S-B")]
        let space = workspace(windows: [winA, winB], keyIndex: 0)
        let res = resolver(space, .external(sessionID: "S-B", hasAutomationGrant: false))
        let current = try res.resolveWindow(.current)
        #expect(current == WindowID(value: 2))
    }

    // MARK: - Dispatcher: set-protected owner gate + windows.list

    private func makeHarness(_ windows: [[TabState]]) -> Harness {
        let space = workspace(windows: windows)
        let fake = FakeDaemonClient()
        let router = Router(workspace: space, daemon: fake)
        let dispatcher = IntentDispatcher(workspace: space, router: router, actionDelegate: nil)
        return Harness(dispatcher: dispatcher, workspace: space, fake: fake)
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    @Test
    func setTabProtectedExternalNonOwnerRefused() async {
        let pub = tab(id: 1, session: "S-pub")
        let priv = tab(id: 2, session: "S-priv", isProtected: true)
        let harness = makeHarness([[pub, priv]])
        let result = await harness.dispatcher.dispatch(
            .setTabProtected(.sessionId("S-priv"), isProtected: false),
            origin: .external(sessionID: "S-pub", hasAutomationGrant: false)
        )
        await settle()
        guard case let .error(error) = result else {
            Issue.record("expected notFound; got \(result)"); return
        }
        #expect(error.code == "intent.notFound")
        #expect(harness.fake.setProtectedBatchCalls.isEmpty)
    }

    @Test
    func setTabProtectedNonOwnerOfVisibleTabIsOwnerRequired() async {
        // Both tabs are unprotected, so resolution succeeds and the owner
        // gate is what refuses. The caller can see this tab in `tabs list`,
        // so the refusal names its reason rather than claiming the tab
        // doesn't exist.
        let mine = tab(id: 1, session: "S-mine")
        let theirs = tab(id: 2, session: "S-theirs")
        let harness = makeHarness([[mine, theirs]])
        let result = await harness.dispatcher.dispatch(
            .setTabProtected(.sessionId("S-theirs"), isProtected: true),
            origin: .external(sessionID: "S-mine", hasAutomationGrant: false)
        )
        await settle()
        guard case let .error(error) = result else {
            Issue.record("expected ownerRequired; got \(result)"); return
        }
        #expect(error.code == "intent.ownerRequired")
        #expect(harness.fake.setProtectedBatchCalls.isEmpty)
    }

    @Test
    func setTabProtectedGrantDoesNotWidenTheOwnerGate() async {
        // The owner gate ignores the grant bit. A granted caller reaching a
        // visible foreign tab is refused exactly like an ungranted one, so
        // the hint must not be `automationRequired`: running this from an
        // Automation Tab would still refuse.
        let mine = tab(id: 1, session: "S-mine")
        let theirs = tab(id: 2, session: "S-theirs")
        let harness = makeHarness([[mine, theirs]])
        let result = await harness.dispatcher.dispatch(
            .setTabProtected(.sessionId("S-theirs"), isProtected: true),
            origin: .external(sessionID: "S-mine", hasAutomationGrant: true)
        )
        await settle()
        guard case let .error(error) = result else {
            Issue.record("a grant reached a foreign tab's protection; got \(result)"); return
        }
        #expect(error.code == "intent.ownerRequired")
        #expect(harness.fake.setProtectedBatchCalls.isEmpty)
    }

    @Test
    func setTabProtectedOwnerUnsetsItsOwnProtectedTab() async {
        // Protection is reversible by the session that owns the tab: the
        // resolver reaches a caller's own protected tab and the owner gate
        // admits it, so the unprotect commits.
        let priv = tab(id: 1, session: "S-priv", isProtected: true)
        let harness = makeHarness([[priv]])
        let result = await harness.dispatcher.dispatch(
            .setTabProtected(.sessionId("S-priv"), isProtected: false),
            origin: .external(sessionID: "S-priv", hasAutomationGrant: false)
        )
        await settle()
        guard case let .data(.tabSetProtected(outcome)) = result else {
            Issue.record("expected committed data; got \(result)"); return
        }
        #expect(outcome.isProtected == false)
        #expect(outcome.committed)
        #expect(harness.fake.setProtectedBatchCalls.count == 1)
    }

    @Test
    func setTabProtectedExternalNilSessionRefused() async {
        let harness = makeHarness([[tab(id: 1, session: "S-A")]])
        let result = await harness.dispatcher.dispatch(
            .setTabProtected(.sessionId("S-A"), isProtected: true),
            origin: .external(sessionID: nil, hasAutomationGrant: false)
        )
        await settle()
        guard case let .error(error) = result else {
            Issue.record("expected error; got \(result)"); return
        }
        // The tab is unprotected, so it resolves and the owner gate refuses
        // a caller that owns no terminal anywhere.
        #expect(error.code == "intent.ownerRequired")
        #expect(harness.fake.setProtectedBatchCalls.isEmpty)
    }

    @Test
    func setTabProtectedInProcessCommitsAndReportsCommitted() async {
        // The dispatch awaits the transition and reports the daemon's real
        // outcome: a successful batch resolves to `committed: true`.
        let harness = makeHarness([[tab(id: 1, session: "S-A")]])
        let result = await harness.dispatcher.dispatch(
            .setTabProtected(.sessionId("S-A"), isProtected: true),
            origin: .inProcess
        )
        #expect(harness.fake.setProtectedBatchCalls.count == 1)
        guard case let .data(.tabSetProtected(outcome)) = result else {
            Issue.record("expected committed data; got \(result)"); return
        }
        #expect(outcome.committed)
        #expect(outcome.isProtected)
    }

    @Test
    func setTabProtectedReportsErrorOnDefiniteRefusal() async {
        // A DEFINITE daemon rejection (validated and refused before the
        // atomic mutation, so it definitely never committed) is a terminal
        // failure, reported as an `.error`, not pending. Retrying can't
        // succeed, so the transition stops and reports the failure; it
        // reconciles the presentation from the authoritative daemon state
        // rather than a request-time snapshot.
        let harness = makeHarness([[tab(id: 1, session: "S-A")]])
        harness.fake.setProtectedBatchFailures = [
            DaemonClientError.daemon(code: -32_602, message: "refused")
        ]
        let result = await harness.dispatcher.dispatch(
            .setTabProtected(.sessionId("S-A"), isProtected: true),
            origin: .inProcess
        )
        guard case .error = result else {
            Issue.record("expected error on definite refusal; got \(result)"); return
        }
    }

    @Test
    func setTabProtectedReportsPendingOnIndeterminateLoss() async {
        // An indeterminate transport loss reports pending (converging),
        // not a false confirmation.
        let harness = makeHarness([[tab(id: 1, session: "S-A")]])
        harness.fake.setProtectedBatchFailures = [
            DaemonClientError.transport("dropped")
        ]
        let result = await harness.dispatcher.dispatch(
            .setTabProtected(.sessionId("S-A"), isProtected: true),
            origin: .inProcess
        )
        guard case let .data(.tabSetProtected(outcome)) = result else {
            Issue.record("expected pending data; got \(result)"); return
        }
        #expect(outcome.committed == false)
    }

    @Test
    func windowCloseRefusedWhenWindowHoldsForeignProtectedTab() async {
        // Window 1 hosts the caller's tab AND a foreign-protected tab. An
        // external close would tear down the protected tab, so it fails
        // closed rather than closing the window.
        let mine = tab(id: 1, session: "S-A")
        let foreign = tab(id: 2, session: "S-priv", isProtected: true)
        let harness = makeHarness([[mine, foreign]])
        let result = await harness.dispatcher.dispatch(
            .closeWindow(.current, mode: .detach),
            origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )
        guard case .error = result else {
            Issue.record("expected close refusal; got \(result)"); return
        }
    }

    @Test
    func paneAttachDoesNotLeakForeignProtectedTabUDID() async {
        // An external caller attaching a UDID that lives in a foreign
        // protected tab must not receive the differentiated "already
        // attached to a different tab" error (which would confirm the
        // UDID's existence there). The scan is origin-scoped, so the
        // foreign pane is invisible and the attach proceeds.
        let udid = "7db632b6-86d3-437d-b567-36a80e59788b"
        let foreignPane = pane(paneId: "P", udid: udid)
        let mine = tab(id: 1, session: "S-pub")
        let priv = tab(id: 2, session: "S-priv", isProtected: true, panes: [foreignPane])
        let harness = makeHarness([[mine, priv]])
        let result = await harness.dispatcher.dispatch(
            .paneAttach(udid: udid),
            origin: .external(sessionID: "S-pub", hasAutomationGrant: false)
        )
        await settle()
        #expect(result == .ok)
    }

    @Test
    func devicePaneRelinkDoesNotDetachForeignProtectedTab() async {
        // The shim relink path (`relinkExisting: true`) must not detach a
        // device mirrored in a foreign protected tab, the origin-scoped
        // scan doesn't see it, so no detach is dispatched.
        let deviceId = "dev-1"
        let foreignDevice = DevicePaneState(
            paneId: "DP",
            deviceId: deviceId,
            displayName: "iPhone",
            family: "iPhone"
        )
        let mine = tab(id: 1, session: "S-pub")
        let primary = TerminalPaneState(
            id: TerminalPaneID(value: 2),
            sessionId: "S-priv",
            capability: "cap"
        )
        let priv = TabState(
            id: TabID(value: 2),
            terminals: [primary],
            simPanes: [],
            devicePanes: [foreignDevice],
            isProtected: true
        )
        let harness = makeHarness([[mine, priv]])
        _ = await harness.dispatcher.dispatch(
            .devicePaneAttach(deviceId: deviceId, relinkExisting: true),
            origin: .external(sessionID: "S-pub", hasAutomationGrant: false)
        )
        await settle()
        // No detach of the foreign-protected tab's device.
        #expect(harness.fake.closePaneCalls.isEmpty)
    }

    @Test
    func windowsListOmitsForeignProtectedWindow() async {
        let winA = [tab(id: 1, session: "S-pub")]
        let winB = [tab(id: 2, session: "S-priv", isProtected: true)]
        let harness = makeHarness([winA, winB])
        let result = await harness.dispatcher.dispatch(
            .windowsList(all: true),
            origin: .external(sessionID: "S-pub", hasAutomationGrant: false)
        )
        guard case .data(.windowsList(let payload)) = result else {
            Issue.record("expected windowsList; got \(result)"); return
        }
        // Only the unprotected window is visible; the protected-only window is
        // absent from the count and index space.
        #expect(payload.count == 1)
        #expect(payload[0].tabCount == 1)
    }
}
