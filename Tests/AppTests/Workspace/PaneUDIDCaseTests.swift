// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// Which spelling of a sim's UDID a mounted pane carries, and therefore
/// which one the GUI-served verbs print.
///
/// The daemon canonicalizes to lowercase at create and reports that back as
/// `PaneCreateResponse.target`, so the internal `pane.deviceList` roster uses
/// lowercase. The attach paths reach the Router with whatever case they were
/// handed: discovery and orphan recovery pass simctl's uppercase through. The
/// GUI stores the daemon's spelling so public `pane show` and daemon-direct
/// device operations stay string-comparable.
@MainActor
struct PaneUDIDCaseTests {
    private struct Harness {
        let dispatcher: IntentDispatcher
        let workspace: WorkspaceViewModel
        let router: Router
        let fake: FakeDaemonClient
    }

    private static let canonical = "1d464fbe-56ba-4a49-8d73-277a7e8a0e92"
    private static let uppercased = "1D464FBE-56BA-4A49-8D73-277A7E8A0E92"

    /// Let the Router's serial drain process queued routes.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    /// A workspace holding one window and its initial tab, with the fake
    /// answering `device.attach` with `target`. No action delegate: every
    /// intent here is a read.
    private func makeHarness(target: PaneTarget?) async -> Harness {
        let workspace = WorkspaceViewModel()
        let fake = FakeDaemonClient()
        fake.attachResult = PaneCreateResponse(
            paneId: "P1",
            scale: nil,
            family: "phone",
            shortId: "abc123",
            target: target
        )
        let router = Router(workspace: workspace, daemon: fake)
        let dispatcher = IntentDispatcher(
            workspace: workspace,
            router: router,
            actionDelegate: nil,
            automationPrograms: FakeAutomationPrograms()
        )
        router.dispatch(.openWindow())
        await settle()
        return Harness(
            dispatcher: dispatcher,
            workspace: workspace,
            router: router,
            fake: fake
        )
    }

    /// Attach `uppercased` into the harness's one tab and settle.
    private func attach(_ harness: Harness) async {
        harness.router.dispatch(
            .attachSimPane(
                tab: TabID(value: 1),
                udid: Self.uppercased,
                displayName: "iPhone"
            )
        )
        await settle()
    }

    private func simPanes(_ workspace: WorkspaceViewModel) -> [SimPaneState] {
        workspace.window(id: WindowID(value: 1))?
            .tabs.tab(id: TabID(value: 1))?.simPanes ?? []
    }

    @Test
    func aMountedPaneCarriesTheUDIDTheDaemonReported() async {
        let harness = await makeHarness(target: .sim(udid: Self.canonical))
        await attach(harness)
        #expect(simPanes(harness.workspace).map(\.udid) == [Self.canonical])
        // The attach still went out with what the caller asked for; only the
        // identity the pane is mounted under changes.
        #expect(harness.fake.attachDeviceCalls.map(\.udid) == [Self.uppercased])
    }

    @Test
    func theLayoutLeafIsKeyedOnTheSameSpellingAsThePane() async throws {
        // The leaf key and the pane's own `udid` are what a later remove or
        // replace matches on, and they are set from separate expressions.
        let harness = await makeHarness(target: .sim(udid: Self.canonical))
        await attach(harness)
        let tree = try #require(
            harness.workspace.window(id: WindowID(value: 1))?
                .tabs.tab(id: TabID(value: 1))?.paneTree
        )
        let leaves = PaneTreeOps.leavesInOrder(tree)
        #expect(leaves.contains(.sim(udid: Self.canonical)))
        #expect(!leaves.contains(.sim(udid: Self.uppercased)))
    }

    @Test
    func aPeerThatSendsNoTargetStillGetsTheCanonicalForm() async {
        // `target` is optional-decoded for daemon-version skew. A peer that
        // omits it canonicalized the UDID behind its own `pane.deviceList`
        // anyway, so echoing the caller's spelling here would leave the two
        // disagreeing for exactly the callers this is meant to help.
        let harness = await makeHarness(target: nil)
        await attach(harness)
        #expect(simPanes(harness.workspace).map(\.udid) == [Self.canonical])
    }

    @Test
    func aReferenceThatIsNotAUUIDIsMountedAsGiven() async {
        // The daemon rejects a malformed UDID before a mount can happen, so
        // this is the shape of the guard rather than a reachable state: a
        // string the canonical rule can't parse is left alone instead of
        // being mangled into one.
        let harness = await makeHarness(target: nil)
        harness.router.dispatch(
            .attachSimPane(tab: TabID(value: 1), udid: "U", displayName: "iPhone")
        )
        await settle()
        #expect(simPanes(harness.workspace).map(\.udid) == ["U"])
    }

    @Test
    func workspacePaneShowReportsTheSameStringAsTheDaemonRoster() async {
        // `pane.deviceList` is answered by the daemon off its own record, while
        // the workspace projection reads the mounted GUI pane. Both
        // readers must name the same Simulator identically.
        let harness = await makeHarness(target: .sim(udid: Self.canonical))
        await attach(harness)
        let result = await harness.dispatcher.dispatch(
            .workspacePaneShow(Self.canonical), origin: .inProcess
        )
        guard case let .data(.workspacePane(payload)) = result else {
            Issue.record("expected .data(.workspacePane); got \(result)")
            return
        }
        #expect(payload.simulator?.udid == Self.canonical)
    }

    @Test
    func recoveryCarriesARenamedPanesNameOnTheAttach() async {
        // A helper restart re-attaches every mounted pane. The user-set name
        // rides the attach so the daemon can stamp the replacement record,
        // which is the only round trip that can restore it.
        let harness = await makeHarness(target: .sim(udid: Self.canonical))
        await attach(harness)
        let renamed = harness.workspace.window(id: WindowID(value: 1))?
            .tabs.renamePane(
            .sim(udid: Self.canonical),
            inTab: TabID(value: 1),
            to: "Login Phone"
        )
        #expect(renamed == true)

        harness.router.dispatch(.recoverPanes)
        await settle()
        #expect(harness.fake.attachDeviceCalls.last?.name == "Login Phone")
    }
}
