// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Resolve raw public window, tab, and pane refs into GUI-internal IDs.
///
/// Lives at `@MainActor` because it reads the workspace's live tab /
/// window lists. Pure projection (no mutation, no side effects); every
/// error path returns a typed `IntentError` with enough hint for the
/// source-layer to render.
///
/// Resolution is **origin-aware**. The `origin` decides both what
/// `.current` means and which tabs are reachable:
///   - `.inProcess` (menu / tab strip) has full authority: `.current`
///     borrows the key window and every tab is visible.
///   - `.external(sessionID:hasAutomationGrant:)` (the CLI back-channel)
///     resolves `.current` against the caller's own session (never the
///     human's key window), and every enumeration restricts to tabs the
///     caller can legitimately see. A foreign protected tab is opaque: it
///     resolves `notFound`, indistinguishable from a tab that doesn't
///     exist, and never leaks as `.ambiguous`. The grant half of that
///     origin is not read here at all: it widens *authority* to mutate a
///     resolved target (`WorkspaceAuthorityDecision`), never visibility,
///     so a granted caller sees exactly what an ungranted one sees.
///
/// The accessibility check is ANDed **into** each enumeration predicate,
/// not applied as a post-filter, so a name shared by a visible tab and a
/// foreign-protected tab resolves to the visible one rather than throwing
/// `.ambiguous` (which would reveal the protected tab and a match count).
@MainActor
struct IntentResolver {
    let workspace: WorkspaceViewModel
    /// Where the request came from: carries the caller's session (for
    /// `.current` / owner checks) and the visibility policy. Required; no
    /// default, so a call site cannot silently obtain unrestricted
    /// resolution.
    let origin: IntentOrigin

    // MARK: - Accessibility

    /// Whether an external caller may see/reach `tab`: a hidden tab is
    /// reachable only by a caller that owns a terminal in it. A fully
    /// unprotected tab is reachable by anyone. This is the caller-relative
    /// axis; `TabState.isEffectivelyProtected` is the absolute one.
    static func externallyAccessible(_ tab: TabState, callerSessionID: String?) -> Bool {
        guard tab.isEffectivelyProtected else { return true }
        guard let callerSessionID else { return false }
        return tab.terminals.contains { $0.sessionId == callerSessionID }
    }

    /// Accessibility under this resolver's origin: in-process sees
    /// everything; external restricts to `externallyAccessible`.
    private func accessible(_ tab: TabState) -> Bool {
        guard origin.restrictsToVisibleTabs else { return true }
        return Self.externallyAccessible(tab, callerSessionID: origin.sessionID)
    }

    /// Windows an external caller may observe: those with at least one
    /// accessible tab. In-process sees the raw window list. A window that
    /// holds only foreign-protected tabs disappears entirely, so it never
    /// occupies an index or a count an external caller can observe.
    private func visibleWindows() -> [WindowState] {
        guard origin.restrictsToVisibleTabs else { return workspace.windows }
        return workspace.windows.filter { window in
            window.tabs.tabs.contains { accessible($0) }
        }
    }

    /// Caller-visible windows in stable workspace order.
    func visibleWindowStates() -> [WindowState] { visibleWindows() }

    /// Resolve one raw public window reference. Full UUID, short id, and name
    /// are accepted; omitted and `current` are origin-aware.
    func resolveWindow(_ raw: String?) throws -> WindowID {
        guard let raw, !raw.isEmpty, raw != "current" else {
            switch origin {
            case .inProcess:
                guard let windowID = workspace.selectedWindowID else {
                    throw IntentError.notFound(kind: "window", ref: "current")
                }
                return windowID

            case let .external(sessionID, _):
                guard let sessionID, let tab = findBySession(sessionID) else {
                    throw IntentError.notFound(kind: "window", ref: "current")
                }
                return tab.windowID
            }
        }
        let windows = visibleWindows()
        let folded = raw.lowercased()
        let exactShort = windows.filter { WorkspaceShortID.make(from: $0.publicID) == folded }
        if let resolved = try uniqueWindow(exactShort, ref: raw) { return resolved }
        let exactID = windows.filter { $0.publicID.uuidString.lowercased() == folded }
        if let resolved = try uniqueWindow(exactID, ref: raw) { return resolved }
        let exactName = windows.filter { $0.name?.lowercased() == folded }
        if let resolved = try uniqueWindow(exactName, ref: raw) { return resolved }
        let prefix = windows.filter {
            $0.publicID.uuidString.lowercased().hasPrefix(folded)
        }
        guard let resolved = try uniqueWindow(prefix, ref: raw) else {
            throw IntentError.notFound(kind: "window", ref: raw)
        }
        return resolved
    }

    /// Resolve one raw public tab reference using the shared public identity
    /// tiers. Protected foreign tabs never enter the candidate set.
    func resolveTab(_ raw: String?) throws -> ResolvedTab {
        guard let raw, !raw.isEmpty, raw != "current" else {
            return try resolveCurrentTab()
        }
        let folded = raw.lowercased()
        let candidates = visibleTabStates()
        let exactShort = candidates.filter {
            WorkspaceShortID.make(from: $0.tab.cohortId) == folded
        }
        if let resolved = try uniqueTab(exactShort, ref: raw) { return resolved }
        let exactID = candidates.filter { $0.tab.cohortId.uuidString.lowercased() == folded }
        if let resolved = try uniqueTab(exactID, ref: raw) { return resolved }
        let exactName = candidates.filter { $0.tab.name?.lowercased() == folded }
        if let resolved = try uniqueTab(exactName, ref: raw) { return resolved }
        let prefix = candidates.filter {
            $0.tab.cohortId.uuidString.lowercased().hasPrefix(folded)
        }
        guard let resolved = try uniqueTab(prefix, ref: raw) else {
            throw IntentError.notFound(kind: "tab", ref: raw)
        }
        return resolved
    }

    /// Resolve one terminal, Simulator, or physical-device pane reference.
    func resolveWorkspacePane(_ raw: String?) throws -> ResolvedWorkspacePane {
        if raw == nil || raw?.isEmpty == true || raw == "current" {
            return try resolveCurrentWorkspacePane()
        }
        let raw = raw ?? ""
        let folded = raw.lowercased()
        let candidates = visibleWorkspacePanes()
        let exactShort = candidates.filter { $0.shortID?.lowercased() == folded }
        if let resolved = try uniqueWorkspacePane(exactShort, ref: raw) { return resolved }
        let exactID = candidates.filter { $0.id.lowercased() == folded }
        if let resolved = try uniqueWorkspacePane(exactID, ref: raw) { return resolved }
        let exactName = candidates.filter { $0.name?.lowercased() == folded }
        if let resolved = try uniqueWorkspacePane(exactName, ref: raw) { return resolved }
        let exactDevice = candidates.filter { pane in
            switch pane.state {
            case let .simulator(simulator):
                simulator.udid.lowercased() == folded

            case let .device(device):
                device.deviceId.lowercased() == folded

            case .terminal:
                false
            }
        }
        if let resolved = try uniqueWorkspacePane(exactDevice, ref: raw) { return resolved }
        let prefix = candidates.filter { pane in
            pane.id.lowercased().hasPrefix(folded)
        }
        guard let resolved = try uniqueWorkspacePane(prefix, ref: raw) else {
            throw IntentError.notFound(kind: "pane", ref: raw)
        }
        return resolved
    }

    /// `.current` resolution, by origin. In-process borrows the key
    /// window's selected tab; an external caller resolves against its own
    /// session only (never the human's focus) and a nil-session
    /// external caller (no authority) resolves nothing.
    private func resolveCurrentTab() throws -> ResolvedTab {
        switch origin {
        case .inProcess:
            guard let windowID = workspace.selectedWindowID,
                let window = workspace.window(id: windowID),
                let idx = window.tabs.selectedIndex,
                let tab = window.tabs.tabs[safe: idx] else {
                throw IntentError.notFound(kind: "tab", ref: "current")
            }
            return ResolvedTab(windowID: windowID, tabID: tab.id, tab: tab)

        case let .external(sessionID, _):
            guard let sessionID, let hit = findBySession(sessionID) else {
                throw IntentError.notFound(kind: "tab", ref: "current")
            }
            // The caller's own tab is always accessible to it.
            return hit
        }
    }

    // MARK: - Private helpers

    private func findBySession(_ sessionID: String) -> ResolvedTab? {
        // `sessionID` may name any terminal pane inside the tab: each
        // terminal in a tab carries its own daemon session, so a tab
        // matches when ANY of its terminals' sessions match. This is a raw
        // lookup; callers apply the accessibility check.
        for window in workspace.windows {
            if let tab = window.tabs.tabs.first(
                where: { tab in
                    tab.terminals.contains(where: { $0.sessionId == sessionID })
                }
            ) {
                return ResolvedTab(
                    windowID: window.id,
                    tabID: tab.id,
                    tab: tab
                )
            }
        }
        return nil
    }

    private func visibleTabStates() -> [ResolvedTab] {
        visibleWindows().flatMap { window in
            window.tabs.tabs.compactMap { tab in
                guard accessible(tab) else { return nil }
                return ResolvedTab(windowID: window.id, tabID: tab.id, tab: tab)
            }
        }
    }

    private func visibleWorkspacePanes() -> [ResolvedWorkspacePane] {
        visibleTabStates().flatMap { resolved -> [ResolvedWorkspacePane] in
            guard resolved.tab.lifecycle == .ready else { return [] }
            return PaneTreeOps.leavesInOrder(resolved.tab.paneTree).compactMap { slot in
                switch slot {
                case let .terminal(id):
                    guard let terminal = resolved.tab.terminals.first(where: { $0.id == id }) else {
                        return nil
                    }
                    return ResolvedWorkspacePane(
                        windowID: resolved.windowID,
                        tabID: resolved.tabID,
                        slot: slot,
                        state: .terminal(terminal)
                    )

                case let .sim(udid):
                    guard let pane = resolved.tab.simPanes.first(where: { $0.udid == udid }) else {
                        return nil
                    }
                    return ResolvedWorkspacePane(
                        windowID: resolved.windowID,
                        tabID: resolved.tabID,
                        slot: slot,
                        state: .simulator(pane)
                    )

                case let .device(deviceId):
                    guard let pane = resolved.tab.devicePanes.first(where: { $0.deviceId == deviceId }) else {
                        return nil
                    }
                    return ResolvedWorkspacePane(
                        windowID: resolved.windowID,
                        tabID: resolved.tabID,
                        slot: slot,
                        state: .device(pane)
                    )

                case .pending:
                    return nil
                }
            }
        }
    }

    private func resolveCurrentWorkspacePane() throws -> ResolvedWorkspacePane {
        let tab = try resolveCurrentTab()
        let panes = visibleWorkspacePanes().filter { $0.tabID == tab.tabID }
        if let sessionID = origin.sessionID,
            let terminal = panes.first(where: { $0.id == sessionID }) {
            return terminal
        }
        if let remembered = tab.tab.lastFocusedPane,
            let pane = panes.first(where: { $0.slot == remembered }) {
            return pane
        }
        guard let pane = panes.first else {
            throw IntentError.notFound(kind: "pane", ref: "current")
        }
        return pane
    }

    private func uniqueWindow(_ matches: [WindowState], ref: String) throws -> WindowID? {
        if matches.count > 1 {
            throw IntentError.ambiguous(kind: "window", ref: ref, matchCount: matches.count)
        }
        return matches.first?.id
    }

    private func uniqueTab(_ matches: [ResolvedTab], ref: String) throws -> ResolvedTab? {
        if matches.count > 1 {
            throw IntentError.ambiguous(kind: "tab", ref: ref, matchCount: matches.count)
        }
        return matches.first
    }

    private func uniqueWorkspacePane(
        _ matches: [ResolvedWorkspacePane],
        ref: String
    ) throws -> ResolvedWorkspacePane? {
        if matches.count > 1 {
            throw IntentError.ambiguous(kind: "pane", ref: ref, matchCount: matches.count)
        }
        return matches.first
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
