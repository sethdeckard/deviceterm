// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The single consumer of `RouteIntent`, which arrives from the CLI
/// back-channel and from in-process menu actions. Only CLI frames pass
/// through `CLIIntentTranslator`; menu callers construct a `RouteIntent`
/// themselves and dispatch it with `origin: .inProcess`.
///
/// Responsibilities:
///   1. Resolve external refs to GUI IDs via `IntentResolver`.
///   2. Translate the resolved intent into `Route`(s) the Router can
///      execute, OR read inline from the workspace for read-only
///      intents (`*Info` / `windowsList`), OR call an injected
///      `IntentActionDelegate` for actions that don't fit the Route
///      shape (rename / move).
///   3. Return a typed `IntentResult` the source layer renders.
///
/// Pattern notes:
///   - Mutations return `.ok` once the Router has *accepted* the
///     Route. The actual reconcile happens on the MainActor drain
///     shortly after. This optimistic shape avoids instrumenting
///     every Route with a completion handle.
///   - Read-only intents (`tabInfo`, `paneInfo`, `windowsList`)
///     synthesize their payload from current workspace state and
///     return immediately. No Router involvement.
///   - Errors at the resolver layer (notFound / ambiguous) flow
///     up as `IntentResult.error(IntentError)` so the source layer
///     can render without re-classifying.
@MainActor
final class IntentDispatcher {
    private let workspace: WorkspaceViewModel
    private let router: Router
    private weak var actionDelegate: IntentActionDelegate?

    init(
        workspace: WorkspaceViewModel,
        router: Router,
        actionDelegate: IntentActionDelegate?
    ) {
        self.workspace = workspace
        self.router = router
        self.actionDelegate = actionDelegate
    }

    /// Dispatch a single intent. `origin` is **required**: it decides
    /// both what `.current` means and which tabs the caller may reach.
    /// There is deliberately no default: a source layer must name
    /// `.inProcess` (menu / tab strip, full authority) or
    /// `.external(sessionID:hasAutomationGrant:)` (the CLI
    /// back-channel, restricted), so no
    /// path can silently obtain unrestricted resolution by omitting an
    /// argument.
    func dispatch(
        _ intent: RouteIntent,
        origin: IntentOrigin
    ) async -> IntentResult {
        let resolver = IntentResolver(workspace: workspace, origin: origin)
        do {
            return try await handle(intent, resolver: resolver, origin: origin)
        } catch let error as IntentError {
            return .error(error)
        } catch {
            return .error(.internalError(String(describing: error)))
        }
    }

    // MARK: - Per-intent handlers

    private func handle(
        _ intent: RouteIntent,
        resolver: IntentResolver,
        origin: IntentOrigin
    ) async throws -> IntentResult {
        switch intent {
        case .openWindow:
            router.dispatch(.openWindow())
            return .ok

        case let .closeWindow(ref, mode):
            let id = try resolver.resolveWindow(ref)
            // An external caller may not close a window that hosts a tab
            // it can't see: that would tear down a foreign protected tab.
            // Fail closed, indistinguishable from an unknown window.
            if windowHoldsForeignTab(id, origin: origin) {
                throw IntentError.notFound(kind: "window", ref: "close")
            }
            // Closing a window closes every tab in it, so it needs what
            // closing each of those tabs would need. The guard above has
            // already made a window holding an invisible tab opaque, so
            // everything reaching this is a tab the caller can name and
            // a plain refusal discloses nothing new.
            let held = workspace.window(id: id)?.tabs.tabs ?? []
            for tab in held {
                try requireAuthority(
                    "window close",
                    over: tab,
                    requirement: .soleTerminal,
                    origin: origin
                )
            }
            router.dispatch(
                .closeWindow(
                    id,
                    mode: mode,
                    authorizedTerminals: authorizedTerminals(held, origin: origin)
                )
            )
            return .ok

        case let .focusWindow(ref):
            let id = try resolver.resolveWindow(ref)
            guard let delegate = actionDelegate else {
                throw IntentError.internalError(
                    "no IntentActionDelegate wired for focusWindow"
                )
            }
            // No foreign-tab guard here. That guard withholds what a
            // caller could otherwise learn, and a raise discloses
            // nothing: resolution has already refused any window with
            // no caller-visible tab in it. The disruption is the real
            // cost, and the automation grant is what gates it.
            //
            // No `Route.selectWindow` alongside the raise, either.
            // `windowDidBecomeKey` records what AppKit does with it,
            // whereas a route waits on the serial drain and can land
            // after the human has clicked elsewhere, overwriting the
            // newer key window with this stale request.
            delegate.raiseWindow(id)
            return .ok

        case let .windowsList(all):
            return .data(
                .windowsList(
                windowsListPayload(
                includeAll: all,
                origin: origin
            )
                )
                )

        case let .openTab(windowRef, role, cwd, cmd):
            let windowID = try resolveOptionalWindow(
                windowRef,
                resolver: resolver
            )
            switch role {
            case .agent:
                router.dispatch(.newTab(windowID, cwd: cwd, cmd: cmd))

            case .automation:
                router.dispatch(
                    .openAutomationTab(windowID, cwd: cwd, cmd: cmd)
                )
            }
            return .ok

        case let .closeTab(ref, mode):
            let resolved = try resolver.resolveTab(ref)
            // Closing your own single-terminal tab is `exit` by another
            // name, so it stays free. A split tab holds other sessions
            // and closing it ends their work, which is the same
            // cross-session destruction as closing a foreign tab.
            try requireAuthority(
                "tab close",
                over: resolved.tab,
                requirement: .soleTerminal,
                origin: origin
            )
            router.dispatch(
                .closeTab(
                resolved.windowID,
                resolved.tabID,
                mode: mode,
                authorizedTerminals: authorizedTerminals(
                [resolved.tab],
                origin: origin
            )
            )
                )
            return .ok

        case let .renameTab(ref, name):
            let resolved = try resolver.resolveTab(ref)
            try requireAuthority(
                "tab rename",
                over: resolved.tab,
                requirement: .ownership,
                origin: origin
            )
            guard let delegate = actionDelegate else {
                throw IntentError.internalError(
                    "no IntentActionDelegate wired for renameTab"
                )
            }
            delegate.renameTab(
                window: resolved.windowID,
                tab: resolved.tabID,
                to: name
            )
            return .ok

        case let .selectTab(ref):
            let resolved = try resolver.resolveTab(ref)
            // Selects within the host window and deliberately does not
            // raise it. `window focus` is the verb that brings a window
            // forward; keeping the two separate lets a granted caller
            // stage a background window's tab without taking the
            // human's attention, and composes into the same result when
            // it does want both. The trade is that `tab select` on a
            // background window shows nothing until something focuses
            // that window.
            router.dispatch(.selectTab(resolved.windowID, resolved.tabID))
            return .ok

        case let .tabInfo(ref):
            let resolved = try resolver.resolveTab(ref)
            return .data(
                .tabInfo(
                tabInfoPayload(
                resolved: resolved,
                callerSessionID: origin.sessionID
            )
                )
                )

        case let .moveTab(ref, toIndex, toWindowRef):
            let resolved = try resolver.resolveTab(ref)
            // Cross-window move when a distinct destination window is
            // named; otherwise a same-window reorder.
            if let toWindowRef {
                let destWindowID = try resolver.resolveWindow(toWindowRef)
                let destCount = workspace.window(id: destWindowID)?.tabs.tabs.count ?? 0
                if destWindowID == resolved.windowID {
                    // `--to-window` resolved to the tab's own window: this
                    // is a same-window reorder, which requires an explicit
                    // `--to <index>`. Don't silently slide the tab to the
                    // end when it's omitted.
                    guard let toIndex else {
                        throw IntentError.internalError(
                            "tab move within the same window needs --to <index>"
                        )
                    }
                    let raw = rawTabIndex(visibleIndex: toIndex, in: destWindowID, origin: origin)
                    router.dispatch(.reorderTab(destWindowID, resolved.tabID, toIndex: raw))
                    return .ok
                }
                guard let delegate = actionDelegate else {
                    throw IntentError.internalError(
                        "no IntentActionDelegate wired for moveTab"
                    )
                }
                // Map the caller's visible-projection index into the raw
                // model so a foreign-protected tab in the destination can't
                // shift where the moved tab lands; a nil index appends.
                let atIndex = toIndex
                    .map { rawTabIndex(visibleIndex: $0, in: destWindowID, origin: origin) }
                    ?? destCount
                delegate.moveTabAcrossWindows(
                    resolved.tabID,
                    from: resolved.windowID,
                    to: destWindowID,
                    atIndex: atIndex
                )
                return .ok
            }
            guard let toIndex else {
                throw IntentError.internalError(
                    "tab move needs --to <index> or --to-window <ref>"
                )
            }
            let raw = rawTabIndex(visibleIndex: toIndex, in: resolved.windowID, origin: origin)
            router.dispatch(.reorderTab(resolved.windowID, resolved.tabID, toIndex: raw))
            return .ok

        case let .openPaneTerminal(tabRef, cwd, cmd):
            // Add an additional terminal pane to the named (or
            // current) tab. `--cwd` overrides the shell's startup
            // CWD; `--cmd '<cmd>'` is typed into the shell as
            // initial input. When the resolver can't find the named
            // tab, surface notFound; with no ref + no current tab,
            // fall back to opening a fresh window+tab (matches the
            // "you asked to open a terminal, here's a place to do
            // it" affordance), cwd/cmd silently drop on that
            // fallback because openWindow has no surface for them,
            // which is fine: the fresh window's primary tab
            // is the intended `tab open` shape, not `pane open`.
            if let ref = tabRef {
                let resolved = try resolver.resolveTab(ref)
                // With `--tab` omitted the resolver returns the caller's
                // own tab, so only the named form can land outside it.
                try requireAuthority(
                    "pane open",
                    over: resolved.tab,
                    requirement: .ownership,
                    origin: origin
                )
                router.dispatch(
                    .openTerminalPane(tab: resolved.tabID, cwd: cwd, cmd: cmd)
                )
                return .ok
            }
            do {
                let current = try resolver.resolveTab(.current)
                router.dispatch(
                    .openTerminalPane(tab: current.tabID, cwd: cwd, cmd: cmd)
                )
            } catch IntentError.notFound {
                router.dispatch(.openWindow())
            }
            return .ok

        case let .closePane(ref, mode):
            let resolved = try resolver.resolveSimPane(ref)
            // Gated on the host tab, and that is the whole of it. The
            // daemon's pane-ownership check binds a session calling
            // `pane.closeById` directly, but the Router reaches that
            // method as the validated GUI, a principal that spans
            // sessions by design, so nothing downstream re-checks who
            // owns this pane: a co-tenant of the tab can close a pane
            // it can't drive. A pane whose host tab vanished between
            // resolution and here is a refusal, not a bypass.
            guard let host = hostTab(of: resolved) else {
                throw IntentError.notFound(kind: "pane", ref: "close")
            }
            try requireAuthority(
                "pane close",
                over: host,
                requirement: .ownership,
                origin: origin
            )
            router.dispatch(
                .detachSimPane(
                tab: resolved.tabID,
                udid: resolved.pane.udid,
                mode: mode
            )
                )
            return .ok

        case .renamePane:
            throw IntentError.internalError(
                "pane rename is not implemented"
            )

        case let .paneInfo(ref):
            let resolved = try resolver.resolveSimPane(ref)
            return .data(.paneInfo(paneInfoPayload(resolved: resolved)))

        case .movePane:
            throw IntentError.internalError(
                "pane move is not implemented"
            )

        case let .paneAttach(udid):
            // Claim an already-booted sim (booted outside deviceterm,
            // booted via a shim-bypassing path, or left orphaned by
            // a closed session) into the caller's current tab. Reuses
            // the existing `Route.attachSimPane` pipeline that
            // discovery / orphan-recovery / shim-intercept boot all
            // funnel through: one mounting path. The Router calls
            // `daemon.attachDevice`, which transfers ownership and
            // returns the IOSurface handle; the GUI then mounts the
            // sim pane in the resolved tab.
            //
            // UUIDs are case-insensitive and `simctl list` prints
            // them uppercase, so this argument arrives in either
            // case while the mounted panes carry the daemon's
            // lowercase. Canonicalize the input first
            // and walk pane comparisons case-insensitively so
            // repeated calls with different casing don't slip past
            // the duplicate guards and double-attach the same sim.
            // Malformed input (not a UUID) fails fast here with a
            // user-visible hint rather than the daemon's terser
            // `malformed UDID` error after a round-trip.
            guard let canonicalUDID = UUID(uuidString: udid)?
                .uuidString.lowercased() else {
                throw IntentError.internalError(
                    "udid \(udid) is not a valid UUID; check the "
                    + "value with `deviceterm device list`"
                )
            }
            let resolved = try resolver.resolveTab(.current)
            // Idempotent within the same tab: repeated calls are
            // a no-op rather than stacking duplicate panes.
            if resolved.tab.simPanes.contains(
                where: {
                $0.udid.caseInsensitiveCompare(canonicalUDID) == .orderedSame
                }
                ) {
                return .ok
            }
            // Reject if the udid is already attached to a different
            // tab. The locked linkage design reserves cross-tab pane
            // movement to the human (via GUI drag); a CLI `pane
            // attach` from the wrong tab is a likely user error, not
            // a relink request. Stealing the pane via a second
            // `device.attach` would also create a duplicate pane
            // record in the daemon and break the original tab's
            // stream, so it has to be a hard reject. Case-insensitive
            // walk so the check is symmetric with the same-tab guard.
            // Scope the cross-tab scan to tabs the caller may see. An
            // external caller must not learn (via the differentiated
            // "already attached to a different tab" error) that a UDID
            // lives in a foreign protected tab.
            let attachedElsewhere = visibleTabs(for: origin).contains { tab in
                tab.simPanes.contains {
                    $0.udid.caseInsensitiveCompare(canonicalUDID) == .orderedSame
                }
            }
            if attachedElsewhere {
                throw IntentError.internalError(
                    "udid \(canonicalUDID) is already attached to a "
                    + "different tab; move it via GUI drag rather "
                    + "than `pane attach` from another tab"
                )
            }
            // Pass the canonical form to Router so the SimPaneState
            // we create stores it consistently: future `pane attach`
            // calls from the same tab will see the lowercased value
            // and the same-tab guard short-circuits without needing
            // a case-insensitive compare.
            //
            // `displayName: nil` asks the Router to resolve the real
            // device name via `daemon.deviceList` rather than passing
            // a UDID-prefix placeholder: `pane attach` is the only
            // mounting path without a pre-fetched name in hand
            // (discovery / shim-intercept / orphan re-attach all
            // populate the name from their own deviceList snapshots).
            router.dispatch(
                .attachSimPane(
                tab: resolved.tabID,
                udid: canonicalUDID,
                displayName: nil
            )
                )
            return .ok

        case let .devicePaneAttach(deviceId, relinkExisting):
            // Mount a physically-connected device into the caller's
            // current tab: the `.device` arm of `device attach <ref>`
            // and the shim's contextual auto-attach. Idempotent within the
            // tab. When the device is already mirrored in a *different*
            // tab, behavior splits by intent: the explicit CLI verb
            // (`relinkExisting == false`) rejects: one mirror per device,
            // cross-tab moves are a deliberate GUI drag, not a CLI relink;
            // the contextual shim trigger (`relinkExisting == true`) moves
            // the mirror here, because a `devicectl install`/`launch` is
            // strong evidence the active device context is now this tab.
            // `deviceId` is the physical device's stable CoreDevice UDID;
            // preserve it exactly. `displayName: nil` lets the Router
            // compose from the attach response.
            let resolved = try resolver.resolveTab(.current)
            if resolved.tab.devicePanes.contains(where: { $0.deviceId == deviceId }) {
                return .ok
            }
            // Only consider tabs the caller may see: a device mirrored in
            // a foreign protected tab is invisible here, so an external
            // caller can neither probe it via the reject error nor detach
            // it via the shim relink path.
            let owningTabID = visibleTabs(for: origin).first {
                $0.devicePanes.contains { $0.deviceId == deviceId }
            }?.id
            if let owningTabID {
                guard relinkExisting else {
                    throw IntentError.internalError(
                        "device \(deviceId) is already mirrored in a "
                        + "different tab; move it via GUI drag rather "
                        + "than `device attach` from another tab"
                    )
                }
                // Rehome latest-wins. The serial router drain handles the
                // detach before the attach, so the old mirror is gone
                // before the new one mounts (the device itself keeps
                // running, `.detach` only drops the mirror, never powers
                // it off).
                router.dispatch(
                    .detachDevicePane(
                        tab: owningTabID,
                        deviceId: deviceId,
                        mode: .detach
                    )
                )
            }
            router.dispatch(
                .attachDevicePane(
                    tab: resolved.tabID,
                    deviceId: deviceId,
                    displayName: nil
                )
            )
            return .ok

        case let .sendInput(ref, text, typeDelayMillis):
            let resolved = try resolver.resolveTab(ref)
            guard let delegate = actionDelegate else {
                throw IntentError.internalError(
                    "no IntentActionDelegate wired for sendInput"
                )
            }
            do {
                try delegate.sendInput(
                    window: resolved.windowID,
                    tab: resolved.tabID,
                    text: text,
                    typeDelayMillis: typeDelayMillis
                )
            } catch let error as IntentError {
                throw error
            } catch {
                throw IntentError.internalError(
                    "sendInput failed: \(error)"
                )
            }
            return .ok

        case let .captureTab(ref):
            let resolved = try resolver.resolveTab(ref)
            guard let delegate = actionDelegate else {
                throw IntentError.internalError(
                    "no IntentActionDelegate wired for captureTab"
                )
            }
            let text: String
            do {
                text = try delegate.captureTab(
                    window: resolved.windowID,
                    tab: resolved.tabID
                )
            } catch let error as IntentError {
                throw error
            } catch {
                throw IntentError.internalError(
                    "captureTab failed: \(error)"
                )
            }
            return .data(.tabCapture(TabCapturePayload(text: text)))

        case let .setTabProtected(ref, isProtected):
            let resolved = try resolver.resolveTab(ref)
            // Owner gate by origin. In-process (the human at the keyboard)
            // always passes: the resolver already refused a foreign
            // protected tab. An external caller may flip protection only on a
            // tab it owns a terminal in; a nil-session external caller
            // (no authority) is refused. This is the one gate that must
            // key on *source*, not session-presence: the human toggling
            // the menu passes a nil session too, but is `.inProcess`.
            switch origin {
            case .inProcess:
                break

            case let .external(sessionID, _):
                let isOwner = sessionID.map { sid in
                    resolved.tab.terminals.contains { $0.sessionId == sid }
                } ?? false
                guard isOwner else {
                    throw IntentError.notFound(kind: "tab", ref: "set-protected")
                }
            }
            // Await the transition's first decisive outcome so the caller
            // learns the daemon's real state, not an optimistic echo: an ack
            // is committed. Pending means the requested protection state has not
            // yet been confirmed; definite refusal or opposite-state
            // supersession returns failure.
            let outcome = await router.applyTabProtection(
                tab: resolved.tabID,
                isProtected: isProtected
            )
            switch outcome {
            case .committed:
                return .data(.tabSetProtected(
                    TabSetProtectedResult(isProtected: isProtected, committed: true)
                ))

            case .pending:
                return .data(.tabSetProtected(
                    TabSetProtectedResult(isProtected: isProtected, committed: false)
                ))

            case .rejected:
                return .error(.internalError(
                    "tab set-protected was rejected (daemon refused it, "
                    + "or a newer protection change superseded it)"
                ))
            }
        }
    }

    // MARK: - Payload builders

    /// `callerSessionID` is the origin's session (CLI back-channel: the
    /// calling tab; in-process menu: nil). A `deviceterm tab info` from
    /// inside a tab reports `isCurrent: true` for its own row.
    private func tabInfoPayload(
        resolved: ResolvedTab,
        callerSessionID: String?
    ) -> TabInfoPayload {
        // Multi-terminal-pane: a CLI call from any terminal inside
        // the resolved tab should report `isCurrent: true` for its
        // own row, so match against the full terminal set rather
        // than just the primary's session.
        let isCurrent: Bool
        if let sid = callerSessionID {
            isCurrent = resolved.tab.terminals.contains(where: { $0.sessionId == sid })
        } else {
            isCurrent = false
        }
        let simPanes = resolved.tab.simPanes.map {
            SimPanePayload(
                paneId: $0.paneId,
                udid: $0.udid,
                shortId: $0.shortId,
                displayName: $0.displayName,
                family: $0.family
            )
        }
        // `sessionId` in the tab-info payload reports the primary
        // terminal's session: backward-compat for consumers that
        // expected a single tab session. Per-terminal session
        // enumeration is a future field on the payload (the wire
        // type's Optional shape leaves room without breaking
        // existing parsers).
        return TabInfoPayload(
            sessionId: resolved.tab.primaryTerminal.sessionId,
            shortId: resolved.tab.primaryTerminal.shortId,
            name: resolved.tab.primaryTerminal.name,
            role: resolved.tab.role.rawValue,
            cwd: nil,
            label: nil,
            isCurrent: isCurrent,
            simPanes: simPanes
        )
    }

    private func paneInfoPayload(resolved: ResolvedPane) -> PaneInfoPayload {
        // Sim panes attribute to the tab's primary terminal. A
        // future refinement will route ownership to the specific
        // terminal session whose shell ran `xcrun simctl boot`
        // (resolved via shim intercept).
        let linkedSessionID = workspace
            .window(id: resolved.windowID)?
            .tabs.tab(id: resolved.tabID)?
            .primaryTerminal.sessionId ?? ""
        return PaneInfoPayload(
            paneId: resolved.pane.paneId,
            udid: resolved.pane.udid,
            shortId: resolved.pane.shortId,
            name: resolved.pane.name,
            displayName: resolved.pane.displayName,
            family: resolved.pane.family,
            linkedSessionId: linkedSessionID
        )
    }

    /// `includeAll == true` returns the visible-window projection;
    /// `includeAll == false` scopes to the caller's window. Counts,
    /// indices, and selected short ids are all computed over the tabs the
    /// caller may see: a window holding only foreign-protected tabs
    /// disappears entirely (no entry, no index, no count), and the
    /// selected short id is never a tab the caller can't see. In-process
    /// callers see everything.
    ///
    /// `--all` is not role-gated: any caller can ask for it, and the
    /// visibility filter is what bounds the answer.
    private func windowsListPayload(
        includeAll: Bool,
        origin: IntentOrigin
    ) -> [WindowInfoPayload] {
        let restrict = origin.restrictsToVisibleTabs
        let caller = origin.sessionID
        func visibleTabs(_ window: WindowState) -> [TabState] {
            guard restrict else { return window.tabs.tabs }
            return window.tabs.tabs.filter {
                IntentResolver.externallyAccessible($0, callerSessionID: caller)
            }
        }
        // Index is the position in the *visible* projection, so a hidden
        // window never shifts a number an external caller can observe.
        var entries: [(windowID: WindowID, payload: WindowInfoPayload)] = []
        for window in workspace.windows {
            let visible = visibleTabs(window)
            if restrict, visible.isEmpty { continue }
            let selectedShortId: String? = {
                guard let sIdx = window.tabs.selectedIndex,
                    let selected = window.tabs.tabs[safe: sIdx] else { return nil }
                if !restrict
                    || IntentResolver.externallyAccessible(selected, callerSessionID: caller) {
                    return selected.primaryTerminal.shortId
                }
                // The selected tab is hidden from this caller: name the
                // first visible tab rather than nil, so a hidden selection
                // isn't observable as "nil-selected in a non-empty window."
                return visible.first?.primaryTerminal.shortId
            }()
            entries.append((
                window.id,
                WindowInfoPayload(
                    index: entries.count + 1,
                    // Projected key window: mark the frontmost window as key
                    // only when it's in the caller's visible set. For the
                    // interactive human, their key window always contains a
                    // tab they own, so `*` still shows; a protected-only key
                    // window (visible to nobody but its owner) simply isn't
                    // marked for others. This keeps the documented `*`
                    // semantics working while never exposing which
                    // *inaccessible* window is focused.
                    isKey: window.id == workspace.selectedWindowID,
                    tabCount: visible.count,
                    selectedTabShortId: selectedShortId
                )
            ))
        }
        if includeAll { return entries.map(\.payload) }
        guard let caller else { return [] }
        guard let hit = entries.first(where: { entry in
            workspace.window(id: entry.windowID)?.tabs.tabs.contains { tab in
                tab.terminals.contains { $0.sessionId == caller }
            } == true
        }) else { return [] }
        return [hit.payload]
    }

    // MARK: - Helpers

    /// An omitted `--window` resolves through the *origin-aware*
    /// `.current`: in-process opens in the key window; an external caller
    /// opens in its own window (never the human's key window), and a
    /// nil-session external caller is `notFound` rather than a borrow.
    private func resolveOptionalWindow(
        _ ref: WindowRef?,
        resolver: IntentResolver
    ) throws -> WindowID {
        try resolver.resolveWindow(ref ?? .current)
    }

    /// The tabs the origin may see: the same rule the resolver enforces.
    /// Direct workspace scans (the attach ownership checks) must use this
    /// instead of walking `workspace.windows` so an external caller can't
    /// probe or mutate a sim/device inside a foreign protected tab.
    private func visibleTabs(for origin: IntentOrigin) -> [TabState] {
        let all = workspace.windows.flatMap(\.tabs.tabs)
        guard origin.restrictsToVisibleTabs else { return all }
        return all.filter {
            IntentResolver.externallyAccessible($0, callerSessionID: origin.sessionID)
        }
    }

    /// Map an external caller's visible-projection tab index in a window
    /// to a raw `tabs` index, so a foreign-protected tab can't shift where
    /// the caller's index lands. In-process indices pass through
    /// unchanged; an index at/after the visible end maps to the raw end.
    private func rawTabIndex(visibleIndex: Int, in windowID: WindowID, origin: IntentOrigin) -> Int {
        guard case let .external(sessionID, _) = origin,
            let window = workspace.window(id: windowID) else { return visibleIndex }
        // Clamp to the front like `TabListViewModel.move` does, so a
        // negative visible index lands at position 0 rather than appending.
        let wanted = max(0, visibleIndex)
        var seen = 0
        for (raw, tab) in window.tabs.tabs.enumerated() {
            guard IntentResolver.externallyAccessible(tab, callerSessionID: sessionID) else {
                continue
            }
            if seen == wanted { return raw }
            seen += 1
        }
        return window.tabs.tabs.count
    }

    /// A resolved tab reduced to what `WorkspaceAuthorityDecision`
    /// needs. Ownership is per *session*, not per tab: a split tab's
    /// terminals each carry their own session, so the caller owns the
    /// tab only when one of them is its own.
    private func authorityTarget(
        for tab: TabState,
        origin: IntentOrigin
    ) -> WorkspaceAuthorityTarget {
        let owns = origin.sessionID.map { sessionID in
            tab.terminals.contains { $0.sessionId == sessionID }
        } ?? false
        return WorkspaceAuthorityTarget(
            callerOwnsIt: owns,
            terminalCount: tab.terminals.count
        )
    }

    /// Refuse unless the caller may act on `tab`. Every cross-tab verb
    /// calls this **after** resolution, so a foreign protected tab has
    /// already failed as `notFound` and can't be distinguished here.
    private func requireAuthority(
        _ verb: String,
        over tab: TabState,
        requirement: WorkspaceAuthorityRequirement,
        origin: IntentOrigin
    ) throws {
        let decision = WorkspaceAuthorityDecision.decide(
            origin: origin,
            requirement: requirement,
            target: authorityTarget(for: tab, origin: origin)
        )
        guard decision == .allowed else {
            throw IntentError.automationRequired(verb: verb)
        }
    }

    /// The membership an authorization was computed over, handed to the
    /// Router so it can confirm nothing moved before the close runs.
    /// Nil when authority doesn't depend on membership: the human at the
    /// keyboard, or a caller holding a live grant. Only an ungranted
    /// external caller is cleared *because* of which sessions the tabs
    /// hold, so only it needs the re-check.
    private func authorizedTerminals(
        _ tabs: [TabState],
        origin: IntentOrigin
    ) -> Set<String>? {
        guard case let .external(_, hasAutomationGrant) = origin,
            !hasAutomationGrant else { return nil }
        return Set(tabs.flatMap { $0.terminals.map(\.sessionId) })
    }

    /// The tab hosting a resolved pane, for the pane verbs that gate on
    /// their host tab's ownership.
    private func hostTab(of pane: ResolvedPane) -> TabState? {
        workspace.window(id: pane.windowID)?.tabs.tab(id: pane.tabID)
    }

    /// Whether `windowID` hosts any tab the external caller can't see.
    /// Always false for `.inProcess` (the human owns the workspace).
    ///
    /// This gates `window.close`: closing a shared window would tear down
    /// a co-hosted foreign protected tab. The refuse-vs-succeed difference is
    /// a *minor* 1-bit oracle ("this visible window also holds a hidden
    /// tab"), deliberately accepted as far less harmful than letting an
    /// external caller destroy another session's protected tab. (A perfectly
    /// oracle-free fix (partial close of only the caller's tabs) is out
    /// of scope for the rare cross-session co-hosting case.)
    private func windowHoldsForeignTab(_ windowID: WindowID, origin: IntentOrigin) -> Bool {
        guard case let .external(sessionID, _) = origin,
            let window = workspace.window(id: windowID) else { return false }
        return window.tabs.tabs.contains {
            !IntentResolver.externallyAccessible($0, callerSessionID: sessionID)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
