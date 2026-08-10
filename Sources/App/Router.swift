// SPDX-License-Identifier: GPL-3.0-or-later
//
// Router: the single navigation dispatch point. Every Route is
// enqueued onto a serial drain (one AsyncStream<Route> consumer
// Task), so navigation is ordered and non-reentrant even though
// each handler awaits daemon work. The handler performs the daemon
// *record* operations (session.create, device.attach, pane.close,
// session.close, the shutdown fan-out) and mutates the nav view
// models; the AppKit glue reconciles its controllers (views, the
// session env, and pane subscriptions) to that state. Menu actions,
// the discovery/resurrect loops, and orphan re-attach all dispatch
// here: one path for everything.

import DaemonProtocol
import Foundation

/// The per-backend slice of an optimistic pane attach. The scaffolding
/// around it is identical for sims and physical devices: insert a
/// placeholder leaf the instant the user acts, run the (slow) attach RPC
/// off the serial drain so navigation never freezes, then reconcile with
/// the same cancel / leak-cleanup guards, the same "Name · Type"
/// composition, and the same failure rendering. This carries only what
/// diverges: the resurrect metadata (sim-only), the RPC + its auth model,
/// the name resolution, and the concrete pane build + mount.
private struct PendingAttachSpec {
    let target: PaneTarget
    let displayName: String?
    /// Resurrect metadata: sim-only. Device panes are never persisted or
    /// auto-resurrected, so these are nil for a device attach. Read only at
    /// placeholder-insert time.
    let family: String?
    let atIndex: Int?
    let anchor: ResurrectAnchor?
    /// The attach RPC, given the tab's primary terminal (the
    /// ownership/attribution session). Sim uses the cap-authenticated
    /// `device.attach`; device uses `physicalDevice.attach` (deviceId +
    /// attribution session, no cap). Both return `PaneCreateResponse`.
    let attach: @MainActor (TerminalPaneState) async throws -> PaneCreateResponse
    /// Resolve the bare device name. Sim does an async `device.list` lookup
    /// when the caller passed no name (the CLI claim path); device reads the
    /// response's marketing name. Both fall back to a `target`-prefix
    /// placeholder.
    let resolveName: @MainActor (PaneCreateResponse) async -> String
    /// Build the concrete pane state and swap it in for the placeholder.
    let mount: @MainActor (WindowState, PendingPaneID, PaneCreateResponse, String) -> Void
    /// Failure-log prefix (`": \(error)"` is appended).
    let failureLog: String
}

/// One in-flight tab-privacy transition. `generation` is monotonic per
/// Router so a superseded transition's late resolution can't overwrite a
/// newer one (a rapid private→public→private converges on the last
/// requested state). `task` is held so a supersede / tab-close / quit can
/// cancel it.
private struct PrivacyTransition {
    let generation: Int
    /// The state being converged toward. A membership re-kick reconverges
    /// toward this same target.
    let target: Bool
    let task: Task<Void, Never>
}

/// First decisive outcome of an awaited tab-privacy transition, reported
/// to the intent layer so `tab set-private` reflects the daemon's real
/// state. `.pending` means the requested state remains unconfirmed because
/// of a deadline, indeterminate transport loss, same-state supersession, or
/// tab disappearance.
enum TabPrivacyOutcome: Sendable, Equatable {
    case committed
    case rejected
    case pending
}

/// One-shot resolver for an awaited privacy outcome: whichever fires
/// first (the transition's `onFirstOutcome` callback or the deadline)
/// wins; later calls are ignored.
@MainActor
private final class PrivacyOutcomeGate {
    private var resumed = false
    private let continuation: CheckedContinuation<TabPrivacyOutcome, Never>

    init(_ continuation: CheckedContinuation<TabPrivacyOutcome, Never>) {
        self.continuation = continuation
    }

    func resolve(_ outcome: TabPrivacyOutcome) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: outcome)
    }
}

@MainActor
final class Router {
    /// Wire codes for a *definite* pre-commit privacy rejection: the
    /// daemon validated and refused **before** the atomic mutation, so this
    /// batch never committed. These are **terminal**: the transition reports
    /// failure and stops (retry can't succeed), then reconciles presentation
    /// from a fenced `session.privacySnapshot`, never a local guess, since
    /// the daemon's actual state may be public OR private (an older send may
    /// have committed). Everything *not* in this set (a catch-all
    /// serverError (-32000), a dropped connection) is an indeterminate
    /// transport loss that may have landed *after* the mutation, so it stays
    /// fail-closed hidden and retries with a fresh revision. A since-closed
    /// session in the batch is caught earlier by the membership re-read
    /// (reapply over the live set), before this classification runs.
    private static let definitePrivacyRejectionCodes: Set<Int> = [
        -32_602,  // invalidParams (malformed batch / bad UUID)
        -32_001,  // unauthorized (unknown session in the batch)
        -32_011   // roleViolation (not the validated GUI peer, e.g. --smoke UDS)
    ]

    let workspace: WorkspaceViewModel

    private let daemon: any SessionControlling & DeviceControlling & PaneControlling
        & PhysicalDeviceControlling
    /// Injected name-detector: production defaults to the GUI's CWD
    /// via `WorktreeName.detect`. Tests inject a fixed function so
    /// `createSessionCalls` stay deterministic regardless of where the
    /// test runner happens to be.
    private let detectWorktreeName: @MainActor () -> String?
    private var continuation: AsyncStream<Route>.Continuation?
    private var drainTask: Task<Void, Never>?
    private var nextWindowValue = 1
    private var nextTabValue = 1
    private var nextTerminalValue = 1
    private var nextPendingValue = 1
    /// In-flight attach tasks, keyed by the placeholder pane they back.
    /// The optimistic-insert handlers spawn the slow attach RPC *off*
    /// the serial drain into one of these so navigation stays
    /// responsive; Cancel / tab-close / window-close / quit cancel them
    /// deterministically. Removed by each task on completion.
    private var attachTasks: [PendingPaneID: Task<Void, Never>] = [:]
    /// In-flight tab-privacy transitions, keyed by tab. The retry-until-ack
    /// loop that keeps the daemon and GUI converged lives off the serial
    /// drain (like `attachTasks`) so a lost response doesn't wedge
    /// navigation; supersede / close / quit cancel deterministically.
    private var privacyTransitions: [TabID: PrivacyTransition] = [:]
    /// GUI-side supersession identity, one per `setTabPrivate` call. It
    /// decides which transition *owns* the tab (cancel-previous, report
    /// the outcome, clear the record); it is NOT the wire ordering key.
    /// the daemon orders by `(epoch, revision)`, so GUI generations never
    /// cross the wire.
    private var nextPrivacyGeneration = 1
    /// Superseding target per superseded generation: when a new transition
    /// replaces an in-flight one, its target is recorded here against the old
    /// generation, so the old transition's `defer` reports `.rejected` vs
    /// `.pending` deterministically, even if the superseder already committed
    /// and cleared. Each entry is removed by the superseded transition's own
    /// `defer`.
    private var supersededTargets: [Int: Bool] = [:]
    /// The client half of the wire ordering key. Monotonic per Router; a
    /// fresh value is stamped on every actual `setPrivateBatch` *send*
    /// (including retries and membership-expanded re-sends), never by a
    /// superseded task. The daemon pairs it with the connection epoch and
    /// rejects any send whose key doesn't dominate.
    private var nextPrivacyRevision = 1
    /// Highest revision whose `applied: true` reply has been committed to
    /// tab presentation, per tab. Guards against a late lower-revision ack
    /// (from a send that already lost to a newer write) reverting the tab:
    /// the GUI commits a reply only when its revision advances this.
    private var lastCommittedPrivacyRevision: [TabID: Int] = [:]
    /// One in-flight snapshot-reconciliation task per tab. It retries
    /// (fresh revision, backoff) until an authoritative fenced result or a
    /// newer transition takes ownership, so a lost/unfenced reply can't
    /// abandon the tab pending forever. A new transition cancels it.
    private var privacyReconcileTasks: [TabID: Task<Void, Never>] = [:]
    /// Set once `shutdown()` begins: a tombstone so a cancelled transition's
    /// late RPC reply can't resurrect a reconcile task after cleanup.
    private var isShutdown = false
    /// Tabs whose records are being torn down (`closeTabRecords`) but not yet
    /// removed from the workspace: a per-tab tombstone so a cancelled
    /// transition's late reply during the teardown awaits can't resurrect a
    /// reconcile while the tab still appears present.
    private var closingTabs: Set<TabID> = []
    /// Windows whose close is in progress (draining tabs across teardown
    /// awaits). The transfer coordinator rejects moves touching a closing
    /// window so its membership is FROZEN at the set the caller's `window.close`
    /// was authorized against. otherwise a foreign tab moved in during a
    /// teardown await would be destroyed without the caller having authority
    /// over it.
    private var closingWindows: Set<WindowID> = []
    /// Terminal-session creations currently in flight, per tab, keyed by a
    /// monotonic token. A privacy transition beginning while a create is in
    /// flight waits for it before snapshotting session ids, so the batch
    /// can't miss a session minted in the pre-transition state and leave it
    /// exposed under a newly-private tab. Creates that *start* after a
    /// transition inherit its target instead (no wait).
    private var inFlightCreates: [TabID: Set<Int>] = [:]
    private var nextCreateToken = 1
    /// Deadline for an awaited `applyTabPrivacy` to report `.pending` when
    /// the daemon is slow, so a stalled RPC can't wedge the serial command
    /// drain. Kept below the daemon's 5s back-channel timeout; tests
    /// shorten it.
    var privacyOutcomeDeadlineNanos: UInt64 = 3_000_000_000

    init(
        workspace: WorkspaceViewModel,
        daemon: any SessionControlling & DeviceControlling & PaneControlling
        & PhysicalDeviceControlling,
        detectWorktreeName: @escaping @MainActor () -> String? = {
            WorktreeName.detect(cwd: FileManager.default.currentDirectoryPath)
        }
    ) {
        self.workspace = workspace
        self.daemon = daemon
        self.detectWorktreeName = detectWorktreeName
        let (stream, continuation) = AsyncStream.makeStream(of: Route.self)
        self.continuation = continuation
        self.drainTask = Task { @MainActor [weak self] in
            for await route in stream {
                await self?.handle(route)
            }
        }
    }

    /// Enqueue a navigation intent. Returns immediately; the route is
    /// handled in order on the serial drain.
    func dispatch(_ route: Route) {
        // Reserve a closing window SYNCHRONOUSLY on accept, not when the
        // handler eventually runs. `dispatch` only enqueues onto the serial
        // drain, so between here and the handler the transfer coordinator
        // (which runs outside the drain) would otherwise see the window as open
        // and move a foreign tab in, which the handler's snapshot would then
        // destroy. Marking it now freezes membership from the instant the
        // close is accepted; the handler clears it when done.
        if case let .closeWindow(windowID, _) = route {
            closingWindows.insert(windowID)
        }
        continuation?.yield(route)
    }

    /// End the drain and await in-flight handling. The quit path
    /// dispatches its teardown routes first, then awaits this so the
    /// daemon RPCs complete before the GUI exits.
    func shutdown() async {
        // Tombstone: after shutdown, a cancelled transition's late
        // (non-cancellation-aware) RPC reply must not resurrect a reconcile
        // task via `scheduleReconcile`. Set before cancelling so cleanup is
        // authoritative.
        isShutdown = true
        // Drop any in-flight attaches; a 10s tunnel bring-up must not
        // wedge quit. A pane that materializes post-cancel is closed by
        // the Task's own guard (best-effort). the daemon idle-exits and
        // reaps orphans regardless.
        for task in attachTasks.values { task.cancel() }
        attachTasks.removeAll()
        for transition in privacyTransitions.values { transition.task.cancel() }
        privacyTransitions.removeAll()
        for task in privacyReconcileTasks.values { task.cancel() }
        privacyReconcileTasks.removeAll()
        continuation?.finish()
        await drainTask?.value
    }

    // MARK: - Route handling (serial drain)

    private func handle(_ route: Route) async {
        switch route {
        case let .openWindow(reattach, cwd, command):
            let window = WindowState(id: allocateWindowID(), tabs: TabListViewModel())
            workspace.addWindow(window)
            await addTab(
                to: window,
                role: .agent,
                reattach: reattach,
                cwd: cwd,
                command: command
            )

        case let .closeWindow(windowID, mode):
            // Reserved synchronously in `dispatch`; always release it, even on
            // the guard's early return, so an absent window isn't left frozen.
            defer { closingWindows.remove(windowID) }
            guard let window = workspace.window(id: windowID) else { return }
            // Close ONLY the membership authorized at enqueue time
            // (`IntentDispatcher` checked it for foreign-private tabs). The
            // Router is self-authoritative here: a tab that arrives later must
            // never be torn down without authority. Two layers protect this:
            // `closingWindows` freezes the window (from accept) so the transfer
            // coordinator rejects moves touching it, and this snapshot means
            // even a bypass leaves a straggler intact (the window just isn't
            // removed while it holds one). Re-resolve each removal for a tab
            // moved OUT.
            let authorized = window.tabs.tabs.map(\.id)
            for tabID in authorized {
                guard let tab = workspace.windowContaining(tab: tabID)?.tabs.tab(id: tabID) else {
                    continue
                }
                await closeTabRecords(tab, mode: mode)
                workspace.windowContaining(tab: tabID)?.tabs.removeTab(id: tabID)
            }
            // Remove the window only when empty, never dropping (leaking) an
            // unauthorized straggler that slipped in.
            if workspace.window(id: windowID)?.tabs.tabs.isEmpty ?? false {
                workspace.removeWindow(id: windowID)
            }

        case let .selectWindow(windowID):
            workspace.select(id: windowID)

        case let .newTab(windowID, reattach, cwd, cmd):
            guard let window = workspace.window(id: windowID) else { return }
            await addTab(
                to: window,
                role: .agent,
                reattach: reattach,
                cwd: cwd,
                command: cmd
            )

        case let .openOrchestratorTab(windowID, cwd, cmd):
            guard let window = workspace.window(id: windowID) else { return }
            await addTab(
                to: window,
                role: .orchestrator,
                reattach: [],
                cwd: cwd,
                command: cmd
            )

        case let .selectTab(windowID, tabID):
            workspace.window(id: windowID)?.tabs.select(id: tabID)

        case let .moveTabRelative(windowID, tabID, delta):
            // Resolve the named tab's *current* index, not the selection:
            // an intervening route may have moved the selection elsewhere,
            // and the user pointed at this tab.
            guard let tabs = workspace.window(id: windowID)?.tabs,
                let from = tabs.tabs.firstIndex(where: { $0.id == tabID }),
                let target = TabSelectionMath.moveDestination(
                    from: from,
                    delta: delta,
                    tabCount: tabs.tabs.count
                ) else { return }
            tabs.move(id: tabID, toIndex: target)

        case let .selectRelativeTab(windowID, delta):
            guard let tabs = workspace.window(id: windowID)?.tabs,
                let index = TabSelectionMath.wrappedIndex(
                    from: tabs.selectedIndex,
                    delta: delta,
                    tabCount: tabs.tabs.count
                ),
                tabs.tabs.indices.contains(index) else { return }
            tabs.select(id: tabs.tabs[index].id)

        case let .closeTab(windowID, tabID, mode):
            guard let window = workspace.window(id: windowID),
                let tab = window.tabs.tab(id: tabID) else { return }
            await closeTabRecords(tab, mode: mode)
            // Re-resolve the tab's window: a cross-window move (run outside the
            // drain by the AppDelegate transfer coordinator) can relocate it
            // during the teardown awaits, making the captured `window` stale.
            // Remove it from wherever it now lives, else it survives with its
            // sessions closed and a late privacy reply could resurrect it once
            // the closing tombstone drops.
            workspace.windowContaining(tab: tabID)?.tabs.removeTab(id: tabID)

        case let .openTerminalPane(tabID, cwd, cmd, anchor, axis, side):
            await openTerminalPane(
                tab: tabID,
                cwd: cwd,
                command: cmd,
                anchor: anchor,
                axis: axis,
                side: side
            )

        case let .closeTerminalPane(tabID, terminalID, mode):
            await closeTerminalPane(tab: tabID, terminal: terminalID, mode: mode)

        case let .setTabPrivate(tabID, isPrivate):
            setTabPrivate(tab: tabID, isPrivate: isPrivate)

        case let .attachSimPane(tabID, udid, displayName, family, atIndex, anchor):
            attachPaneOptimistically(
                tab: tabID,
                spec: simAttachSpec(
                    tab: tabID,
                    udid: udid,
                    displayName: displayName,
                    family: family,
                    atIndex: atIndex,
                    anchor: anchor
                )
            )

        case let .detachSimPane(tabID, udid, mode):
            await detachPane(tab: tabID, udid: udid, mode: mode)

        case let .attachDevicePane(tabID, deviceId, displayName):
            attachPaneOptimistically(
                tab: tabID,
                spec: deviceAttachSpec(tab: tabID, deviceId: deviceId, displayName: displayName)
            )

        case let .detachDevicePane(tabID, deviceId, mode):
            await detachDevicePane(tab: tabID, deviceId: deviceId, mode: mode)

        case let .retryPendingPane(tabID, pendingId):
            retryPendingPane(tab: tabID, pendingId: pendingId)

        case let .cancelPendingPane(tabID, pendingId, mode):
            cancelPendingPane(tab: tabID, pendingId: pendingId, mode: mode)

        case let .reorderTab(windowID, tabID, toIndex):
            workspace.window(id: windowID)?.tabs.move(id: tabID, toIndex: toIndex)

        case let .reorderPane(tabID, slot, target, zone):
            guard let window = workspace.windowContaining(tab: tabID) else { return }
            window.tabs.reorderPane(
                slot: slot,
                to: target,
                zone: zone,
                inTab: tabID
            )

        case let .flipSplitAxis(tabID, slot):
            guard let window = workspace.windowContaining(tab: tabID) else { return }
            window.tabs.flipSplitAxis(containing: slot, inTab: tabID)
        }
    }

    private func addTab(
        to window: WindowState,
        role: SessionRole,
        reattach: [OrphanRecord],
        cwd: String? = nil,
        command: [String]? = nil
    ) async {
        do {
            // Pre-populate `name` from the worktree branch when the
            // GUI's CWD is in a git worktree. Detector returns nil
            // outside a worktree, leaving the tab unnamed; a future
            // `deviceterm tab rename` can fill it.
            //
            // Role: the standard tab-open path passes `.agent`; the
            // "Open Orchestrator Tab" menu's route passes
            // `.orchestrator`. The daemon may reject the request (e.g.
            // an older daemon that doesn't accept the role parameter
            // returns `.agent`); trust the response's `role` rather
            // than the requested one so the tab's recorded role
            // matches what's actually on the wire.
            let name = detectWorktreeName()
            // A freshly-opened tab is always public; a private tab is only
            // ever reached by toggling privacy after it exists.
            let session = try await daemon.createSession(
                label: nil,
                name: name,
                role: role,
                initialPrivate: false
            )
            let primary = TerminalPaneState(
                id: allocateTerminalPaneID(),
                sessionId: session.sessionId,
                capability: session.capability,
                shortId: session.shortId,
                name: session.name,
                cwd: cwd,
                command: command
            )
            let tab = TabState(
                id: allocateTabID(),
                terminals: [primary],
                simPanes: [],
                role: session.role ?? role
            )
            window.tabs.append(tab)
            // Mount each orphan record's sims; clean its session dir only
            // after every sim attached, else leave it so the orphan is
            // re-offered next launch (matches the original addTab).
            for orphan in reattach {
                var allAttached = true
                for sim in orphan.liveSims {
                    // Orphan mount happens at cold start with nothing else
                    // competing for the drain, so awaiting the attach inline
                    // here is fine, and it lets the cleanup decision still
                    // hinge on real success. The pending pane is inserted
                    // first so the sims appear immediately during the mount.
                    let target = PaneTarget.sim(udid: sim.udid)
                    guard let live = window.tabs.tab(id: tab.id) else {
                        allAttached = false
                        continue
                    }
                    if TabListViewModel.isTargetPresent(target, in: live) {
                        continue  // already mounted/pending → idempotent success
                    }
                    let pendingId = allocatePendingPaneID()
                    window.tabs.addPendingPane(
                        PendingPaneState(
                            id: pendingId,
                            target: target,
                            displayName: sim.displayName
                        ),
                        toTab: tab.id,
                        spawningTerminal: tab.primaryTerminal.id
                    )
                    let ok = await runAttach(
                        tab: tab.id,
                        pendingId: pendingId,
                        spec: simAttachSpec(
                            tab: tab.id,
                            udid: sim.udid,
                            displayName: sim.displayName
                        )
                    )
                    if !ok { allAttached = false }
                }
                if allAttached { OrphanRecovery.cleanup([orphan.sessionDir]) }
            }
        } catch {
            logError("session.create failed: \(error)")
        }
    }

    /// Add an additional terminal pane to an existing tab. Mints a
    /// new daemon session inheriting the tab's role; the reconcile
    /// pass in `TabContentViewController` picks up the new entry and
    /// builds a `TerminalPaneViewController` for it. Carries no
    /// worktree-name pre-population. added terminals start unnamed.
    private func openTerminalPane(
        tab tabID: TabID,
        cwd: String? = nil,
        command: [String]? = nil,
        anchor: PaneSlot? = nil,
        axis: SplitAxis? = nil,
        side: AdjacentSide = .after
    ) async {
        guard let window = workspace.windowContaining(tab: tabID),
            let tab = window.tabs.tab(id: tabID) else { return }
        // Mint the fresh session fail-closed from the tab's *current
        // effective-hidden* state: private whenever the tab is hidden,
        // including mid-transition in EITHER direction. Never inherit a
        // transition's target: a private→public target would declassify the
        // new session (born daemon-public) while the tab is deliberately
        // still private until the daemon acks. The transition's membership
        // recheck then publicizes every session together only when it
        // commits. Register the create as in-flight first so a privacy
        // transition beginning while this is suspended in `createSession`
        // waits for its session id before batching.
        let createdPrivate = tab.isEffectivelyHidden
        let createToken = nextCreateToken
        nextCreateToken += 1
        inFlightCreates[tabID, default: []].insert(createToken)
        defer {
            inFlightCreates[tabID]?.remove(createToken)
            if inFlightCreates[tabID]?.isEmpty == true { inFlightCreates[tabID] = nil }
        }
        do {
            let session = try await daemon.createSession(
                label: nil,
                name: nil,
                role: tab.role,
                initialPrivate: createdPrivate
            )
            // Re-resolve the tab's window after the await: a cross-window
            // `tab move` runs on the main actor outside the route drain and
            // can relocate (or close) the tab while `createSession` is
            // suspended. The `window` captured above would then be stale, so
            // `addTerminal` would silently no-op against the old window,
            // stranding a live daemon session that no pane references and that
            // a concurrent privacy batch never covers. If the tab is gone,
            // close the orphaned session rather than leak it.
            guard let liveWindow = workspace.windowContaining(tab: tabID),
                liveWindow.tabs.tab(id: tabID) != nil else {
                try? await daemon.closeSession(
                    sessionId: session.sessionId,
                    capability: session.capability,
                    mode: .shutdown
                )
                return
            }
            let terminal = TerminalPaneState(
                id: allocateTerminalPaneID(),
                sessionId: session.sessionId,
                capability: session.capability,
                shortId: session.shortId,
                name: session.name,
                cwd: cwd,
                command: command
            )
            liveWindow.tabs.addTerminal(
                terminal,
                toTab: tabID,
                anchor: anchor,
                axis: axis,
                side: side
            )
            // Defense in depth. A transition in flight already covers this
            // session: it either waited for this create (in-flight when it
            // began) or this create inherited its target, and its
            // membership recheck folds in anything it missed; re-kicking it
            // here would only supersede (and mis-report) the awaited
            // transition. So only reconcile when NO transition is in flight
            // and the tab's EFFECTIVE state changed while `createSession`
            // awaited (the terminal was minted with stale privacy). Compare
            // against `isEffectivelyHidden`, NOT committed `isPrivate`: a
            // `.pendingPrivate` (hidden-but-unresolved) tab is effectively
            // hidden, matching a terminal minted from a hidden tab, so it is
            // NOT re-kicked toward public, which would reveal a tab mid-hide.
            if privacyTransitions[tabID] == nil,
                let liveTab = liveWindow.tabs.tab(id: tabID),
                liveTab.isEffectivelyHidden != createdPrivate {
                setTabPrivate(tab: tabID, isPrivate: liveTab.isEffectivelyHidden)
            }
        } catch {
            logError("session.create failed: \(error)")
        }
    }

    /// Close one terminal pane in a tab. Refuses to drop the only
    /// remaining terminal. the caller should `closeTab` instead.
    /// The cap-authenticated `session.close` runs first, then the
    /// scratch dir is wiped on `.shutdown`; the nav-state removal
    /// drops the entry so reconcile tears the VC down.
    private func closeTerminalPane(
        tab tabID: TabID,
        terminal terminalID: TerminalPaneID,
        mode: PaneCloseMode
    ) async {
        guard let window = workspace.windowContaining(tab: tabID),
            let tab = window.tabs.tab(id: tabID),
            let terminal = tab.terminals.first(where: { $0.id == terminalID })
        else { return }
        // Last-terminal guard: refuse silently rather than orphaning the
        // tab. The Intent layer translates this into a callable error
        // when invoked from the CLI.
        guard tab.terminals.count > 1 else { return }
        try? await daemon.closeSession(
            sessionId: terminal.sessionId,
            capability: terminal.capability,
            mode: mode
        )
        if mode == .shutdown {
            SessionEnvironment.cleanup(sessionId: terminal.sessionId)
        }
        window.tabs.removeTerminal(id: terminalID, fromTab: tabID)
        // Re-kick any in-flight transition so its next batch drops the
        // now-closed session (a stale id would make the daemon reject the
        // batch); the generation guard makes the superseded batch harmless.
        reconvergePrivacyIfTransitioning(tab: tabID)
    }

    /// Begin (or supersede) a tab-privacy transition. Fail-closed and
    /// acknowledged:
    ///
    ///  - A public→private transition hides the tab **immediately**
    ///    (`.pendingPrivate`), before any daemon round-trip, and only
    ///    commits to `.privateHidden` on the ack. A private→public stays
    ///    hidden (its committed-private state) until the ack.
    ///  - `runPrivacyTransition` commits presentation only from authoritative
    ///    daemon signals: a tab is EXPOSED only by the owning transition's
    ///    highest-key make-public `applied: true` or a fenced uniform-public
    ///    `session.privacySnapshot`. An indeterminate loss retries; a definite
    ///    rejection or a stale `applied: false` reconciles via a fenced
    ///    snapshot (never a local guess).
    ///  - Ordering is DAEMON-enforced by `(epoch, revision)` last-write-wins,
    ///    so the GUI does not serialize: a superseded send still in flight
    ///    simply loses (its key can't dominate). A rapid
    ///    private→public→private converges on the last requested state, and a
    ///    stale send (even one arriving after an XPC reconnect) can never
    ///    overwrite a newer one daemon-side.
    private func setTabPrivate(
        tab tabID: TabID,
        isPrivate: Bool,
        onFirstOutcome: (@MainActor (TabPrivacyOutcome) -> Void)? = nil
    ) {
        guard let window = workspace.windowContaining(tab: tabID),
            let liveTab = window.tabs.tab(id: tabID) else {
            onFirstOutcome?(.pending)
            return
        }
        // Terminal creates already in flight for this tab were minted in the
        // pre-transition state; the transition must wait for their session
        // ids before batching so it doesn't miss them. Creates that start
        // after this point are minted fail-closed from the (now hidden)
        // effective state and need no wait.
        let awaitedCreates = inFlightCreates[tabID] ?? []
        let generation = nextPrivacyGeneration
        nextPrivacyGeneration += 1
        // Fail-closed hide happens now, synchronously, before the first
        // suspension: a public→private is hidden the instant the user
        // acts even though the daemon hasn't confirmed.
        if isPrivate, liveTab.privacyState == .publicVisible {
            window.tabs.setPrivacyState(.pendingPrivate, id: tabID)
        }
        // Supersede any in-flight transition, but do NOT wait for it: the
        // daemon is the ordering authority now (last-write-wins by
        // `(epoch, revision)`), so an older send still in flight simply
        // loses. the GUI needn't serialize and can never wedge behind a
        // stalled predecessor. Cancelling stops the old transition from
        // *retrying*; its already-sent batch is harmless (stale or a no-op
        // idempotent re-apply). Record THIS request's target against the
        // superseded generation so the predecessor's outcome is determined
        // against the superseder even after this transition commits and
        // clears: reading only the live transition would misreport an
        // abandoned request as `.pending`.
        if let previous = privacyTransitions[tabID] {
            supersededTargets[previous.generation] = isPrivate
            previous.task.cancel()
        }
        // A new transition takes ownership: cancel any snapshot reconcile
        // still retrying for this tab; the transition drives it now.
        privacyReconcileTasks[tabID]?.cancel()
        privacyReconcileTasks[tabID] = nil
        let task = Task { @MainActor [weak self] in
            guard let self else {
                // Router torn down. never leave an awaiter hanging.
                onFirstOutcome?(.pending)
                return
            }
            await self.runPrivacyTransition(
                tab: tabID,
                isPrivate: isPrivate,
                generation: generation,
                awaitedCreates: awaitedCreates,
                onFirstOutcome: onFirstOutcome
            )
        }
        privacyTransitions[tabID] = PrivacyTransition(
            generation: generation,
            target: isPrivate,
            task: task
        )
    }

    /// Awaited privacy transition for the intent layer. Begins (or
    /// supersedes) the transition and resolves on its first decisive
    /// outcome: `.committed` (daemon applied it), `.rejected` (definitely
    /// refused, or abandoned by an opposite-state supersede), or `.pending`
    /// (unconfirmed because of a deadline, indeterminate transport loss,
    /// same-state supersession, or tab disappearance). Lets
    /// `tab set-private` report the daemon's real state instead of an
    /// optimistic echo.
    func applyTabPrivacy(tab tabID: TabID, isPrivate: Bool) async -> TabPrivacyOutcome {
        await withCheckedContinuation { continuation in
            let gate = PrivacyOutcomeGate(continuation)
            setTabPrivate(tab: tabID, isPrivate: isPrivate) { outcome in
                gate.resolve(outcome)
            }
            // Bound the wait so one slow/unresponsive daemon can't wedge the
            // serial command drain: report `.pending` after the deadline
            // while the transition keeps converging in the background. Kept
            // below the daemon's 5s back-channel command timeout.
            let deadline = privacyOutcomeDeadlineNanos
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: deadline)
                gate.resolve(.pending)
            }
        }
    }

    /// Drive one privacy transition, then reconcile presentation ONLY from
    /// authoritative daemon signals, never a local heuristic. Fail-closed:
    /// hiding is immediate, revealing needs proof.
    ///
    ///  - A tab is EXPOSED (`.publicVisible`) only by the OWNING transition's
    ///    highest-key make-public `applied: true`, or by a fenced,
    ///    uniform-public `session.privacySnapshot`. Never from a superseded
    ///    reply, an in-flight counter, or a "pending-implies-public" guess.
    ///  - `applied: true` (owning, membership match, revision advances):
    ///    commit `.privateHidden` / `.publicVisible`; report `.committed`.
    ///  - `applied: false` (a higher key won, possibly another connection's)
    ///    or a **definite rejection**: clear and reconcile via a fenced
    ///    snapshot; the tab reveals only on a fenced uniform-public result,
    ///    else stays hidden and unresolved.
    ///  - **indeterminate transport loss**: retry with a fresh revision.
    ///  - A SUPERSEDED reply commits nothing; the superseding transition (or
    ///    its own terminal reconcile) drives the tab.
    ///
    /// Membership recheck still applies: a terminal created (fail-closed
    /// private) while a batch is in flight is folded in by reapplying over
    /// the new session set before committing.
    private func runPrivacyTransition(
        tab tabID: TabID,
        isPrivate desiredPrivate: Bool,
        generation: Int,
        awaitedCreates: Set<Int> = [],
        onFirstOutcome: (@MainActor (TabPrivacyOutcome) -> Void)? = nil
    ) async {
        var backoffMs = 200
        // Report the first decisive outcome exactly once to an awaiting
        // intent caller. The `defer` is a safety net: any exit that didn't
        // already report (supersede, tab-gone) resolves as `.pending` so
        // an awaiter never hangs.
        var fired = false
        func fire(_ outcome: TabPrivacyOutcome) {
            guard !fired else { return }
            fired = true
            onFirstOutcome?(outcome)
        }
        defer {
            // Unreported exit = superseded or tab-gone. If the transition that
            // superseded this one pursued the OPPOSITE state, the caller's
            // request was abandoned: report `.rejected`, not a misleading
            // "converging toward your value." A same-state supersede is still
            // converging, so `.pending`. Prefer the target RECORDED at
            // supersession time (`supersededTargets[generation]`): the
            // superseder may have already committed and cleared, so reading
            // only the live transition would race and misreport. Fall back to
            // the live transition for a tab-gone exit with no recorded
            // superseder.
            let superseder = supersededTargets[generation] ?? privacyTransitions[tabID]?.target
            supersededTargets[generation] = nil
            if let superseder, superseder != desiredPrivate {
                fire(.rejected)
            } else {
                fire(.pending)
            }
        }
        // Wait for terminal creates that were already in flight when this
        // transition began: their sessions were minted in the
        // pre-transition state, so the batch must cover them. The tab is
        // already fail-closed hidden while we wait (set synchronously in
        // `setTabPrivate`). Bails if a newer transition supersedes.
        while !awaitedCreates.isDisjoint(with: inFlightCreates[tabID] ?? []) {
            guard privacyTransitions[tabID]?.generation == generation else { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        while !Task.isCancelled {
            guard privacyTransitions[tabID]?.generation == generation else { return }
            guard let tab = workspace.windowContaining(tab: tabID)?.tabs.tab(id: tabID) else {
                // Tab closed mid-transition: nothing to converge.
                clearPrivacyTransition(tabID, generation: generation)
                return
            }
            let sentIds = tab.terminals.map(\.sessionId)
            // Fresh revision per send: the daemon rejects a stale key, so
            // reusing one across attempts would make an idempotent retry
            // look stale. A superseded task never reaches here (guard above).
            let revision = nextPrivacyRevision
            nextPrivacyRevision += 1
            do {
                let result = try await daemon.setPrivateBatch(
                    sessionIds: sentIds,
                    isPrivate: desiredPrivate,
                    revision: revision
                )
                // A SUPERSEDED reply commits nothing itself. But it may have
                // changed the daemon (an older make-public that finally
                // applied), so if NO transition is active to drive the tab,
                // reconcile from an authoritative snapshot; if a newer one is
                // active, it drives.
                guard privacyTransitions[tabID]?.generation == generation else {
                    // Reconcile ONLY if this reply is newer than the last
                    // committed revision. A newer transition that already
                    // committed (lastCommitted advanced past our revision) is
                    // authoritative: scheduling a reconcile would
                    // synchronously demote its correct state to `.pendingPrivate`.
                    if privacyTransitions[tabID] == nil,
                        revision > (lastCommittedPrivacyRevision[tabID] ?? 0) {
                        scheduleReconcile(tab: tabID)
                    }
                    return
                }
                if !result.applied {
                    // A higher-key write won daemon-side, possibly another
                    // connection's, whose state we can't infer locally. Clear
                    // and reconcile from an authoritative fenced snapshot.
                    clearPrivacyTransition(tabID, generation: generation)
                    scheduleReconcile(tab: tabID)
                    return
                }
                guard let window = workspace.windowContaining(tab: tabID),
                    let liveTab = window.tabs.tab(id: tabID) else {
                    clearPrivacyTransition(tabID, generation: generation)
                    return
                }
                if Set(liveTab.terminals.map(\.sessionId)) != Set(sentIds) {
                    // Membership changed while the batch was in flight:
                    // reapply over the new set with a fresh revision.
                    backoffMs = 200
                    continue
                }
                // Owning + applied + membership match. This is the one place a
                // make-public may REVEAL the tab (the highest-key public
                // write acknowledgement) and hiding is always safe. The
                // revision guard stops a late lower-key ack from overriding a
                // newer commit (e.g. a snapshot reconcile that already ran).
                if revision > (lastCommittedPrivacyRevision[tabID] ?? 0) {
                    lastCommittedPrivacyRevision[tabID] = revision
                    window.tabs.setPrivacyState(
                        result.isPrivate ? .privateHidden : .publicVisible,
                        id: tabID
                    )
                }
                clearPrivacyTransition(tabID, generation: generation)
                fire(.committed)
                return
            } catch {
                if Task.isCancelled { return }
                guard privacyTransitions[tabID]?.generation == generation else {
                    // Superseded. An indeterminate loss may have committed the
                    // daemon; reconcile only if nothing is left to drive the
                    // tab AND this reply is newer than the last commit (else a
                    // newer transition already set the authoritative state).
                    if privacyTransitions[tabID] == nil,
                        revision > (lastCommittedPrivacyRevision[tabID] ?? 0) {
                        scheduleReconcile(tab: tabID)
                    }
                    return
                }
                guard let liveTab = workspace.windowContaining(tab: tabID)?
                    .tabs.tab(id: tabID) else {
                    clearPrivacyTransition(tabID, generation: generation)
                    return
                }
                // Self-heal a concurrently-changed membership before
                // classifying: a failure may only name a session that closed
                // while the batch was in flight, so reapply over the live set
                // rather than treating it as a refusal (drops the dead id).
                if Set(liveTab.terminals.map(\.sessionId)) != Set(sentIds) {
                    backoffMs = 200
                    continue
                }
                // Membership is stable. A DEFINITE pre-commit rejection (the
                // daemon validated and refused before mutating) is terminal:
                // report the failure, then reconcile presentation from a
                // fenced snapshot, never a local guess (the daemon may be
                // public OR private, e.g. an older send committed). Only an
                // INDETERMINATE transport loss retries with a fresh revision,
                // reported as `.pending`. (`.rejected` also covers an opposite
                // supersede, see the `defer` above.) `roleViolation` (-32011)
                // is a definite/terminal signature rejection on BOTH transports
                // now: the smoke UDS structural refusal AND a genuine XPC
                // signature mismatch (which retrying can't fix). The transient,
                // retryable validation-unavailable outcome is `notReadyCode`
                // (-32002), which the client's `request()` retries internally,
                // so it never surfaces here as a definite rejection.
                if case let DaemonClientError.daemon(code, message) = error,
                    Self.definitePrivacyRejectionCodes.contains(code) {
                    logError(
                        "session.setPrivateBatch refused for tab "
                        + "\(tabID.value): \(code) \(message)"
                    )
                    clearPrivacyTransition(tabID, generation: generation)
                    fire(.rejected)
                    scheduleReconcile(tab: tabID)
                    return
                }
                fire(.pending)
                try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                backoffMs = min(backoffMs * 2, 5_000)
            }
        }
    }

    /// Present a tab as hidden-and-UNRESOLVED (`.pendingPrivate`) when a
    /// reconcile can't get an authoritative answer. Demotes BOTH a
    /// `.publicVisible` and a `.privateHidden` tab: leaving a `.privateHidden`
    /// tab as-is would falsely classify it committed-private while its real
    /// daemon state is unknown. Idempotent (no-op if already pending).
    private func markPrivacyUnresolved(tab tabID: TabID, window: WindowState) {
        guard window.tabs.tab(id: tabID)?.privacyState != .pendingPrivate else { return }
        window.tabs.setPrivacyState(.pendingPrivate, id: tabID)
    }

    /// Schedule (or restart) the snapshot reconciliation for a tab after a
    /// terminal/ambiguous transition outcome. Supersedes any prior reconcile
    /// task for the tab.
    private func scheduleReconcile(tab tabID: TabID) {
        // Cleanup is authoritative: after Router shutdown, while a tab is
        // being torn down (still in the workspace but closing), or once the
        // tab is gone, a late reply must not resurrect a reconcile task.
        guard !isShutdown, !closingTabs.contains(tabID),
            let window = workspace.windowContaining(tab: tabID) else { return }
        privacyReconcileTasks[tabID]?.cancel()
        // Fail-closed SYNCHRONOUSLY, before the async snapshot task runs: the
        // triggering outcome (an `applied: false`, a rejection, a superseded
        // reply) means the tab's true daemon privacy is now unknown. Leaving
        // it `.publicVisible` would expose it to foreign callers, and leaving
        // it `.privateHidden` would falsely present it as committed-private,
        // for the whole (possibly stalled) read window. Mark it unresolved
        // now; the reconcile resolves it to an authoritative state.
        markPrivacyUnresolved(tab: tabID, window: window)
        privacyReconcileTasks[tabID] = Task { @MainActor [weak self] in
            await self?.runPrivacyReconcile(tab: tabID)
        }
    }

    /// Drive a tab's presentation to the daemon's authoritative privacy via a
    /// fenced `session.privacySnapshot`, retrying (fresh revision, backoff)
    /// until it gets an authoritative fenced result, a newer transition takes
    /// ownership, or a newer authoritative commit supersedes it. so a lost
    /// or unfenced reply never abandons the tab pending forever. Fail-closed:
    /// exposes the tab ONLY on a fenced uniform-public result with unchanged
    /// membership *and* a revision that still leads the last commit; anything
    /// else stays hidden (and, when not yet authoritative, retries).
    private func runPrivacyReconcile(tab tabID: TabID) async {
        var backoffMs = 200
        while !Task.isCancelled {
            // A transition owns the tab now: it drives; stop reconciling.
            guard privacyTransitions[tabID] == nil,
                let tab = workspace.windowContaining(tab: tabID)?.tabs.tab(id: tabID) else { return }
            let sessionIds = tab.terminals.map(\.sessionId)
            let revision = nextPrivacyRevision
            nextPrivacyRevision += 1
            let result: SessionPrivacySnapshotResult
            do {
                result = try await daemon.privacySnapshot(sessionIds: sessionIds, revision: revision)
            } catch {
                // A `roleViolation` (-32011) is a definite/terminal signature
                // rejection on BOTH transports: the `--smoke` UDS structural
                // refusal (no audit token to validate) AND a genuine XPC
                // signature mismatch, so retrying can never succeed: stop and
                // leave the tab fail-closed hidden (already marked unresolved in
                // `scheduleReconcile`). The transient, retryable
                // validation-unavailable outcome is `notReadyCode` (-32002),
                // retried inside the client's `request()`, so it never surfaces
                // here. Mirrors `AppCommandSubscriber.drainLoop`.
                if case let DaemonClientError.daemon(code, _) = error, code == -32_011 {
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                backoffMs = min(backoffMs * 2, 5_000)
                continue
            }
            if Task.isCancelled { return }
            guard privacyTransitions[tabID] == nil,
                let window = workspace.windowContaining(tab: tabID),
                let liveTab = window.tabs.tab(id: tabID) else { return }
            // A newer authoritative commit already set the correct state while
            // we were reading. this snapshot is stale; NEVER apply a state
            // older than what's committed (this is the exposure guard: it
            // gates the presentation write itself, not just the counter).
            guard revision > (lastCommittedPrivacyRevision[tabID] ?? 0) else { return }
            let membershipUnchanged = Set(liveTab.terminals.map(\.sessionId)) == Set(sessionIds)
            if result.fenced, membershipUnchanged {
                lastCommittedPrivacyRevision[tabID] = revision
                if result.sessions.allSatisfy({ $0.state == .publicState }) {
                    window.tabs.setPrivacyState(.publicVisible, id: tabID)
                    return
                }
                if result.sessions.allSatisfy({ $0.state == .privateState }) {
                    window.tabs.setPrivacyState(.privateHidden, id: tabID)
                    return
                }
                // Fenced but MIXED: authoritative yet non-uniform (only a new
                // write resolves a genuine split). Present as
                // hidden-and-unresolved; a later transition reconciles.
                // Terminal: retrying can't change a genuine split.
                markPrivacyUnresolved(tab: tabID, window: window)
                return
            }
            // Unfenced or membership-changed → not yet authoritative. Present
            // as hidden-and-unresolved (fail-closed) and retry until it
            // settles, never leave a stale committed classification.
            markPrivacyUnresolved(tab: tabID, window: window)
            try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
            backoffMs = min(backoffMs * 2, 5_000)
        }
    }

    /// Re-kick an in-flight privacy transition after a tab's terminal set
    /// changed, so the newly-added (or removed) session is folded into a
    /// fresh batch over the current membership. A no-op when no transition
    /// is in flight: a terminal added to a stable tab already inherits
    /// the right privacy at `session.create`.
    private func reconvergePrivacyIfTransitioning(tab tabID: TabID) {
        guard let transition = privacyTransitions[tabID] else { return }
        // Reconverge toward the transition's target over the new membership.
        setTabPrivate(tab: tabID, isPrivate: transition.target)
    }

    /// Drop the transition record iff it's still the one identified by
    /// `generation` (a newer supersede may have replaced it).
    private func clearPrivacyTransition(_ tabID: TabID, generation: Int) {
        if privacyTransitions[tabID]?.generation == generation {
            privacyTransitions[tabID] = nil
        }
    }

    private func simAttachSpec(
        tab tabID: TabID,
        udid: String,
        displayName: String?,
        family: String? = nil,
        atIndex: Int? = nil,
        anchor: ResurrectAnchor? = nil
    ) -> PendingAttachSpec {
        PendingAttachSpec(
            target: .sim(udid: udid),
            displayName: displayName,
            family: family,
            atIndex: atIndex,
            anchor: anchor,
            attach: { [daemon] primary in
                try await daemon.attachDevice(
                    sessionId: primary.sessionId,
                    capability: primary.capability,
                    udid: udid
                )
            },
            resolveName: { [weak self] _ in
                if let displayName { return displayName }
                if let looked = await self?.resolveDeviceName(udid: udid) { return looked }
                return "Sim \(udid.prefix(8))"
            },
            mount: { window, pendingId, response, resolvedName in
                let pane = SimPaneState(
                    paneId: response.paneId,
                    udid: udid,
                    displayName: resolvedName,
                    family: response.family ?? DeviceFamily.unknown.rawValue,
                    shortId: response.shortId,
                    name: response.name,
                    pixelWidth: response.pixelWidth,
                    pixelHeight: response.pixelHeight,
                    capabilities: response.capabilities
                )
                window.tabs.replacePendingWithSim(id: pendingId, pane: pane, inTab: tabID)
            },
            failureLog: "device.attach failed for \(udid)"
        )
    }

    /// Device attach: mirrors `simAttachSpec` with two deliberate
    /// differences: `physicalDevice.attach` (deviceId + an explicit
    /// attribution session the daemon honors only for the
    /// signature-validated GUI peer, no cap), and no resurrect metadata
    /// (device panes are never persisted). The response carries the
    /// marketing name, so there's no `device.list` lookup.
    private func deviceAttachSpec(
        tab tabID: TabID,
        deviceId: String,
        displayName: String?
    ) -> PendingAttachSpec {
        PendingAttachSpec(
            target: .device(deviceId: deviceId),
            displayName: displayName,
            family: nil,
            atIndex: nil,
            anchor: nil,
            attach: { [daemon] primary in
                try await daemon.attachPhysicalDevice(
                    deviceId: deviceId,
                    sessionId: primary.sessionId
                )
            },
            resolveName: { response in
                if let displayName { return displayName }
                if let responseName = response.name { return responseName }
                return "Device \(deviceId.prefix(8))"
            },
            mount: { window, pendingId, response, resolvedName in
                let pane = DevicePaneState(
                    paneId: response.paneId,
                    deviceId: deviceId,
                    displayName: resolvedName,
                    family: response.family ?? DeviceFamily.unknown.rawValue,
                    shortId: response.shortId,
                    name: response.name,
                    pixelWidth: response.pixelWidth,
                    pixelHeight: response.pixelHeight,
                    capabilities: response.capabilities
                )
                window.tabs.replacePendingWithDevice(id: pendingId, pane: pane, inTab: tabID)
            },
            failureLog: "physicalDevice.attach failed for \(deviceId)"
        )
    }

    /// Optimistically mount a pane: insert a placeholder leaf the instant
    /// the user acts, then run the attach RPC **off** the serial drain so a
    /// slow attach never freezes navigation. On success the placeholder
    /// swaps for the real pane; on failure it shows the error + Retry.
    /// Discovery / resurrect / menu / CLI claim / device picker funnel here.
    private func attachPaneOptimistically(tab tabID: TabID, spec: PendingAttachSpec) {
        guard let window = workspace.windowContaining(tab: tabID),
            let tab = window.tabs.tab(id: tabID) else { return }
        // Target-based dedup across mounted + pending panes so discovery
        // (every 2s), menu, CLI, picker, and resurrect can't stack a second
        // (or a duplicate failed) placeholder for the same target.
        guard !TabListViewModel.isTargetPresent(spec.target, in: tab) else { return }
        // The daemon session is always the tab's primary terminal (the
        // ownership/cap binding); `lastFocusedTerminal` is only the
        // placement heuristic: where the new leaf lands.
        let spawningTerminalID = tab.lastFocusedTerminal ?? tab.primaryTerminal.id
        let pendingId = allocatePendingPaneID()
        window.tabs.addPendingPane(
            PendingPaneState(
                id: pendingId,
                target: spec.target,
                displayName: spec.displayName,
                family: spec.family,
                atIndex: spec.atIndex
            ),
            toTab: tabID,
            spawningTerminal: spawningTerminalID,
            anchor: spec.anchor
        )
        let task = Task { @MainActor [weak self] in
            _ = await self?.runAttach(tab: tabID, pendingId: pendingId, spec: spec)
            self?.attachTasks[pendingId] = nil
        }
        attachTasks[pendingId] = task
    }

    /// Run the attach RPC for a pending pane and reconcile the result: swap
    /// the placeholder for the real pane on success, flip it to `.failed` on
    /// error. Returns whether the pane mounted (the orphan-reattach loop
    /// reads this to decide cleanup). If the placeholder vanished during the
    /// await (Cancel / tab close), the daemon pane that came back is closed
    /// so it doesn't leak.
    @discardableResult
    private func runAttach(
        tab tabID: TabID,
        pendingId: PendingPaneID,
        spec: PendingAttachSpec
    ) async -> Bool {
        guard let primary = workspace.windowContaining(tab: tabID)?
            .tabs.tab(id: tabID)?.primaryTerminal else { return false }
        do {
            let response = try await spec.attach(primary)
            // If teardown cancelled us mid-attach (tab/window close,
            // explicit Cancel, or quit), do NOT mount. The pending record
            // may still be in nav state (the tab is only removed after
            // its close RPCs await) so the pending-still-present guard
            // below isn't enough on its own; the cancellation flag is.
            // Close the pane that just materialized so it doesn't leak.
            if Task.isCancelled {
                try? await daemon.closePane(paneId: response.paneId, mode: .detach)
                return false
            }
            // Resolve the bare name (the sim path may await a `device.list`
            // lookup here), then compose "Name · Type" using the response's
            // deviceType (collapsed to just the name for a stock device).
            let bareName = await spec.resolveName(response)
            let resolvedName: String
            if let deviceType = response.deviceType, deviceType != bareName {
                resolvedName = "\(bareName) · \(deviceType)"
            } else {
                resolvedName = bareName
            }
            // Single post-await reconciliation covering every race (the
            // attach await + the optional name-lookup await): mount iff
            // the placeholder is still present; otherwise the attach
            // outlived a Cancel / tab-close: close the materialized
            // daemon pane so it doesn't leak.
            guard let window = workspace.windowContaining(tab: tabID),
                window.tabs.tab(id: tabID)?.pendingPanes
                    .contains(where: { $0.id == pendingId }) == true else {
                try? await daemon.closePane(paneId: response.paneId, mode: .detach)
                return false
            }
            spec.mount(window, pendingId, response, resolvedName)
            return true
        } catch {
            logError("\(spec.failureLog): \(error)")
            workspace.windowContaining(tab: tabID)?.tabs.failPendingPane(
                id: pendingId,
                message: ErrorText.describing(error),
                inTab: tabID
            )
            return false
        }
    }

    /// Best-effort `device.list` lookup for the human-readable name of
    /// `udid`. Returns nil on RPC failure or no match: caller falls
    /// back to a UDID-prefix placeholder so the pane still mounts.
    private func resolveDeviceName(udid: String) async -> String? {
        guard let devices = try? await daemon.deviceList(scope: .all) else {
            return nil
        }
        return devices.first {
            $0.udid.caseInsensitiveCompare(udid) == .orderedSame
        }?.name
    }

    private func detachPane(tab tabID: TabID, udid: String, mode: PaneCloseMode) async {
        guard let window = workspace.windowContaining(tab: tabID),
            let pane = window.tabs.tab(id: tabID)?.simPanes
                .first(where: { $0.udid == udid }) else { return }
        try? await daemon.closePane(paneId: pane.paneId, mode: mode)
        window.tabs.removeSimPane(udid: udid, fromTab: tabID)
    }

    /// Retry a failed pending pane: re-run the attach whose first try
    /// threw. Guarded on the `.failed` phase so a stray retry while an
    /// attach is already in flight is a no-op (re-entrancy).
    private func retryPendingPane(tab tabID: TabID, pendingId: PendingPaneID) {
        guard let window = workspace.windowContaining(tab: tabID),
            let pending = window.tabs.tab(id: tabID)?.pendingPanes
                .first(where: { $0.id == pendingId }),
            case .failed = pending.phase else { return }
        window.tabs.retryPendingPane(id: pendingId, inTab: tabID)
        attachTasks[pendingId]?.cancel()
        // Rebuild the attach spec from the placeholder's target. Retry only
        // re-runs the attach: the resurrect metadata was consumed at the
        // original insert, so the sim spec's nil defaults are correct here.
        let spec: PendingAttachSpec
        switch pending.target {
        case let .sim(udid):
            spec = simAttachSpec(tab: tabID, udid: udid, displayName: pending.displayName)

        case let .device(deviceId):
            spec = deviceAttachSpec(tab: tabID, deviceId: deviceId, displayName: pending.displayName)
        }
        let task = Task { @MainActor [weak self] in
            _ = await self?.runAttach(tab: tabID, pendingId: pendingId, spec: spec)
            self?.attachTasks[pendingId] = nil
        }
        attachTasks[pendingId] = task
    }

    /// Cancel/close a pending pane: cancel the in-flight attach Task and
    /// drop the placeholder leaf. The Task's post-await guard closes any
    /// daemon pane that materializes after this, so a cancel mid-attach
    /// can't leak. The in-flight cancel always detaches (we never power
    /// off a device whose attach we didn't finish), so `mode` is advisory:
    /// the leaf removal itself ignores it.
    private func cancelPendingPane(
        tab tabID: TabID,
        pendingId: PendingPaneID,
        mode: PaneCloseMode
    ) {
        _ = mode
        attachTasks[pendingId]?.cancel()
        attachTasks[pendingId] = nil
        workspace.windowContaining(tab: tabID)?.tabs.removePendingPane(
            id: pendingId,
            fromTab: tabID
        )
    }

    private func detachDevicePane(
        tab tabID: TabID,
        deviceId: String,
        mode: PaneCloseMode
    ) async {
        guard let window = workspace.windowContaining(tab: tabID),
            let pane = window.tabs.tab(id: tabID)?.devicePanes
                .first(where: { $0.deviceId == deviceId }) else { return }
        try? await daemon.closePane(paneId: pane.paneId, mode: mode)
        window.tabs.removeDevicePane(deviceId: deviceId, fromTab: tabID)
    }

    /// Daemon-side teardown for a tab being closed: close each sim pane,
    /// fan out device.shutdown across owned booted sims on `.shutdown`
    /// (session.close itself ignores `mode`), then close every
    /// terminal pane's session. The owned-booted fan-out checks each
    /// terminal session for ownership because sims may be linked to
    /// non-primary terminals.
    private func closeTabRecords(_ tab: TabState, mode: PaneCloseMode) async {
        // Closing tombstone: this method cancels privacy work but then
        // `await`s several daemon teardown RPCs while the tab is STILL in the
        // workspace (removal happens synchronously at the call site after we
        // return). A cancelled transition's late reply arriving during those
        // awaits would otherwise pass `scheduleReconcile`'s guards (not
        // shut down, tab still present) and resurrect a reconcile. The
        // tombstone blocks that; the `defer` drops it just before the
        // synchronous `removeTab` (no `await` between, so no reply can slip
        // into the gap, and after removal the workspace check takes over).
        closingTabs.insert(tab.id)
        defer { closingTabs.remove(tab.id) }
        // Cancel any in-flight attach for this tab. The attach Task's
        // post-await guard closes a daemon pane that materializes after
        // the tab is gone, so a tab closed mid-attach can't leak.
        for pending in tab.pendingPanes {
            attachTasks[pending.id]?.cancel()
            attachTasks[pending.id] = nil
        }
        // Cancel any in-flight privacy transition or snapshot reconcile for
        // the closing tab so neither outlives it.
        privacyTransitions[tab.id]?.task.cancel()
        privacyTransitions[tab.id] = nil
        privacyReconcileTasks[tab.id]?.cancel()
        privacyReconcileTasks[tab.id] = nil
        for pane in tab.simPanes {
            try? await daemon.closePane(paneId: pane.paneId, mode: mode)
        }
        // Device panes tear down the daemon pane + IOSurface stream the
        // same way; `mode` is moot for the physical device itself (we
        // never power it off, closing the pane just drops the mirror).
        for pane in tab.devicePanes {
            try? await daemon.closePane(paneId: pane.paneId, mode: mode)
        }
        if mode == .shutdown {
            let owned = (try? await daemon.deviceList(scope: .owned)) ?? []
            let tabSessionIds = Set(tab.terminals.map(\.sessionId))
            for device in owned
            where tabSessionIds.contains(device.ownedBySession ?? "")
                && device.state == "Booted" {
                try? await daemon.shutdownDevice(udid: device.udid)
            }
        }
        for terminal in tab.terminals {
            try? await daemon.closeSession(
                sessionId: terminal.sessionId,
                capability: terminal.capability,
                mode: mode
            )
            // On `.shutdown` the scratch dir is gone; on `.detach` it stays
            // as the orphan record so a future cold start re-offers the sim.
            if mode == .shutdown {
                SessionEnvironment.cleanup(sessionId: terminal.sessionId)
            }
        }
    }

    // MARK: - Helpers

    /// Mint a fresh window id from the single global counter: used by
    /// the tab tear-off coordinator to build a new window out-of-band
    /// (without `.openWindow`, which would also create a session/tab).
    /// Keeping the mint here preserves the one-counter invariant that
    /// `windowContaining` / `window(id:)` lookups depend on.
    func mintWindowID() -> WindowID { allocateWindowID() }

    /// Whether `windowID`'s close is in progress. The tab-transfer coordinator
    /// consults this to reject a move into or out of a closing window, freezing
    /// its membership at the authorized set.
    func isWindowClosing(_ windowID: WindowID) -> Bool { closingWindows.contains(windowID) }

    private func allocateWindowID() -> WindowID {
        defer { nextWindowValue += 1 }
        return WindowID(value: nextWindowValue)
    }

    private func allocateTabID() -> TabID {
        defer { nextTabValue += 1 }
        return TabID(value: nextTabValue)
    }

    private func allocateTerminalPaneID() -> TerminalPaneID {
        defer { nextTerminalValue += 1 }
        return TerminalPaneID(value: nextTerminalValue)
    }

    private func allocatePendingPaneID() -> PendingPaneID {
        defer { nextPendingValue += 1 }
        return PendingPaneID(value: nextPendingValue)
    }

    private func logError(_ message: String) {
        FileHandle.standardError.write(Data("deviceterm: \(message)\n".utf8))
    }
}
