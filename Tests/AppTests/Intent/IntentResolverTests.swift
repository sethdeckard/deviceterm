// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// Pin the happy-path + error-path behavior of
/// each ref kind.
///
/// The resolver lives at `@MainActor` (it reads the workspace's live
/// tab/window lists) and is pure (no mutation, no side effects). Each
/// test seeds a `WorkspaceViewModel` with synthetic state, runs one
/// resolution, asserts either the resolved ID/struct or the typed
/// `IntentError`.
@MainActor
struct IntentResolverTests {
    // MARK: - Fixtures

    private struct WindowFixture {
        let id: WindowID
        let tabs: [TabState]
        let selected: Bool
    }

    private func makeWorkspace(windows: [WindowFixture]) -> WorkspaceViewModel {
        let workspace = WorkspaceViewModel()
        for fixture in windows {
            let list = TabListViewModel()
            for tab in fixture.tabs { list.append(tab) }
            workspace.addWindow(WindowState(id: fixture.id, tabs: list))
        }
        if let selected = windows.first(where: \.selected)?.id {
            workspace.select(id: selected)
        }
        return workspace
    }

    private func tab(
        id: TabID,
        session: String,
        shortId: String? = nil,
        name: String? = nil,
        panes: [SimPaneState] = []
    ) -> TabState {
        let primary = TerminalPaneState(
            id: TerminalPaneID(value: id.value),
            sessionId: session,
            capability: "cap",
            shortId: shortId,
            name: name
        )
        return TabState(id: id, terminals: [primary], simPanes: panes)
    }

    private func pane(
        paneId: String,
        udid: String,
        shortId: String? = nil
    ) -> SimPaneState {
        SimPaneState(
            paneId: paneId,
            udid: udid,
            displayName: "iPhone",
            family: "iPhone",
            shortId: shortId
        )
    }

    // MARK: - resolveTab

    @Test
    func resolveTabCurrentUsesCallerSession() throws {
        let tabA = tab(id: TabID(value: 1), session: "S-A")
        let tabB = tab(id: TabID(value: 2), session: "S-B")
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [tabA, tabB],
                selected: true
            )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .external(sessionID: "S-B", hasAutomationGrant: false)
        )
        let resolved = try resolver.resolveTab(.current)
        #expect(resolved.tabID == TabID(value: 2))
    }

    @Test
    func resolveTabCurrentFallsBackToKeyWindowSelection() throws {
        let tabA = tab(id: TabID(value: 1), session: "S-A")
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [tabA],
                selected: true
            )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .inProcess
        )
        let resolved = try resolver.resolveTab(.current)
        #expect(resolved.tabID == TabID(value: 1))
    }

    @Test
    func resolveTabBySessionIDFindsMatch() throws {
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [
                tab(id: TabID(value: 1), session: "S-A"),
                tab(id: TabID(value: 2), session: "S-B")
                ],
                selected: true
                )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .inProcess
        )
        let resolved = try resolver.resolveTab(.sessionId("S-B"))
        #expect(resolved.tabID == TabID(value: 2))
    }

    @Test
    func resolveTabBySessionIDNotFoundThrows() {
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [
                tab(id: TabID(value: 1), session: "S-A")
                ],
                selected: true
                )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .inProcess
        )
        #expect(throws: IntentError.notFound(kind: "tab", ref: "S-X")) {
            try resolver.resolveTab(.sessionId("S-X"))
        }
    }

    @Test
    func resolveTabByShortIDDuplicateThrowsAmbiguous() {
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [
                tab(id: TabID(value: 1), session: "S-A", shortId: "ab12"),
                tab(id: TabID(value: 2), session: "S-B", shortId: "ab12")
                ],
                selected: true
                )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .inProcess
        )
        #expect(
            throws: IntentError.ambiguous(
            kind: "tab",
            ref: "ab12",
            matchCount: 2
        )
        ) {
            try resolver.resolveTab(.shortId("ab12"))
        }
    }

    @Test
    func resolveTabByNameUniqueHit() throws {
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [
                tab(id: TabID(value: 1), session: "S-A", name: "auth"),
                tab(id: TabID(value: 2), session: "S-B", name: "billing")
                ],
                selected: true
                )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .inProcess
        )
        let resolved = try resolver.resolveTab(.name("billing"))
        #expect(resolved.tabID == TabID(value: 2))
    }

    @Test
    func resolveTabBySessionMatchesAnyTerminalInTab() throws {
        // Multi-terminal-pane: a CLI call from any terminal inside a
        // tab should resolve `.current` to that tab. The resolver
        // walks every terminal's sessionId when matching, not just
        // the primary's.
        let primary = TerminalPaneState(
            id: TerminalPaneID(value: 100),
            sessionId: "S-primary",
            capability: "cap"
        )
        let added = TerminalPaneState(
            id: TerminalPaneID(value: 101),
            sessionId: "S-added",
            capability: "cap"
        )
        let tab = TabState(
            id: TabID(value: 7),
            terminals: [primary, added],
            simPanes: []
        )
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(id: WindowID(value: 1), tabs: [tab], selected: true)
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .external(sessionID: "S-added", hasAutomationGrant: false)
        )
        let resolved = try resolver.resolveTab(.current)
        #expect(resolved.tabID == TabID(value: 7))
    }

    // MARK: - resolveSimPane

    @Test
    func resolveSimPaneCurrentRequiresExactlyOneSimPane() throws {
        let onlyPane = pane(paneId: "P1", udid: "U1", shortId: "sh1")
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [
                tab(id: TabID(value: 1), session: "S-A", panes: [onlyPane])
                ],
                selected: true
                )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )
        let resolved = try resolver.resolveSimPane(.current)
        #expect(resolved.pane.paneId == "P1")
    }

    @Test
    func resolveSimPaneCurrentEmptyThrowsNotFound() {
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [
                tab(id: TabID(value: 1), session: "S-A")
                ],
                selected: true
                )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .external(sessionID: "S-A", hasAutomationGrant: false)
        )
        #expect(throws: (any Error).self) {
            try resolver.resolveSimPane(.current)
        }
    }

    @Test
    func resolveSimPaneByUDIDFindsAcrossWindows() throws {
        let windowA = WindowFixture(
            id: WindowID(value: 1),
            tabs: [
            tab(
                id: TabID(value: 1),
                session: "S-A",
                panes: [
                pane(paneId: "P1", udid: "U-iphone")
                ]
                )
            ],
            selected: true
            )
        let windowB = WindowFixture(
            id: WindowID(value: 2),
            tabs: [
            tab(
                id: TabID(value: 2),
                session: "S-B",
                panes: [
                pane(paneId: "P2", udid: "U-watch")
                ]
                )
            ],
            selected: false
            )
        let workspace = makeWorkspace(windows: [windowA, windowB])
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .inProcess
        )
        let resolved = try resolver.resolveSimPane(.udid("U-watch"))
        #expect(resolved.windowID == WindowID(value: 2))
        #expect(resolved.pane.paneId == "P2")
    }

    // MARK: - resolveWindow

    @Test
    func resolveWindowCurrentReturnsSelected() throws {
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [
                tab(id: TabID(value: 1), session: "S-A")
                ],
                selected: false
                ),
            WindowFixture(
                id: WindowID(value: 2),
                tabs: [
                tab(id: TabID(value: 2), session: "S-B")
                ],
                selected: true
                )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .inProcess
        )
        let resolved = try resolver.resolveWindow(.current)
        #expect(resolved == WindowID(value: 2))
    }

    @Test
    func resolveWindowByIndexIs1Based() throws {
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [
                tab(id: TabID(value: 1), session: "S-A")
                ],
                selected: true
                ),
            WindowFixture(
                id: WindowID(value: 2),
                tabs: [
                tab(id: TabID(value: 2), session: "S-B")
                ],
                selected: false
                )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .inProcess
        )
        let first = try resolver.resolveWindow(.index(1))
        let second = try resolver.resolveWindow(.index(2))
        #expect(first == WindowID(value: 1))
        #expect(second == WindowID(value: 2))
    }

    @Test
    func resolveWindowKeyedAlwaysFailsToday() {
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [
                tab(id: TabID(value: 1), session: "S-A")
                ],
                selected: true
                )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .inProcess
        )
        #expect(
            throws: IntentError.notFound(
            kind: "window",
            ref: "anything"
        )
        ) {
            try resolver.resolveWindow(.keyed("anything"))
        }
    }

    @Test
    func resolveWindowByConcreteIDHonorsThisStripsWindow() throws {
        // The strip-pinning case: `.current` would resolve to the
        // routed-selected window (window 1 here), but a tab-strip
        // menu in window 2 should target window 2 regardless of
        // which window the Router last selected.
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [
                tab(id: TabID(value: 1), session: "S-A")
                ],
                selected: true
                ),
            WindowFixture(
                id: WindowID(value: 2),
                tabs: [
                tab(id: TabID(value: 2), session: "S-B")
                ],
                selected: false
                )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .inProcess
        )
        let pinned = try resolver.resolveWindow(
            .windowID(WindowID(value: 2))
        )
        #expect(pinned == WindowID(value: 2))
        let current = try resolver.resolveWindow(.current)
        #expect(current == WindowID(value: 1))
    }

    @Test
    func resolveWindowByConcreteIDRejectsClosedWindow() {
        let workspace = makeWorkspace(
            windows: [
            WindowFixture(
                id: WindowID(value: 1),
                tabs: [
                tab(id: TabID(value: 1), session: "S-A")
                ],
                selected: true
                )
            ]
            )
        let resolver = IntentResolver(
            workspace: workspace,
            origin: .inProcess
        )
        #expect(
            throws: IntentError.notFound(
            kind: "window",
            ref: "windowID 99"
        )
        ) {
            try resolver.resolveWindow(.windowID(WindowID(value: 99)))
        }
    }
}
