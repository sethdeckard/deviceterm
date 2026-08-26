// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// WorkspaceViewModel: window add/remove/select + the lookups the
/// tab/pane routes rely on.
@MainActor
struct WorkspaceViewModelTests {
    private func window(_ value: Int) -> WindowState {
        WindowState(id: WindowID(value: value), tabs: TabListViewModel())
    }

    @Test
    func addSelectsNewWindow() {
        let workspace = WorkspaceViewModel()
        workspace.addWindow(window(1))
        workspace.addWindow(window(2))
        #expect(workspace.windows.map(\.id) == [WindowID(value: 1), WindowID(value: 2)])
        #expect(workspace.selectedWindowID == WindowID(value: 2))
    }

    @Test
    func removeSelectedFallsBackToLast() {
        let workspace = WorkspaceViewModel()
        workspace.addWindow(window(1))
        workspace.addWindow(window(2))
        workspace.removeWindow(id: WindowID(value: 2))   // the selected one
        #expect(workspace.windows.map(\.id) == [WindowID(value: 1)])
        #expect(workspace.selectedWindowID == WindowID(value: 1))
    }

    @Test
    func removeLastWindowClearsSelection() {
        let workspace = WorkspaceViewModel()
        workspace.addWindow(window(1))
        workspace.removeWindow(id: WindowID(value: 1))
        #expect(workspace.windows.isEmpty)
        #expect(workspace.selectedWindowID == nil)
    }

    @Test
    func findsWindowContainingTab() {
        let workspace = WorkspaceViewModel()
        let first = window(1)
        let second = window(2)
        workspace.addWindow(first)
        workspace.addWindow(second)
        second.tabs.append(
            TabState(
            id: TabID(value: 9),
            terminals: [
                TerminalPaneState(
                id: TerminalPaneID(value: 9),
                sessionId: "S",
                capability: "C"
            )
            ],
            simPanes: []
        )
            )
        #expect(workspace.windowContaining(tab: TabID(value: 9))?.id == WindowID(value: 2))
        #expect(workspace.windowContaining(tab: TabID(value: 99)) == nil)
    }
}
