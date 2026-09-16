// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Builds the public CLI projection from live GUI-owned workspace state.
@MainActor
final class WorkspaceProjection {
    /// Collection projections include terminal CWD because the measured
    /// 12-terminal case stayed within the accepted latency budget. Keep the A/B
    /// procedure and decision thresholds in
    /// `Tests/Manual/terminal-working-directory-perf.md`.
    static let includesTerminalCWDInCollections = true

    private let workspace: WorkspaceViewModel
    private let resolver: IntentResolver
    private let origin: IntentOrigin
    private weak var actionDelegate: IntentActionDelegate?

    init(
        workspace: WorkspaceViewModel,
        resolver: IntentResolver,
        origin: IntentOrigin,
        actionDelegate: IntentActionDelegate?
    ) {
        self.workspace = workspace
        self.resolver = resolver
        self.origin = origin
        self.actionDelegate = actionDelegate
    }

    func windows(includeAll: Bool) throws -> [WorkspaceWindow] {
        let visible = resolver.visibleWindowStates()
        let selected = includeAll ? visible : [try windowState(id: resolver.resolveWindow(nil))]
        return selected.compactMap { window in
            guard let index = visible.firstIndex(where: { $0.id == window.id }) else { return nil }
            return project(window, visibleIndex: index + 1)
        }
    }

    func window(_ ref: String?) throws -> WorkspaceWindowDetail {
        let id = try resolver.resolveWindow(ref)
        let visible = resolver.visibleWindowStates()
        let state = try windowState(id: id)
        let index = visible.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? 0
        return WorkspaceWindowDetail(
            window: project(state, visibleIndex: index),
            tabs: state.tabs.tabs.compactMap { tab in
                guard IntentResolver.externallyAccessible(
                    tab,
                    callerSessionID: origin.restrictsToVisibleTabs ? origin.sessionID : nil
                ) || !origin.restrictsToVisibleTabs else { return nil }
                return project(tab, in: state)
            }
        )
    }

    func tabs(window: String?, all: Bool) throws -> [WorkspaceTab] {
        if all {
            return resolver.visibleWindowStates().flatMap { state in
                state.tabs.tabs.compactMap { tab in
                    guard isVisible(tab) else { return nil }
                    return project(tab, in: state)
                }
            }
        }
        let state = try windowState(id: resolver.resolveWindow(window))
        return state.tabs.tabs.compactMap { tab in
            guard isVisible(tab) else { return nil }
            return project(tab, in: state)
        }
    }

    func tab(
        _ ref: String?,
        includeTerminalCWD: Bool = WorkspaceProjection.includesTerminalCWDInCollections
    ) throws -> WorkspaceTabDetail {
        let resolved = try resolver.resolveTab(ref)
        let window = try windowState(id: resolved.windowID)
        return WorkspaceTabDetail(
            tab: project(resolved.tab, in: window),
            panes: panes(in: resolved, includeTerminalCWD: includeTerminalCWD),
            layout: projectLayout(resolved.tab.paneTree, tab: resolved)
        )
    }

    /// Project one tab row without walking its pane details.
    ///
    /// Mutation receipts use this when they return a tab summary beside some
    /// other object. In particular, it must not pay for terminal CWD reads that
    /// no returned value can carry.
    func tabSummary(_ ref: String?) throws -> WorkspaceTab {
        let resolved = try resolver.resolveTab(ref)
        let window = try windowState(id: resolved.windowID)
        return project(resolved.tab, in: window)
    }

    func panes(
        tab ref: String?,
        includeTerminalCWD: Bool = WorkspaceProjection.includesTerminalCWDInCollections
    ) throws -> [WorkspacePane] {
        panes(
            in: try resolver.resolveTab(ref),
            includeTerminalCWD: includeTerminalCWD
        )
    }

    func pane(
        _ ref: String?,
        includeTerminalCWD: Bool = true
    ) throws -> WorkspacePane {
        project(
            try resolver.resolveWorkspacePane(ref),
            includeTerminalCWD: includeTerminalCWD
        )
    }

    /// Project only the first committed pane in a tab's layout order.
    func firstPane(
        inTab ref: String?,
        includeTerminalCWD: Bool
    ) throws -> WorkspacePane? {
        let resolved = try resolver.resolveTab(ref)
        guard resolved.tab.lifecycle == .ready else { return nil }
        for slot in PaneTreeOps.leavesInOrder(resolved.tab.paneTree) {
            if let pane = resolvedPane(slot, in: resolved) {
                return project(pane, includeTerminalCWD: includeTerminalCWD)
            }
        }
        return nil
    }

    func project(
        _ resolved: ResolvedWorkspacePane,
        includeTerminalCWD: Bool
    ) -> WorkspacePane {
        let focused = actionDelegate?.focusedPane(
            window: resolved.windowID,
            tab: resolved.tabID
        ) == resolved.slot
        let tab = workspace.windowContaining(tab: resolved.tabID)?
            .tabs.tab(id: resolved.tabID)
        let tabID = tab?.cohortId.uuidString.lowercased() ?? ""
        switch resolved.state {
        case let .terminal(terminal):
            // One hop for the label, the tty, and the directory. Only the
            // directory is grant-scoped, so the gate rides in as a parameter
            // rather than suppressing the whole read: a caller without a grant
            // still gets a title and a tty.
            let facts = actionDelegate?.terminalFacts(
                window: resolved.windowID,
                tab: resolved.tabID,
                terminal: terminal.id,
                includeWorkingDirectory: includeTerminalCWD && origin.readsTerminalWorkingDirectory
            )
            return WorkspacePane(
                id: terminal.sessionId,
                shortId: terminal.shortId ?? fallbackShortID(terminal.sessionId),
                name: terminal.name,
                kind: .terminal,
                tabId: tabID,
                current: origin.sessionID == terminal.sessionId,
                focused: focused,
                capabilities: [.sendInput, .captureText],
                terminal: .init(
                    sessionId: terminal.sessionId,
                    title: PaneTitleDecision.title(
                        oscTitle: facts?.oscTitle,
                        name: terminal.name,
                        oscWorkingDirectory: facts?.oscWorkingDirectory
                    ),
                    tty: facts?.tty,
                    cwd: facts?.cwd
                )
            )

        case let .simulator(pane):
            let capabilities = pane.capabilities ?? .missingBlockFallback
            return WorkspacePane(
                id: pane.paneId,
                shortId: pane.shortId ?? fallbackShortID(pane.paneId),
                name: pane.name,
                kind: .simulator,
                tabId: tabID,
                current: currentSlot(in: resolved.tabID) == resolved.slot,
                focused: focused,
                capabilities: workspaceCapabilities(capabilities),
                simulator: .init(
                    udid: pane.udid,
                    displayName: pane.displayName,
                    family: pane.family,
                    state: actionDelegate?.paneLifecycle(
                        window: resolved.windowID,
                        tab: resolved.tabID,
                        slot: resolved.slot
                    ),
                    orientation: actionDelegate?.paneOrientation(
                        window: resolved.windowID,
                        tab: resolved.tabID,
                        slot: resolved.slot
                    ),
                    pixelWidth: pane.pixelWidth,
                    pixelHeight: pane.pixelHeight,
                    capabilities: pane.capabilities
                )
            )

        case let .device(pane):
            let capabilities = pane.capabilities ?? .missingBlockFallback
            return WorkspacePane(
                id: pane.paneId,
                shortId: pane.shortId ?? fallbackShortID(pane.paneId),
                name: pane.name,
                kind: .device,
                tabId: tabID,
                current: currentSlot(in: resolved.tabID) == resolved.slot,
                focused: focused,
                capabilities: workspaceCapabilities(capabilities),
                device: .init(
                    deviceId: pane.deviceId,
                    displayName: pane.displayName,
                    family: pane.family,
                    state: actionDelegate?.paneLifecycle(
                        window: resolved.windowID,
                        tab: resolved.tabID,
                        slot: resolved.slot
                    ),
                    orientation: actionDelegate?.paneOrientation(
                        window: resolved.windowID,
                        tab: resolved.tabID,
                        slot: resolved.slot
                    ),
                    pixelWidth: pane.pixelWidth,
                    pixelHeight: pane.pixelHeight,
                    capabilities: pane.capabilities
                )
            )
        }
    }

    private func project(_ window: WindowState, visibleIndex: Int) -> WorkspaceWindow {
        let visibleTabs = window.tabs.tabs.filter(isVisible)
        let selected = window.tabs.selectedTab.flatMap { selected in
            isVisible(selected) ? selected : nil
        }
        return WorkspaceWindow(
            id: window.publicID.uuidString.lowercased(),
            shortId: WorkspaceShortID.make(from: window.publicID),
            name: window.name,
            index: visibleIndex,
            current: currentWindowID() == window.id,
            focused: workspace.selectedWindowID == window.id,
            selectedTabId: selected?.cohortId.uuidString.lowercased(),
            tabCount: visibleTabs.count
        )
    }

    private func project(_ tab: TabState, in window: WindowState) -> WorkspaceTab {
        let rawTitle: String
        if tab.lifecycle == .failed {
            rawTitle = tab.name ?? "Tab creation failed"
        } else {
            rawTitle = actionDelegate?.tabDisplayTitle(window: window.id, tab: tab.id)
                ?? tab.name
                ?? tab.primaryTerminal.name
                ?? "Terminal"
        }
        let title = DisplayTitleNormalizer.normalize(rawTitle)
            ?? DisplayTitleNormalizer.normalize(tab.name)
            ?? DisplayTitleNormalizer.normalize(tab.primaryTerminal.name)
            ?? "Terminal"
        let selected = window.tabs.selectedTab?.id == tab.id
        return WorkspaceTab(
            id: tab.cohortId.uuidString.lowercased(),
            shortId: WorkspaceShortID.make(from: tab.cohortId),
            name: tab.name,
            title: title,
            windowId: window.publicID.uuidString.lowercased(),
            current: tab.terminals.contains { $0.sessionId == origin.sessionID },
            selected: selected,
            protected: tab.isEffectivelyProtected,
            state: tab.lifecycle,
            paneCount: tab.lifecycle == .ready
                ? PaneTreeOps.leavesInOrder(tab.paneTree).filter {
                    if case .pending = $0 { return false }
                    return true
                }.count
                : 0
        )
    }

    private func panes(
        in resolved: ResolvedTab,
        includeTerminalCWD: Bool
    ) -> [WorkspacePane] {
        guard resolved.tab.lifecycle == .ready else { return [] }
        return PaneTreeOps.leavesInOrder(resolved.tab.paneTree).compactMap { slot in
            resolvedPane(slot, in: resolved).map {
                project($0, includeTerminalCWD: includeTerminalCWD)
            }
        }
    }

    private func resolvedPane(_ slot: PaneSlot, in tab: ResolvedTab) -> ResolvedWorkspacePane? {
        switch slot {
        case let .terminal(id):
            guard let state = tab.tab.terminals.first(where: { $0.id == id }) else { return nil }
            return .init(windowID: tab.windowID, tabID: tab.tabID, slot: slot, state: .terminal(state))

        case let .sim(udid):
            guard let state = tab.tab.simPanes.first(where: { $0.udid == udid }) else { return nil }
            return .init(windowID: tab.windowID, tabID: tab.tabID, slot: slot, state: .simulator(state))

        case let .device(deviceId):
            guard let state = tab.tab.devicePanes.first(where: { $0.deviceId == deviceId }) else { return nil }
            return .init(windowID: tab.windowID, tabID: tab.tabID, slot: slot, state: .device(state))

        case .pending:
            return nil
        }
    }

    private func projectLayout(_ node: PaneNode, tab: ResolvedTab) -> WorkspaceLayoutNode? {
        guard tab.tab.lifecycle == .ready else { return nil }
        switch node {
        case let .leaf(slot):
            guard let pane = resolvedPane(slot, in: tab) else { return nil }
            return .pane(id: pane.id)

        case let .split(axis, children, extents):
            let kept = children.enumerated().compactMap { index, child -> (WorkspaceLayoutNode, Double)? in
                guard let projected = projectLayout(child, tab: tab) else { return nil }
                let extent = extents.indices.contains(index) ? Double(extents[index]) : 1
                return (projected, extent)
            }
            if kept.count == 1 { return kept[0].0 }
            guard kept.count > 1 else { return nil }
            return .split(
                axis: axis == .horizontal ? "horizontal" : "vertical",
                extents: kept.map(\.1),
                children: kept.map(\.0)
            )
        }
    }

    private func currentSlot(in tabID: TabID) -> PaneSlot? {
        guard let window = workspace.windowContaining(tab: tabID),
            let tab = window.tabs.tab(id: tabID) else { return nil }
        if let sessionID = origin.sessionID,
            let terminal = tab.terminals.first(where: { $0.sessionId == sessionID }) {
            return .terminal(terminal.id)
        }
        return actionDelegate?.focusedPane(window: window.id, tab: tabID)
    }

    private func currentWindowID() -> WindowID? {
        if case .inProcess = origin { return workspace.selectedWindowID }
        guard let sessionID = origin.sessionID else { return nil }
        return workspace.windows.first { window in
            window.tabs.tabs.contains { tab in
                tab.terminals.contains { $0.sessionId == sessionID }
            }
        }?.id
    }

    private func isVisible(_ tab: TabState) -> Bool {
        !origin.restrictsToVisibleTabs
            || IntentResolver.externallyAccessible(tab, callerSessionID: origin.sessionID)
    }

    private func windowState(id: WindowID) throws -> WindowState {
        guard let window = workspace.window(id: id) else {
            throw IntentError.notFound(kind: "window", ref: "current")
        }
        return window
    }

    private func fallbackShortID(_ id: String) -> String {
        if let uuid = UUID(uuidString: id) { return WorkspaceShortID.make(from: uuid) }
        return String(id.prefix(6)).lowercased()
    }

    private func workspaceCapabilities(_ source: PaneCapabilities) -> [WorkspacePaneCapability] {
        var result: [WorkspacePaneCapability] = []
        if source.touch { result.append(.touch) }
        if source.key { result.append(.key) }
        if source.text { result.append(.text) }
        if source.button { result.append(.button) }
        if source.rotate { result.append(.rotate) }
        if source.crown { result.append(.crown) }
        if source.accessibility { result.append(.accessibility) }
        if source.location { result.append(.location) }
        return result
    }
}
