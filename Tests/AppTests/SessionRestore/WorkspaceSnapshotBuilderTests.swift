// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

private let udid = "6f9619ff-8b86-d011-b42d-00c04fc964ff"

@MainActor
private func terminal(_ value: Int, name: String? = nil) -> TerminalPaneState {
    TerminalPaneState(
        id: TerminalPaneID(value: value),
        sessionId: "SESSION-\(value)",
        capability: "CAP-SECRET-\(value)",
        name: name,
        cwd: "/start/\(value)",
        command: ["echo", "COMMAND-SECRET"]
    )
}

@MainActor
private func sources(
    frame: CGRect? = CGRect(x: 10, y: 20, width: 1_000, height: 800),
    ratios: [[Int]: [CGFloat]] = [:],
    cwd: [TerminalPaneID: String] = [:],
    title: String? = nil
) -> WorkspaceSnapshotBuilder.Sources {
    WorkspaceSnapshotBuilder.Sources(
        windowFrame: { _ in frame },
        ratios: { _ in ratios },
        workingDirectory: { _, id in cwd[id] },
        manualTitle: { _ in title }
    )
}

@MainActor
@Suite
struct WorkspaceSnapshotBuilderTests {
    /// A tab holding terminal 1 | (sim over terminal 2), the shape the
    /// fixture snapshot records.
    private func splitTab() -> TabState {
        let sim = SimPaneState(
            paneId: "P1",
            udid: udid,
            displayName: "iPhone 17 Pro",
            family: "iphone",
            name: "checkout",
            sizePreset: .pointAccurate
        )
        var tab = TabState(
            id: TabID(value: 1),
            terminals: [terminal(1), terminal(2, name: "logs")],
            simPanes: [sim],
            isPinned: true
        )
        tab.paneTree = .split(
            axis: .horizontal,
            children: [
                .leaf(.terminal(TerminalPaneID(value: 1))),
                .split(
                    axis: .vertical,
                    children: [.leaf(.sim(udid: udid)), .leaf(.terminal(TerminalPaneID(value: 2)))],
                    extents: [1, 1]
                )
            ],
            extents: [1, 1]
        )
        tab.lastFocusedPane = .sim(udid: udid)
        return tab
    }

    private func workspace(_ tabs: [TabState]) -> WorkspaceViewModel {
        let list = TabListViewModel()
        for tab in tabs { list.append(tab) }
        let workspace = WorkspaceViewModel()
        workspace.addWindow(WindowState(id: WindowID(value: 1), tabs: list))
        return workspace
    }

    @Test
    func recordsTheLayoutWithLiveRatiosAndDirectories() {
        let snapshot = WorkspaceSnapshotBuilder.build(
            workspace: workspace([splitTab()]),
            sources: sources(
                ratios: [[]: [0.4, 0.6], [1]: [0.7, 0.3]],
                cwd: [TerminalPaneID(value: 1): "/live/1"],
                title: "Checkout"
            )
        )
        #expect(snapshot.selectedWindow == 0)
        let window = snapshot.windows[0]
        #expect(window.frame == .init(x: 10, y: 20, width: 1_000, height: 800))
        #expect(window.selectedTab == 0)
        let tab = window.tabs[0]
        #expect(tab.title == "Checkout")
        #expect(tab.isPinned)
        #expect(tab.focusedLeaf == 1)
        #expect(
            tab.layout == .split(
                axis: .horizontal,
                children: [
                    // The live directory wins; the startup one fills in.
                    .terminal(.init(cwd: "/live/1", name: nil)),
                    .split(
                        axis: .vertical,
                        children: [
                            .sim(
                                .init(
                                    id: udid,
                                    displayName: "iPhone 17 Pro",
                                    name: "checkout",
                                    family: "iphone",
                                    sizePreset: "pointAccurate"
                                )
                            ),
                            .terminal(.init(cwd: "/start/2", name: "logs"))
                        ],
                        ratios: [0.7, 0.3]
                    )
                ],
                ratios: [0.4, 0.6]
            )
        )
    }

    @Test
    func recordsNoCredentialOrCommand() throws {
        let snapshot = WorkspaceSnapshotBuilder.build(workspace: workspace([splitTab()]), sources: sources())
        let text = try #require(String(data: try WorkspaceSnapshotStore.encode(snapshot), encoding: .utf8))
        #expect(!text.contains("SESSION-"))
        #expect(!text.contains("CAP-SECRET"))
        #expect(!text.contains("COMMAND-SECRET"))
    }

    @Test
    func leavesAutomationTabsOutAndDropsAWindowLeftEmpty() {
        let automation = TabState(
            id: TabID(value: 2),
            terminals: [terminal(3)],
            simPanes: [],
            role: .automation,
            automationCommand: ["agent"]
        )
        #expect(
            WorkspaceSnapshotBuilder.build(workspace: workspace([automation]), sources: sources()).windows.isEmpty
        )
        let mixed = WorkspaceSnapshotBuilder.build(
            workspace: workspace([TabState(id: TabID(value: 1), terminals: [terminal(1)], simPanes: []), automation]),
            sources: sources()
        )
        #expect(mixed.windows.first?.tabs.count == 1)
        // The automation tab was selected last, so no recorded tab is.
        #expect(mixed.windows.first?.selectedTab == nil)
    }

    @Test
    func recordsAPlaceholderAsTheDeviceItStandsFor() {
        var tab = TabState(id: TabID(value: 1), terminals: [terminal(1)], simPanes: [])
        let pending = PendingPaneState(
            id: PendingPaneID(value: 9),
            target: .device(deviceId: "00008130-0001"),
            displayName: "iPhone 16 Pro",
            family: "iphone",
            name: "phone"
        )
        tab.pendingPanes = [pending]
        tab.paneTree = PaneTreeOps.append(leaf: .pending(pending.id), axis: .horizontal, in: tab.paneTree)
        let snapshot = WorkspaceSnapshotBuilder.build(workspace: workspace([tab]), sources: sources())
        guard case let .split(_, children, ratios) = snapshot.windows[0].tabs[0].layout else {
            Issue.record("expected a split")
            return
        }
        #expect(ratios == nil)
        #expect(
            children[1] == .device(
                .init(
                    id: "00008130-0001",
                    displayName: "iPhone 16 Pro",
                    name: "phone",
                    family: "iphone",
                    sizePreset: nil
                )
            )
        )
    }

    @Test
    func ignoresRatiosThatNoLongerFitTheirSplit() {
        let snapshot = WorkspaceSnapshotBuilder.build(
            workspace: workspace([splitTab()]),
            sources: sources(ratios: [[]: [0.2, 0.3, 0.5]])
        )
        guard case let .split(_, _, ratios) = snapshot.windows[0].tabs[0].layout else {
            Issue.record("expected a split")
            return
        }
        #expect(ratios == nil)
    }
}

/// The title a writer test's layout carries, changed between saves.
@MainActor
private final class TitleBox {
    var title: String? = "a"
}

@MainActor
@Suite
struct WorkspaceSnapshotWriterTests {
    private func snapshot(_ title: String?) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            windows: [
                .init(
                    frame: nil,
                    tabs: [.init(title: title, isPinned: false, layout: .terminal(.init()))],
                    selectedTab: 0
                )
            ],
            selectedWindow: 0
        )
    }

    @Test
    func skipsAWriteWhenNothingChanged() {
        let box = TitleBox()
        var writes: [Data] = []
        let writer = WorkspaceSnapshotWriter(
            write: { writes.append($0) },
            build: { self.snapshot(box.title) }
        )
        writer.saveNow()
        writer.saveNow()
        #expect(writes.count == 1)
        box.title = "b"
        writer.saveNow()
        #expect(writes.count == 2)
    }

    @Test
    func writesNothingOnceFrozen() {
        let box = TitleBox()
        var writes: [Data] = []
        let writer = WorkspaceSnapshotWriter(
            write: { writes.append($0) },
            build: { self.snapshot(box.title) }
        )
        writer.saveFinal()
        #expect(writes.count == 1)
        // What quitting does next: the windows go, and the workspace empties.
        box.title = nil
        writer.saveNow()
        writer.start()
        #expect(writes.count == 1)
        #expect(WorkspaceSnapshotStore.decode(writes[0]) == snapshot("a"))
    }
}
