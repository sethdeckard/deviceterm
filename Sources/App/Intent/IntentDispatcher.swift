// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The single consumer of external `RouteIntent` values translated from the
/// CLI back-channel. In-process AppKit actions already hold concrete GUI IDs
/// and dispatch `Route` values directly.
///
/// Responsibilities:
///   1. Resolve external refs to GUI IDs via `IntentResolver`.
///   2. Translate the resolved intent into `Route`(s) the Router can
///      execute, read inline from the workspace for read-only intents, or call
///      an injected `IntentActionDelegate` for committed GUI state that does
///      not fit the Route shape.
///   3. Return a typed `IntentResult` the source layer renders.
///
/// Pattern notes:
///   - Mutations await the Router/delegate commit and return the projected
///     objects in a `WorkspaceMutationReceipt`.
///   - Read-only intents synthesize their payload from current workspace state
///     and return immediately. No Router involvement.
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
        } catch let error as PaneAttachFailure {
            return .error(
                .attachFailed(
                    message: error.message,
                    forwardedRPCCode: error.rpcCode
                )
            )
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
        case .workspaceWindowList,
            .workspaceWindowShow,
            .workspaceWindowOpen,
            .workspaceWindowFocus,
            .workspaceWindowClose,
            .workspaceTabList,
            .workspaceTabShow,
            .workspaceTabOpen,
            .workspaceTabFocus,
            .workspaceTabClose,
            .workspaceTabRename,
            .workspaceTabMove,
            .workspaceTabProtect,
            .workspacePaneList,
            .workspacePaneShow,
            .workspacePaneSplit,
            .workspacePaneFocus,
            .workspacePaneClose,
            .workspacePaneRename,
            .workspacePaneSendInput,
            .workspacePaneCaptureText:
            return try await handleWorkspace(
                intent,
                resolver: resolver,
                origin: origin
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
                    + "value with `deviceterm devices list`"
                )
            }
            let resolved = try resolver.resolveTab(nil)
            // Idempotent within the same tab: repeated calls are
            // a no-op rather than stacking duplicate panes.
            if resolved.tab.simPanes.contains(
                where: {
                $0.udid.caseInsensitiveCompare(canonicalUDID) == .orderedSame
                }
                ) {
                guard let pane = resolved.tab.simPanes.first(where: {
                    $0.udid.caseInsensitiveCompare(canonicalUDID) == .orderedSame
                }) else {
                    throw IntentError.internalError("attached Simulator pane disappeared")
                }
                return try workspaceAttachReceipt(
                    paneID: pane.paneId,
                    tabID: resolved.tabID,
                    projection: WorkspaceProjection(
                        workspace: workspace,
                        resolver: resolver,
                        origin: origin,
                        actionDelegate: actionDelegate
                    )
                )
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
            try await router.dispatchAndWaitForPaneAttach(
                .attachSimPane(
                    tab: resolved.tabID,
                    udid: canonicalUDID,
                    displayName: nil
                ),
                tab: resolved.tabID,
                target: .sim(udid: canonicalUDID)
            )
            let attachedTab = workspace.windowContaining(tab: resolved.tabID)?
                .tabs.tab(id: resolved.tabID)
            guard let pane = attachedTab?.simPanes.first(where: {
                $0.udid.caseInsensitiveCompare(canonicalUDID) == .orderedSame
            }) else {
                throw IntentError.internalError("Simulator pane attach did not commit a pane")
            }
            return try workspaceAttachReceipt(
                paneID: pane.paneId,
                tabID: resolved.tabID,
                projection: WorkspaceProjection(
                    workspace: workspace,
                    resolver: resolver,
                    origin: origin,
                    actionDelegate: actionDelegate
                )
            )

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
            let resolved = try resolver.resolveTab(nil)
            if let pane = resolved.tab.devicePanes.first(where: { $0.deviceId == deviceId }) {
                return try workspaceAttachReceipt(
                    paneID: pane.paneId,
                    tabID: resolved.tabID,
                    projection: WorkspaceProjection(
                        workspace: workspace,
                        resolver: resolver,
                        origin: origin,
                        actionDelegate: actionDelegate
                    )
                )
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
                await router.dispatchAndWait(
                    .detachDevicePane(
                        tab: owningTabID,
                        deviceId: deviceId,
                        mode: .detach
                    )
                )
            }
            try await router.dispatchAndWaitForPaneAttach(
                .attachDevicePane(
                    tab: resolved.tabID,
                    deviceId: deviceId,
                    displayName: nil
                ),
                tab: resolved.tabID,
                target: .device(deviceId: deviceId)
            )
            let attachedTab = workspace.windowContaining(tab: resolved.tabID)?
                .tabs.tab(id: resolved.tabID)
            guard let pane = attachedTab?.devicePanes.first(where: {
                $0.deviceId == deviceId
            }) else {
                throw IntentError.internalError("physical-device pane attach did not commit a pane")
            }
            return try workspaceAttachReceipt(
                paneID: pane.paneId,
                tabID: resolved.tabID,
                projection: WorkspaceProjection(
                    workspace: workspace,
                    resolver: resolver,
                    origin: origin,
                    actionDelegate: actionDelegate
                )
            )
        }
    }

    // MARK: - Public workspace CLI

    private func handleWorkspace(
        _ intent: RouteIntent,
        resolver: IntentResolver,
        origin: IntentOrigin
    ) async throws -> IntentResult {
        let projection = WorkspaceProjection(
            workspace: workspace,
            resolver: resolver,
            origin: origin,
            actionDelegate: actionDelegate
        )
        switch intent {
        case let .workspaceWindowList(all):
            return .data(.workspaceWindows(try projection.windows(includeAll: all)))

        case let .workspaceWindowShow(ref):
            return .data(.workspaceWindow(try projection.window(ref)))

        case .workspaceWindowOpen:
            let before = Set(workspace.windows.map(\.id))
            await router.dispatchAndWait(.openWindow())
            guard let opened = workspace.windows.first(where: { !before.contains($0.id) }) else {
                throw IntentError.internalError("window open did not commit a window")
            }
            let detail = try projection.window(publicRef(opened))
            let committed = receipt(for: detail, projection: projection)
            if let failed = opened.tabs.tabs.first(where: { $0.lifecycle == .failed }) {
                throw IntentError.mutationFailed(
                    message: failed.failureMessage ?? "terminal session creation failed",
                    committed: committed
                )
            }
            return .data(.workspaceMutation(committed))

        case let .workspaceWindowFocus(ref):
            let windowID = try resolver.resolveWindow(ref)
            guard let delegate = actionDelegate,
                let window = workspace.window(id: windowID) else {
                throw IntentError.internalError("no live window focus target")
            }
            workspace.select(id: windowID)
            delegate.raiseWindow(windowID)
            let detail = try projection.window(publicRef(window))
            return .data(.workspaceMutation(receipt(for: detail, projection: projection)))

        case let .workspaceWindowClose(ref, mode):
            let windowID = try resolver.resolveWindow(ref)
            if windowHoldsForeignTab(windowID, origin: origin) {
                throw IntentError.notFound(kind: "window", ref: ref ?? "current")
            }
            guard let window = workspace.window(id: windowID) else {
                throw IntentError.notFound(kind: "window", ref: ref ?? "current")
            }
            let held = window.tabs.tabs
            for tab in held {
                try requireAuthority(
                    "window close",
                    over: tab,
                    requirement: .soleTerminal,
                    origin: origin
                )
            }
            let closed = try projection.window(publicRef(window)).window
            await router.dispatchAndWait(
                .closeWindow(
                    windowID,
                    mode: paneCloseMode(mode),
                    authorizedTerminals: authorizedTerminals(held, origin: origin)
                )
            )
            guard workspace.window(id: windowID) == nil else {
                throw IntentError.internalError("window close was not committed")
            }
            return .data(.workspaceMutation(.init(
                closed: .init(resource: "window", window: closed),
                mode: mode
            )))

        case let .workspaceTabList(window, all):
            return .data(.workspaceTabs(try projection.tabs(window: window, all: all)))

        case let .workspaceTabShow(ref):
            return .data(.workspaceTab(try projection.tab(ref)))

        case let .workspaceTabOpen(windowRef, cwd, command):
            let windowID = try resolver.resolveWindow(windowRef)
            guard let window = workspace.window(id: windowID) else {
                throw IntentError.notFound(kind: "window", ref: windowRef ?? "current")
            }
            let before = Set(window.tabs.tabs.map(\.id))
            await router.dispatchAndWait(.newTab(windowID, cwd: cwd, cmd: command))
            guard let opened = workspace.window(id: windowID)?.tabs.tabs.first(
                where: { !before.contains($0.id) }
            ) else {
                throw IntentError.internalError("tab open did not commit a tab")
            }
            let detail = try projection.tab(
                publicRef(opened),
                includeTerminalCWD: false
            )
            let projectedWindow = try projection.window(publicRef(window)).window
            let committed = WorkspaceMutationReceipt(
                window: projectedWindow,
                tab: detail.tab,
                pane: detail.panes.first
            )
            if opened.lifecycle == .failed {
                throw IntentError.mutationFailed(
                    message: opened.failureMessage ?? "terminal session creation failed",
                    committed: committed
                )
            }
            return .data(.workspaceMutation(committed))

        case let .workspaceTabFocus(ref):
            let resolved = try resolver.resolveTab(ref)
            await router.dispatchAndWait(.selectTab(resolved.windowID, resolved.tabID))
            workspace.select(id: resolved.windowID)
            actionDelegate?.raiseWindow(resolved.windowID)
            let window = try projection.window(publicWindowRef(resolved.windowID)).window
            let tab = try projection.tabSummary(publicRef(resolved.tab))
            return .data(.workspaceMutation(.init(window: window, tab: tab)))

        case let .workspaceTabClose(ref, mode):
            let resolved = try resolver.resolveTab(ref)
            try requireAuthority(
                "tab close",
                over: resolved.tab,
                requirement: .soleTerminal,
                origin: origin
            )
            let closed = try projection.tabSummary(publicRef(resolved.tab))
            await router.dispatchAndWait(
                .closeTab(
                    resolved.windowID,
                    resolved.tabID,
                    mode: paneCloseMode(mode),
                    authorizedTerminals: authorizedTerminals([resolved.tab], origin: origin)
                )
            )
            guard workspace.windowContaining(tab: resolved.tabID) == nil else {
                throw IntentError.internalError("tab close was not committed")
            }
            return .data(.workspaceMutation(.init(
                closed: .init(resource: "tab", tab: closed),
                mode: mode
            )))

        case let .workspaceTabRename(ref, name):
            let resolved = try resolver.resolveTab(ref)
            try requireAuthority(
                "tab rename",
                over: resolved.tab,
                requirement: .ownership,
                origin: origin
            )
            workspace.window(id: resolved.windowID)?.tabs.renameTab(id: resolved.tabID, to: name)
            actionDelegate?.renameTab(
                window: resolved.windowID,
                tab: resolved.tabID,
                to: name
            )
            let tab = try projection.tabSummary(publicRef(resolved.tab))
            return .data(.workspaceMutation(.init(tab: tab)))

        case let .workspaceTabMove(ref, destinationRef, index):
            let resolved = try resolver.resolveTab(ref)
            let destinationID = try resolver.resolveWindow(destinationRef)
            if destinationID == resolved.windowID {
                guard let index else {
                    throw IntentError.internalError(
                        "tab move within the same window needs --index <index>"
                    )
                }
                let raw = rawTabIndex(
                    visibleIndex: index,
                    in: destinationID,
                    origin: origin
                )
                await router.dispatchAndWait(
                    .reorderTab(destinationID, resolved.tabID, toIndex: raw)
                )
            } else {
                guard let delegate = actionDelegate,
                    let destination = workspace.window(id: destinationID) else {
                    throw IntentError.notFound(kind: "window", ref: destinationRef)
                }
                delegate.moveTabAcrossWindows(
                    resolved.tabID,
                    from: resolved.windowID,
                    to: destinationID,
                    atIndex: rawTabIndex(
                        visibleIndex: index ?? destination.tabs.tabs.count,
                        in: destinationID,
                        origin: origin
                    )
                )
            }
            guard let movedWindow = workspace.windowContaining(tab: resolved.tabID),
                movedWindow.id == destinationID,
                let moved = movedWindow.tabs.tab(id: resolved.tabID) else {
                throw IntentError.internalError("tab move was not committed in the destination window")
            }
            let tab = try projection.tabSummary(publicRef(moved))
            let window = try projection.window(publicRef(movedWindow)).window
            return .data(.workspaceMutation(.init(window: window, tab: tab)))

        case let .workspaceTabProtect(ref, isProtected):
            let resolved = try resolver.resolveTab(ref)
            try requireAuthority(
                isProtected ? "tab protect" : "tab unprotect",
                over: resolved.tab,
                requirement: .ownership,
                origin: origin
            )
            let outcome = await router.applyTabProtection(
                tab: resolved.tabID,
                isProtected: isProtected
            )
            guard outcome == .committed else {
                throw IntentError.internalError(
                    outcome == .pending
                        ? "tab protection is still pending"
                        : "tab protection was rejected"
                )
            }
            let tab = try projection.tabSummary(publicRef(resolved.tab))
            return .data(.workspaceMutation(.init(tab: tab)))

        case let .workspacePaneList(tab):
            return .data(.workspacePanes(try projection.panes(tab: tab)))

        case let .workspacePaneShow(ref):
            return .data(.workspacePane(try projection.pane(ref)))

        case let .workspacePaneSplit(ref, direction):
            let resolved = try resolver.resolveWorkspacePane(ref)
            guard let tab = workspace.window(id: resolved.windowID)?.tabs.tab(id: resolved.tabID) else {
                throw IntentError.notFound(kind: "tab", ref: "pane host")
            }
            try requireAuthority(
                "pane split",
                over: tab,
                requirement: .ownership,
                origin: origin
            )
            let before = Set(tab.terminals.map(\.id))
            await router.dispatchAndWait(
                .openTerminalPane(
                    tab: resolved.tabID,
                    anchor: resolved.slot,
                    axis: direction.isHorizontal ? .horizontal : .vertical,
                    side: direction.isBefore ? .before : .after
                )
            )
            let liveTab = workspace.windowContaining(tab: resolved.tabID)?
                .tabs.tab(id: resolved.tabID)
            guard let opened = liveTab?.terminals.first(
                where: { !before.contains($0.id) }
            ) else {
                throw IntentError.internalError("pane split did not commit a terminal pane")
            }
            let pane = try projection.pane(
                opened.sessionId,
                includeTerminalCWD: false
            )
            let tabReceipt = try projection.tabSummary(publicTabRef(resolved.tabID))
            return .data(.workspaceMutation(.init(tab: tabReceipt, pane: pane)))

        case let .workspacePaneFocus(ref):
            let resolved = try resolver.resolveWorkspacePane(ref)
            await router.dispatchAndWait(.selectTab(resolved.windowID, resolved.tabID))
            workspace.select(id: resolved.windowID)
            actionDelegate?.raiseWindow(resolved.windowID)
            actionDelegate?.focusPane(
                window: resolved.windowID,
                tab: resolved.tabID,
                slot: resolved.slot
            )
            let pane = projection.project(resolved, includeTerminalCWD: false)
            let tab = try projection.tabSummary(publicTabRef(resolved.tabID))
            let window = try projection.window(publicWindowRef(resolved.windowID)).window
            return .data(.workspaceMutation(.init(window: window, tab: tab, pane: pane)))

        case let .workspacePaneClose(ref, mode):
            let resolved = try resolver.resolveWorkspacePane(ref)
            guard let tab = workspace.window(id: resolved.windowID)?.tabs.tab(id: resolved.tabID) else {
                throw IntentError.notFound(kind: "tab", ref: "pane host")
            }
            try requirePaneMutationAuthority(
                "pane close",
                pane: resolved,
                hostTab: tab,
                origin: origin
            )
            let closed = projection.project(resolved, includeTerminalCWD: false)
            if mode != nil {
                switch resolved.state {
                case .terminal:
                    throw IntentError.unsupportedPane(
                        verb: "close --mode",
                        kind: .terminal
                    )

                case .device:
                    throw IntentError.unsupportedPane(
                        verb: "close --mode",
                        kind: .device
                    )

                case .simulator:
                    break
                }
            }
            let selectedMode = mode ?? .detach
            switch resolved.state {
            case let .terminal(terminal):
                guard tab.terminals.count > 1 else { throw IntentError.wouldCloseTab }
                await router.dispatchAndWait(
                    .closeTerminalPane(
                        tab: resolved.tabID,
                        terminal: terminal.id,
                        mode: paneCloseMode(selectedMode)
                    )
                )

            case let .simulator(pane):
                await router.dispatchAndWait(
                    .detachSimPane(
                        tab: resolved.tabID,
                        udid: pane.udid,
                        mode: paneCloseMode(selectedMode)
                    )
                )

            case let .device(pane):
                await router.dispatchAndWait(
                    .detachDevicePane(
                        tab: resolved.tabID,
                        deviceId: pane.deviceId,
                        mode: paneCloseMode(selectedMode)
                    )
                )
            }
            do {
                _ = try resolver.resolveWorkspacePane(closed.id)
                throw IntentError.internalError("pane close was not committed")
            } catch IntentError.notFound {
                // Expected committed state.
            }
            return .data(.workspaceMutation(.init(
                closed: .init(resource: "pane", pane: closed),
                mode: selectedMode
            )))

        case let .workspacePaneRename(ref, name):
            let resolved = try resolver.resolveWorkspacePane(ref)
            guard let window = workspace.window(id: resolved.windowID),
                let tab = window.tabs.tab(id: resolved.tabID) else {
                throw IntentError.notFound(kind: "tab", ref: "pane host")
            }
            try requirePaneMutationAuthority(
                "pane rename",
                pane: resolved,
                hostTab: tab,
                origin: origin
            )
            guard let delegate = actionDelegate else {
                throw IntentError.internalError("no pane rename delegate")
            }
            let daemonPaneId: String? = switch resolved.state {
            case .terminal:
                nil

            case let .simulator(pane):
                pane.paneId

            case let .device(pane):
                pane.paneId
            }
            try await delegate.renamePane(
                window: resolved.windowID,
                tab: resolved.tabID,
                slot: resolved.slot,
                daemonPaneId: daemonPaneId,
                to: name
            )
            guard window.tabs.renamePane(resolved.slot, inTab: resolved.tabID, to: name) else {
                throw IntentError.notFound(kind: "pane", ref: resolved.id)
            }
            let pane = try projection.pane(
                resolved.id,
                includeTerminalCWD: false
            )
            return .data(.workspaceMutation(.init(pane: pane)))

        case let .workspacePaneSendInput(ref, text, delay):
            let resolved = try resolver.resolveWorkspacePane(ref)
            guard case let .terminal(terminal) = resolved.state else {
                throw IntentError.unsupportedPane(
                    verb: "send-input",
                    kind: paneKind(resolved)
                )
            }
            guard let delegate = actionDelegate else {
                throw IntentError.internalError("no terminal input delegate")
            }
            try delegate.sendInput(
                window: resolved.windowID,
                tab: resolved.tabID,
                terminal: terminal.id,
                text: text,
                typeDelayMillis: delay
            )
            return .data(.workspaceMutation(.init(
                pane: projection.project(resolved, includeTerminalCWD: false),
                bytes: Data(text.utf8).count,
                typeDelayMs: delay
            )))

        case let .workspacePaneCaptureText(ref, ansi):
            let resolved = try resolver.resolveWorkspacePane(ref)
            guard case let .terminal(terminal) = resolved.state else {
                throw IntentError.unsupportedPane(
                    verb: "capture-text",
                    kind: paneKind(resolved)
                )
            }
            guard let delegate = actionDelegate else {
                throw IntentError.internalError("no terminal capture delegate")
            }
            let text = try delegate.captureTerminal(
                window: resolved.windowID,
                tab: resolved.tabID,
                terminal: terminal.id,
                ansi: ansi
            )
            return .data(.workspaceCapture(.init(
                pane: projection.project(resolved, includeTerminalCWD: false),
                text: text
            )))

        default:
            throw IntentError.internalError("non-workspace intent reached workspace handler")
        }
    }

    // MARK: - Helpers

    private func publicRef(_ window: WindowState) -> String {
        window.publicID.uuidString.lowercased()
    }

    private func publicRef(_ tab: TabState) -> String {
        tab.cohortId.uuidString.lowercased()
    }

    private func publicWindowRef(_ id: WindowID) throws -> String {
        guard let window = workspace.window(id: id) else {
            throw IntentError.notFound(kind: "window", ref: "current")
        }
        return publicRef(window)
    }

    private func publicTabRef(_ id: TabID) throws -> String {
        guard let tab = workspace.windowContaining(tab: id)?.tabs.tab(id: id) else {
            throw IntentError.notFound(kind: "tab", ref: "current")
        }
        return publicRef(tab)
    }

    private func receipt(
        for detail: WorkspaceWindowDetail,
        projection: WorkspaceProjection
    ) -> WorkspaceMutationReceipt {
        let tab = detail.tabs.first(where: \.selected) ?? detail.tabs.first
        let pane = tab.flatMap {
            try? projection.firstPane(
                inTab: $0.id,
                includeTerminalCWD: false
            )
        }
        return WorkspaceMutationReceipt(window: detail.window, tab: tab, pane: pane)
    }

    private func workspaceAttachReceipt(
        paneID: String,
        tabID: TabID,
        projection: WorkspaceProjection
    ) throws -> IntentResult {
        let pane = try projection.pane(
            paneID,
            includeTerminalCWD: false
        )
        let tab = try projection.tabSummary(publicTabRef(tabID))
        return .data(.workspaceMutation(.init(tab: tab, pane: pane)))
    }

    private func paneCloseMode(_ mode: WorkspaceCloseMode) -> PaneCloseMode {
        switch mode {
        case .detach:
            .detach

        case .shutdown:
            .shutdown
        }
    }

    private func paneKind(_ resolved: ResolvedWorkspacePane) -> WorkspacePaneKind {
        switch resolved.state {
        case .terminal:
            .terminal

        case .simulator:
            .simulator

        case .device:
            .device
        }
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

    /// Terminal panes are individual trust units: an ungranted external
    /// caller may mutate only the pane backed by its own session. Mirrored
    /// panes retain tab ownership here and the daemon's cohort authorization
    /// on their pane-targeted request.
    private func requirePaneMutationAuthority(
        _ verb: String,
        pane: ResolvedWorkspacePane,
        hostTab: TabState,
        origin: IntentOrigin
    ) throws {
        guard case let .terminal(terminal) = pane.state else {
            try requireAuthority(
                verb,
                over: hostTab,
                requirement: .ownership,
                origin: origin
            )
            return
        }
        guard case let .external(sessionID, hasAutomationGrant) = origin else {
            return
        }
        guard hasAutomationGrant || sessionID == terminal.sessionId else {
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

private extension WorkspaceSplitDirection {
    var isHorizontal: Bool { self == .left || self == .right }
    var isBefore: Bool { self == .left || self == .up }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
