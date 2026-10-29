// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

/// Builds a `WorkspaceSnapshot` from the live navigation model.
///
/// Pure over its inputs: the workspace plus the few facts only AppKit holds,
/// passed in as `Sources`, so the mapping is unit-tested without windows.
/// Records layout and nothing that grants anything (see `WorkspaceSnapshot`):
/// no session id, capability, role, or command reaches the result, and an
/// automation tab is left out whole, because the `automation-programs` file
/// reopens it.
@MainActor
enum WorkspaceSnapshotBuilder {
    /// What the navigation model doesn't hold.
    struct Sources {
        /// A window's current frame.
        var windowFrame: @MainActor (WindowID) -> CGRect?
        /// A tab's live divider proportions, keyed by split path. The tree's
        /// own `extents` are insert-time seeds and go stale once a divider
        /// moves.
        var ratios: @MainActor (TabID) -> [[Int]: [CGFloat]]
        /// A terminal's current working directory.
        var workingDirectory: @MainActor (TabID, TerminalPaneID) -> String?
        /// The name the user gave a tab, nil for the automatic title.
        var manualTitle: @MainActor (TabID) -> String?
        /// The id of a terminal's saved scrollback, nil when none was saved.
        var scrollback: @MainActor (TabID, TerminalPaneID) -> String? = { _, _ in nil }
    }

    static func build(workspace: WorkspaceViewModel, sources: Sources) -> WorkspaceSnapshot {
        var windows: [WorkspaceSnapshot.Window] = []
        var selectedWindow: Int?
        for window in workspace.windows {
            let selectedTabID = window.tabs.selectedTab?.id
            var tabs: [WorkspaceSnapshot.Tab] = []
            var selectedTab: Int?
            for tab in window.tabs.tabs where tab.role != .automation {
                guard let saved = snapshot(of: tab, sources: sources) else { continue }
                if tab.id == selectedTabID { selectedTab = tabs.count }
                tabs.append(saved)
            }
            guard !tabs.isEmpty else { continue }
            if window.id == workspace.selectedWindowID { selectedWindow = windows.count }
            windows.append(
                WorkspaceSnapshot.Window(
                    frame: sources.windowFrame(window.id).map(WorkspaceSnapshot.Frame.init),
                    tabs: tabs,
                    selectedTab: selectedTab
                )
            )
        }
        return WorkspaceSnapshot(windows: windows, selectedWindow: selectedWindow)
    }

    private static func snapshot(
        of tab: TabState,
        sources: Sources
    ) -> WorkspaceSnapshot.Tab? {
        let ratios = sources.ratios(tab.id)
        var kept: [PaneSlot] = []
        guard let layout = node(
            tab.paneTree,
            path: [],
            tab: tab,
            ratios: ratios,
            sources: sources,
            kept: &kept
        ) else { return nil }
        return WorkspaceSnapshot.Tab(
            title: sources.manualTitle(tab.id),
            isPinned: tab.isPinned,
            layout: layout,
            focusedLeaf: tab.lastFocusedPane.flatMap { kept.firstIndex(of: $0) }
        )
    }

    private static func node(
        _ node: PaneNode,
        path: [Int],
        tab: TabState,
        ratios: [[Int]: [CGFloat]],
        sources: Sources,
        kept: inout [PaneSlot]
    ) -> WorkspaceSnapshot.Node? {
        switch node {
        case let .leaf(slot):
            guard let leaf = leaf(slot, tab: tab, sources: sources) else { return nil }
            kept.append(slot)
            return leaf

        case let .split(axis, children, _):
            var saved: [WorkspaceSnapshot.Node] = []
            for (index, child) in children.enumerated() {
                if let childNode = self.node(
                    child,
                    path: path + [index],
                    tab: tab,
                    ratios: ratios,
                    sources: sources,
                    kept: &kept
                ) {
                    saved.append(childNode)
                }
            }
            if saved.isEmpty { return nil }
            if saved.count == 1 { return saved[0] }
            // Proportions describe the children as they were, so they only
            // carry over when none was dropped.
            let live = ratios[path].flatMap { $0.count == saved.count && saved.count == children.count ? $0 : nil }
            return .split(axis: axis, children: saved, ratios: live?.map(Double.init))
        }
    }

    private static func leaf(
        _ slot: PaneSlot,
        tab: TabState,
        sources: Sources
    ) -> WorkspaceSnapshot.Node? {
        switch slot {
        case let .terminal(id):
            guard let terminal = tab.terminals.first(where: { $0.id == id }) else { return nil }
            return .terminal(
                WorkspaceSnapshot.Terminal(
                    cwd: sources.workingDirectory(tab.id, id) ?? terminal.cwd,
                    name: terminal.name,
                    scrollback: sources.scrollback(tab.id, id)
                )
            )

        case let .sim(udid):
            guard let pane = tab.simPanes.first(where: { $0.udid == udid }) else { return nil }
            return .sim(device(id: udid, pane: pane))

        case let .device(deviceId):
            guard let pane = tab.devicePanes.first(where: { $0.deviceId == deviceId }) else {
                return nil
            }
            return .device(device(id: deviceId, pane: pane))

        case let .pending(id):
            guard let pending = tab.pendingPanes.first(where: { $0.id == id }) else { return nil }
            let saved = WorkspaceSnapshot.Device(
                id: pending.target.key,
                displayName: pending.displayName ?? pending.resolvedLabel,
                name: pending.name,
                family: pending.family,
                sizePreset: pending.sizePreset?.rawValue
            )
            switch pending.target {
            case .sim:
                return .sim(saved)

            case .device:
                return .device(saved)
            }
        }
    }

    private static func device(id: String, pane: any MirroredPaneState) -> WorkspaceSnapshot.Device {
        WorkspaceSnapshot.Device(
            id: id,
            displayName: pane.displayName,
            name: pane.name,
            family: pane.family,
            sizePreset: pane.sizePreset?.rawValue
        )
    }
}
