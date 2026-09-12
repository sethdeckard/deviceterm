// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

@MainActor
struct IntentResolverTests {
    private struct WindowFixture {
        let id: WindowID
        let publicID: UUID
        let tabs: [TabState]
        let selected: Bool
        let name: String?

        init(
            id: WindowID,
            tabs: [TabState],
            selected: Bool,
            publicID: UUID = UUID(),
            name: String? = nil
        ) {
            self.id = id
            self.publicID = publicID
            self.tabs = tabs
            self.selected = selected
            self.name = name
        }
    }

    private func makeWorkspace(_ fixtures: [WindowFixture]) -> WorkspaceViewModel {
        let workspace = WorkspaceViewModel()
        for fixture in fixtures {
            let tabs = TabListViewModel()
            fixture.tabs.forEach(tabs.append)
            workspace.addWindow(
                WindowState(
                    id: fixture.id,
                    tabs: tabs,
                    publicID: fixture.publicID,
                    name: fixture.name
                )
            )
        }
        if let selected = fixtures.first(where: \.selected)?.id {
            workspace.select(id: selected)
        }
        return workspace
    }

    private func tab(
        _ value: Int,
        session: String,
        publicID: UUID = UUID(),
        name: String? = nil,
        terminals: [TerminalPaneState]? = nil,
        simPanes: [SimPaneState] = []
    ) -> TabState {
        let primary = TerminalPaneState(
            id: TerminalPaneID(value: value),
            sessionId: session,
            capability: "cap"
        )
        return TabState(
            id: TabID(value: value),
            terminals: terminals ?? [primary],
            simPanes: simPanes,
            cohortId: publicID,
            name: name
        )
    }

    @Test
    func currentReferencesAreOriginAware() throws {
        let tabA = tab(1, session: "S-A")
        let tabB = tab(2, session: "S-B")
        let workspace = makeWorkspace([
            .init(id: WindowID(value: 1), tabs: [tabA], selected: true),
            .init(id: WindowID(value: 2), tabs: [tabB], selected: false)
        ])

        let inProcess = IntentResolver(workspace: workspace, origin: .inProcess)
        let external = IntentResolver(
            workspace: workspace,
            origin: .external(sessionID: "S-B", hasAutomationGrant: false)
        )

        #expect(try inProcess.resolveWindow(nil) == WindowID(value: 1))
        #expect(try inProcess.resolveTab(nil).tabID == TabID(value: 1))
        #expect(try external.resolveWindow("current") == WindowID(value: 2))
        #expect(try external.resolveTab("current").tabID == TabID(value: 2))
    }

    @Test
    func currentTabMatchesEveryTerminalSession() throws {
        let terminals = [
            TerminalPaneState(
                id: TerminalPaneID(value: 1),
                sessionId: "S-primary",
                capability: "cap"
            ),
            TerminalPaneState(
                id: TerminalPaneID(value: 2),
                sessionId: "S-sibling",
                capability: "cap"
            )
        ]
        let workspace = makeWorkspace([
            .init(
                id: WindowID(value: 1),
                tabs: [tab(1, session: "S-primary", terminals: terminals)],
                selected: true
            )
        ])
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .external(sessionID: "S-sibling", hasAutomationGrant: false)
        )

        #expect(try resolver.resolveTab(nil).tabID == TabID(value: 1))
        #expect(try resolver.resolveWorkspacePane(nil).id == "S-sibling")
    }

    @Test
    func idsShortIdsAndUniqueExactNamesResolve() throws {
        let windowID = try #require(UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000001"))
        let tabID = try #require(UUID(uuidString: "12345600-0000-0000-0000-000000000001"))
        let pane = SimPaneState(
            paneId: "FEDCBA00-0000-0000-0000-000000000001",
            udid: "SIM-ONE",
            displayName: "iPhone",
            family: "iPhone",
            shortId: "fedcba",
            name: "phone"
        )
        let workspace = makeWorkspace([
            .init(
                id: WindowID(value: 1),
                tabs: [tab(1, session: "SESSION", publicID: tabID, name: "billing", simPanes: [pane])],
                selected: true,
                publicID: windowID,
                name: "workspace"
            )
        ])
        let resolver = IntentResolver(workspace: workspace, origin: .inProcess)

        #expect(try resolver.resolveWindow("abcdef") == WindowID(value: 1))
        #expect(try resolver.resolveWindow(windowID.uuidString).value == 1)
        #expect(try resolver.resolveWindow("workspace").value == 1)
        #expect(try resolver.resolveTab("123456").tabID.value == 1)
        #expect(try resolver.resolveTab(tabID.uuidString).tabID.value == 1)
        #expect(try resolver.resolveTab("billing").tabID.value == 1)
        #expect(try resolver.resolveWorkspacePane("fedcba").id == pane.paneId)
        #expect(try resolver.resolveWorkspacePane(pane.paneId).id == pane.paneId)
        #expect(try resolver.resolveWorkspacePane("phone").id == pane.paneId)
    }

    @Test
    func publicNamesResolveExactlyNeverByPrefix() throws {
        let pane = SimPaneState(
            paneId: UUID().uuidString,
            udid: "SIM-ONE",
            displayName: "iPhone",
            family: "iPhone",
            name: "phone"
        )
        let workspace = makeWorkspace([
            .init(
                id: WindowID(value: 1),
                tabs: [tab(1, session: "SESSION", name: "billing", simPanes: [pane])],
                selected: true,
                name: "workspace"
            )
        ])
        let resolver = IntentResolver(workspace: workspace, origin: .inProcess)

        #expect(try resolver.resolveWindow("workspace").value == 1)
        #expect(try resolver.resolveTab("billing").tabID.value == 1)
        #expect(try resolver.resolveWorkspacePane("phone").id == pane.paneId)
        #expect(throws: IntentError.self) { try resolver.resolveWindow("work") }
        #expect(throws: IntentError.self) { try resolver.resolveTab("bill") }
        #expect(throws: IntentError.self) { try resolver.resolveWorkspacePane("pho") }
    }

    @Test
    func UUIDPrefixesRemainResolvableAndAmbiguousPrefixesRefuse() throws {
        let first = try #require(UUID(uuidString: "AAA11100-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "AAA22200-0000-0000-0000-000000000002"))
        let workspace = makeWorkspace([
            .init(
                id: WindowID(value: 1),
                tabs: [
                    tab(1, session: "S-A", publicID: first),
                    tab(2, session: "S-B", publicID: second)
                ],
                selected: true
            )
        ])
        let resolver = IntentResolver(workspace: workspace, origin: .inProcess)

        #expect(try resolver.resolveTab("aaa1110").tabID.value == 1)
        #expect(
            throws: IntentError.ambiguous(kind: "tab", ref: "aaa", matchCount: 2)
        ) {
            try resolver.resolveTab("aaa")
        }
    }

    @Test
    func collidingShortIdsRefuse() throws {
        let first = try #require(UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000002"))
        let workspace = makeWorkspace([
            .init(
                id: WindowID(value: 1),
                tabs: [
                    tab(1, session: "S-A", publicID: first),
                    tab(2, session: "S-B", publicID: second)
                ],
                selected: true
            )
        ])
        let resolver = IntentResolver(workspace: workspace, origin: .inProcess)

        #expect(
            throws: IntentError.ambiguous(kind: "tab", ref: "abcdef", matchCount: 2)
        ) {
            try resolver.resolveTab("abcdef")
        }
    }

    @Test
    func windowIndexIsMetadataOnly() {
        let workspace = makeWorkspace([
            .init(id: WindowID(value: 1), tabs: [tab(1, session: "S-A")], selected: true)
        ])
        let resolver = IntentResolver(workspace: workspace, origin: .inProcess)

        #expect(throws: IntentError.notFound(kind: "window", ref: "1")) {
            try resolver.resolveWindow("1")
        }
    }
}
