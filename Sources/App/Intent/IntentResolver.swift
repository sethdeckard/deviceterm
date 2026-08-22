// SPDX-License-Identifier: GPL-3.0-or-later
//
// IntentResolver: resolve user-facing refs (`TabRef`, `PaneRef`,
// `WindowRef`) into GUI-internal IDs the Router consumes.
//
// Lives at `@MainActor` because it reads the workspace's live tab /
// window lists. Pure projection (no mutation, no side effects); every
// error path returns a typed `IntentError` with enough hint for the
// source-layer to render.
//
// Resolution is **origin-aware**. The `origin` decides both what
// `.current` means and which tabs are reachable:
//   - `.inProcess` (menu / tab strip) has full authority: `.current`
//     borrows the key window and every tab is visible.
//   - `.external(sessionID:)` (the CLI back-channel) resolves `.current`
//     against the caller's own session (never the human's key window),
//     and every enumeration restricts to tabs the caller can legitimately
//     see. A foreign protected tab is opaque: it resolves `notFound`,
//     indistinguishable from a tab that doesn't exist, and never leaks as
//     `.ambiguous`.
//
// The accessibility check is ANDed **into** each enumeration predicate,
// not applied as a post-filter, so a name shared by a visible tab and a
// foreign-protected tab resolves to the visible one rather than throwing
// `.ambiguous` (which would reveal the protected tab and a match count).

import Foundation

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

    // MARK: - Tab

    /// Resolve a `TabRef` to a `ResolvedTab`. Throws `IntentError.notFound`
    /// or `.ambiguous` per the matrix in `IntentError`. A foreign protected
    /// tab always resolves `notFound`.
    func resolveTab(_ ref: TabRef) throws -> ResolvedTab {
        switch ref {
        case .current:
            return try resolveCurrentTab()

        case let .sessionId(sid):
            guard let hit = findBySession(sid), accessible(hit.tab) else {
                throw IntentError.notFound(kind: "tab", ref: sid)
            }
            return hit

        case let .shortId(sid):
            // The tab's display identity tracks the primary terminal
            // (the one created at tab-open). Non-primary terminals have
            // their own short_ids but `--tab` refers to the tab, not an
            // internal terminal: match the primary's id.
            return try findUnique(
                kind: "tab",
                ref: sid,
                predicate: { $0.primaryTerminal.shortId == sid }
            )

        case let .name(n):
            return try findUnique(
                kind: "tab",
                ref: n,
                predicate: { $0.primaryTerminal.name == n }
            )
        }
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

        case let .external(sessionID):
            guard let sessionID, let hit = findBySession(sessionID) else {
                throw IntentError.notFound(kind: "tab", ref: "current")
            }
            // The caller's own tab is always accessible to it.
            return hit
        }
    }

    // MARK: - Pane (sim)

    /// Resolve a `PaneRef` to a `ResolvedPane`. `current` requires the
    /// caller's tab to host exactly one sim pane. A pane inside a foreign
    /// protected tab resolves `notFound`.
    func resolveSimPane(_ ref: PaneRef) throws -> ResolvedPane {
        switch ref {
        case .current:
            let tab = try resolveTab(.current)
            guard tab.tab.simPanes.count == 1,
                let pane = tab.tab.simPanes.first else {
                if tab.tab.simPanes.isEmpty {
                    throw IntentError.notFound(
                        kind: "pane",
                        ref: "current (no sim panes in tab)"
                    )
                }
                throw IntentError.ambiguous(
                    kind: "pane",
                    ref: "current",
                    matchCount: tab.tab.simPanes.count
                )
            }
            return ResolvedPane(
                windowID: tab.windowID,
                tabID: tab.tabID,
                pane: pane
            )

        case let .paneId(pid):
            guard let hit = findPane(where: { $0.paneId == pid }) else {
                throw IntentError.notFound(kind: "pane", ref: pid)
            }
            return hit

        case let .udid(udid):
            guard let hit = findPane(where: { $0.udid == udid }) else {
                throw IntentError.notFound(kind: "pane", ref: udid)
            }
            return hit

        case let .shortId(sid):
            return try findUniquePane(
                kind: "pane",
                ref: sid,
                predicate: { $0.shortId == sid }
            )
        }
    }

    // MARK: - Window

    /// Resolve a `WindowRef` to a `WindowID`, origin-aware. An external
    /// caller's `.current` is *its own* window (the one containing its
    /// session's tab), not the key window; `.index` counts only the
    /// visible-window projection, so a window holding only foreign-protected
    /// tabs never occupies a position an external caller can target.
    func resolveWindow(_ ref: WindowRef) throws -> WindowID {
        switch ref {
        case .current:
            switch origin {
            case .inProcess:
                guard let id = workspace.selectedWindowID else {
                    throw IntentError.notFound(
                        kind: "window",
                        ref: "current (no key window)"
                    )
                }
                return id

            case let .external(sessionID):
                guard let sessionID, let hit = findBySession(sessionID) else {
                    throw IntentError.notFound(
                        kind: "window",
                        ref: "current"
                    )
                }
                return hit.windowID
            }

        case let .index(pos):
            let windows = visibleWindows()
            let idx = pos - 1
            guard let window = windows[safe: idx] else {
                throw IntentError.notFound(
                    kind: "window",
                    ref: "index \(pos)"
                )
            }
            return window.id

        case let .keyed(key):
            // `WindowID` is not a user-facing string. Reject opaque keyed
            // references rather than matching them accidentally.
            throw IntentError.notFound(kind: "window", ref: key)

        case let .windowID(id):
            // Direct concrete-ID targeting from an in-process caller
            // (TabStripVC menu actions). Validate the window is still
            // live so a stale ID held across a close surfaces as notFound
            // rather than silently routing to nowhere.
            guard workspace.window(id: id) != nil else {
                throw IntentError.notFound(
                    kind: "window",
                    ref: "windowID \(id.value)"
                )
            }
            return id
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

    private func findUnique(
        kind: String,
        ref: String,
        predicate: (TabState) -> Bool
    ) throws -> ResolvedTab {
        var matches: [ResolvedTab] = []
        for window in workspace.windows {
            // Accessibility is ANDed into the predicate: a foreign-protected
            // tab is invisible to the match, so it can neither be resolved
            // nor inflate an `.ambiguous` count.
            for tab in window.tabs.tabs where accessible(tab) && predicate(tab) {
                matches.append(
                    ResolvedTab(
                    windowID: window.id,
                    tabID: tab.id,
                    tab: tab
                )
                    )
            }
        }
        if matches.isEmpty {
            throw IntentError.notFound(kind: kind, ref: ref)
        }
        if matches.count > 1 {
            throw IntentError.ambiguous(
                kind: kind,
                ref: ref,
                matchCount: matches.count
            )
        }
        return matches[0]
    }

    private func findPane(where predicate: (SimPaneState) -> Bool) -> ResolvedPane? {
        for window in workspace.windows {
            for tab in window.tabs.tabs where accessible(tab) {
                if let pane = tab.simPanes.first(where: predicate) {
                    return ResolvedPane(
                        windowID: window.id,
                        tabID: tab.id,
                        pane: pane
                    )
                }
            }
        }
        return nil
    }

    private func findUniquePane(
        kind: String,
        ref: String,
        predicate: (SimPaneState) -> Bool
    ) throws -> ResolvedPane {
        var matches: [ResolvedPane] = []
        for window in workspace.windows {
            for tab in window.tabs.tabs where accessible(tab) {
                for pane in tab.simPanes where predicate(pane) {
                    matches.append(
                        ResolvedPane(
                        windowID: window.id,
                        tabID: tab.id,
                        pane: pane
                    )
                        )
                }
            }
        }
        if matches.isEmpty {
            throw IntentError.notFound(kind: kind, ref: ref)
        }
        if matches.count > 1 {
            throw IntentError.ambiguous(
                kind: kind,
                ref: ref,
                matchCount: matches.count
            )
        }
        return matches[0]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
