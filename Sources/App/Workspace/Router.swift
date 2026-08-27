// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The single navigation dispatch point. Every Route is
/// enqueued onto a serial drain (one AsyncStream<Route> consumer
/// Task), so navigation is ordered and non-reentrant even though
/// each handler awaits daemon work. The handler performs the daemon
/// *record* operations (session.create, device.attach, pane.closeById,
/// session.close, the shutdown fan-out) and mutates the nav view
/// models; the AppKit glue reconciles its controllers (views, the
/// session env, and pane subscriptions) to that state. Menu actions,
/// the discovery/resurrect loops, and orphan re-attach all dispatch
/// here: one path for everything.
@MainActor
final class Router {
    /// Wire codes for a *definite* pre-commit protection rejection: the
    /// daemon validated and refused **before** the atomic mutation, so this
    /// batch never committed. These are **terminal**: the transition reports
    /// failure and stops (retry can't succeed), then reconciles presentation
    /// from a fenced `session.protectionSnapshot`, never a local guess, since
    /// the daemon's actual state may be unprotected OR protected (an older send
    /// have committed). Everything *not* in this set (a catch-all
    /// serverError (-32000), a dropped connection) is an indeterminate
    /// transport loss that may have landed *after* the mutation, so it stays
    /// fail-closed hidden and retries with a fresh revision. A since-closed
    /// session in the batch is caught earlier by the membership re-read
    /// (reapply over the live set), before this classification runs.
    private static let definiteProtectionRejectionCodes: Set<Int> = [
        -32_602,  // invalidParams (malformed batch / bad UUID)
        -32_001,  // unauthorized (unknown session in the batch)
        -32_011   // scopeViolation (not the validated GUI peer, e.g. --smoke UDS)
    ]

    let workspace: WorkspaceViewModel

    private let daemon: any SessionControlling & DeviceControlling & PaneControlling
        & PhysicalDeviceControlling
    /// Shared with `DaemonClient` so caller-owned attach deadlines land in the
    /// same method/lane windows as ordinary client-owned bounds. Nil in Router
    /// tests that do not exercise diagnostics.
    private let rpcPerformance: RPCPerformanceDiagnostics?
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
    /// the serial drain into one of these so navigation stays responsive.
    /// Removed by each task on completion; each task's value is whether the
    /// pane mounted, which the orphan batch owner aggregates and every other
    /// caller discards.
    ///
    /// Quit is the only thing that cancels them. Closing a placeholder or its
    /// tab instead mutates nav state and lets `runAttach` observe that after
    /// its await, which keeps every reply on one reconciliation path rather
    /// than splitting it between that path and `Deadline.wait`'s late cleanup
    /// (see `cancelPendingPane`).
    private var attachTasks: [PendingPaneID: Task<Bool, Never>] = [:]
    /// In-flight orphan-reattach batch owners, keyed by tab and then by a
    /// per-batch token (one batch per adopted record, and a tab can adopt
    /// several). Each owner spawns the record's attaches, aggregates their
    /// outcomes, and makes the session-dir cleanup decision when the last one
    /// settles, so `addTab` hands the work off and returns to the drain. Its
    /// children are ordinary `attachTasks` entries and keep running when the
    /// tab closes; only the owner is cancelled, which is what stops a partial
    /// batch from cleaning up afterwards.
    private var orphanBatchTasks: [TabID: [Int: Task<Void, Never>]] = [:]
    private var nextOrphanBatchToken = 1
    /// Panes whose detach was deferred because another attach for the same
    /// target was still in flight, keyed by that (normalized) target. Emptied
    /// by `reconcileDeferredDetaches` once nothing is attaching the target, so
    /// a replacement that fails can't silently keep a pane alive.
    private var deferredDetaches: [PaneTarget: Set<DeferredDetach>] = [:]
    /// The detach RPC currently in flight per (normalized) target. An attach
    /// for that target waits on it before sending, because a detach whose
    /// claim check has already passed WILL close the record, and daemon
    /// dispatch is non-FIFO: an attach sent into that gap can be handed the
    /// very pane being closed and mount it just in time to watch it die.
    /// Cleared by whichever detach installed the entry.
    ///
    /// The fence lasts as long as the GUI's wait on the close; a close that
    /// outlives that wait is made harmless by its admission id instead. See
    /// `detach`.
    private var detachTasks: [PaneTarget: Task<Void, Never>] = [:]
    /// In-flight tab-protection transitions, keyed by tab. The retry-until-ack
    /// loop that keeps the daemon and GUI converged lives off the serial
    /// drain (like `attachTasks`) so a lost response doesn't wedge
    /// navigation. Unlike an attach these hold no daemon identity worth
    /// recovering, so supersede / close / quit all cancel them outright.
    private var protectionTransitions: [TabID: ProtectionTransition] = [:]
    /// GUI-side supersession identity, one per `setTabProtected` call. It
    /// decides which transition *owns* the tab (cancel-previous, report
    /// the outcome, clear the record); it is NOT the wire ordering key.
    /// the daemon orders by `(epoch, revision)`, so GUI generations never
    /// cross the wire.
    private var nextProtectionGeneration = 1
    /// Superseding target per superseded generation: when a new transition
    /// replaces an in-flight one, its target is recorded here against the old
    /// generation, so the old transition's `defer` reports `.rejected` vs
    /// `.pending` deterministically, even if the superseder already committed
    /// and cleared. Each entry is removed by the superseded transition's own
    /// `defer`.
    private var supersededTargets: [Int: Bool] = [:]
    /// The client half of the wire ordering key. Monotonic per Router; a
    /// fresh value is stamped on every actual `setProtectedBatch` *send*
    /// (including retries and membership-expanded re-sends), never by a
    /// superseded task. The daemon pairs it with the connection epoch and
    /// rejects any send whose key doesn't dominate.
    private var nextProtectionRevision = 1
    /// Highest revision whose `applied: true` reply has been committed to
    /// tab presentation, per tab. Guards against a late lower-revision ack
    /// (from a send that already lost to a newer write) reverting the tab:
    /// the GUI commits a reply only when its revision advances this.
    private var lastCommittedProtectionRevision: [TabID: Int] = [:]
    /// One in-flight snapshot-reconciliation task per tab. It retries
    /// (fresh revision, backoff) until an authoritative fenced result or a
    /// newer transition takes ownership, so a lost/unfenced reply can't
    /// abandon the tab pending forever. A new transition cancels it.
    private var protectionReconcileTasks: [TabID: Task<Void, Never>] = [:]
    /// The client half of the cohort wire ordering key. A separate counter
    /// from the protection revision: the daemon fences each cohort on its
    /// own stored `(epoch, revision)` key, so the two method families never
    /// order against each other. Fresh value per actual send, retries
    /// included.
    private var nextCohortRevision = 1
    /// One in-flight cohort reconcile per tab, cancel-and-replace on every
    /// trigger. No generation guard: unlike protection there is no A/B
    /// target to misreport, the target is always the tab's current
    /// membership, and each loop pass re-derives it from live state.
    /// Entries are replaced on reschedule and cancelled on tab close and
    /// shutdown; a completed task's stale entry is harmless to cancel.
    private var cohortReconcileTasks: [TabID: Task<Void, Never>] = [:]
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
    /// monotonic token. A protection transition beginning while a create is in
    /// flight waits for it before snapshotting session ids, so the batch
    /// can't miss a session minted in the pre-transition state and leave it
    /// exposed under a newly-protected tab. Creates that *start* after a
    /// transition inherit its target instead (no wait).
    private var inFlightCreates: [TabID: Set<Int>] = [:]
    private var nextCreateToken = 1
    /// The owned-sim re-assertion currently converging, if any. Held because
    /// it retries unanswered requests until one answers, its window closes, it
    /// is cancelled, or a newer connection supersedes it, so unlike the
    /// one-shot calls around it there is something for quit to stop.
    private var ownershipRestoreTask: Task<Void, Never>?
    /// Which sims deviceterm owns, mirrored from app-wide discovery so the
    /// answer outlives the helper that gave it. Recovery re-asserts it against
    /// a replacement helper, which is the only way a sim with no pane comes
    /// back: nothing else the GUI can act on automatically holds it. See
    /// `OwnedSimRoster`.
    private let ownedSims: OwnedSimRoster
    /// One daemon-wide `.owned` read per cadence. Tabs subscribe for their
    /// own attribution/attach decision, including while their window is hidden.
    private let ownedSimDiscovery: OwnedSimDiscoveryCoordinator
    private lazy var bootClaims = BootClaimCoordinator(
        daemon: daemon,
        didPromote: { [weak self] udid, sessionId, generation in
            self?.noteSimOwned(udid: udid, sessionId: sessionId, generation: generation)
        }
    )
    /// How long an attach may run before its placeholder flips to failed with
    /// Retry. Generous because the work behind it genuinely is: acquiring a
    /// simulator's display and HID, or bringing up a device tunnel. The call
    /// itself is not cancelled at the deadline, so a pane arriving afterwards
    /// is still reconciled (detached, or kept if something has since claimed
    /// its target) rather than stranded. Tests shorten it.
    var attachDeadlineNanos: UInt64 = 120_000_000_000
    /// Backoff between owned-sim re-assertion attempts, from 200ms doubling to
    /// a 2s cap, and the wall-clock window they run inside. Thirty seconds
    /// bounds how long an UNANSWERED request may keep being retried; a request
    /// the helper answers ends the loop whatever it took. See
    /// `restoreSimOwnership` for why the bound is a safety property. Tests
    /// shorten them.
    var restoreRetryBaseNanos: UInt64 = 200_000_000
    var restoreRetryCapNanos: UInt64 = 2_000_000_000
    var restoreWindow: Duration = .seconds(30)
    /// Deadline for an awaited `applyTabProtection` to report `.pending` when
    /// the daemon is slow, so a stalled RPC can't wedge the serial command
    /// drain. Kept below the daemon's 5s back-channel timeout; tests
    /// shorten it.
    var protectionOutcomeDeadlineNanos: UInt64 = 3_000_000_000
    /// How long a close gesture waits for `beginClose`'s authoritative
    /// verdict before proceeding on the binary tombstone fallback. Bounded
    /// so a stalled daemon can't wedge a tab close; the daemon still
    /// converges its own side through the `session.close` seam. Tests
    /// shorten it.
    var cohortCloseDeadlineNanos: UInt64 = 3_000_000_000

    init(
        workspace: WorkspaceViewModel,
        daemon: any SessionControlling & DeviceControlling & PaneControlling
        & PhysicalDeviceControlling,
        rpcPerformance: RPCPerformanceDiagnostics? = nil,
        detectWorktreeName: @escaping @MainActor () -> String? = {
            WorktreeName.detect(cwd: FileManager.default.currentDirectoryPath)
        }
    ) {
        self.workspace = workspace
        self.daemon = daemon
        self.rpcPerformance = rpcPerformance
        self.detectWorktreeName = detectWorktreeName
        let ownedSims = OwnedSimRoster()
        self.ownedSims = ownedSims
        self.ownedSimDiscovery = OwnedSimDiscoveryCoordinator(
            daemon: daemon,
            ownedSims: ownedSims
        )
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
        if case let .closeWindow(windowID, _, _) = route {
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
        // Drop any in-flight attaches; a 10s tunnel bring-up must not wedge
        // quit. Cancelling ends the waiter, not the attach: a pane that lands
        // afterwards still reaches `Deadline.wait`'s cleanup, now racing a
        // process on its way out. Best-effort is the right trade here and only
        // here, because the GUI is going away, so there's nobody to show the
        // pane to, and the daemon idle-exits and reaps orphans anyway.
        for task in attachTasks.values { task.cancel() }
        attachTasks.removeAll()
        for batch in orphanBatchTasks.values {
            for task in batch.values { task.cancel() }
        }
        orphanBatchTasks.removeAll()
        for transition in protectionTransitions.values { transition.task.cancel() }
        protectionTransitions.removeAll()
        for task in protectionReconcileTasks.values { task.cancel() }
        protectionReconcileTasks.removeAll()
        for task in cohortReconcileTasks.values { task.cancel() }
        cohortReconcileTasks.removeAll()
        ownershipRestoreTask?.cancel()
        ownershipRestoreTask = nil
        ownedSimDiscovery.shutdown()
        bootClaims.shutdown()
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

        case let .closeWindow(windowID, mode, authorizedTerminals):
            // Reserved synchronously in `dispatch`; always release it, even on
            // the guard's early return, so an absent window isn't left frozen.
            defer { closingWindows.remove(windowID) }
            guard let window = workspace.window(id: windowID) else { return }
            // Same re-check as `closeTab`, over every terminal the window
            // holds. `closingWindows` freezes transfers from the moment
            // the close was accepted, but a tab or terminal creation
            // already suspended in `createSession` when that happened
            // lands afterwards, and the caller was never cleared for it.
            if let authorizedTerminals,
                Set(window.tabs.tabs.flatMap { $0.terminals.map(\.sessionId) })
                    != authorizedTerminals {
                return
            }
            // Close ONLY the membership authorized at enqueue time
            // (`IntentDispatcher` checked it for foreign-protected tabs). The
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

        case let .openAutomationTab(windowID, cwd, cmd):
            guard let window = workspace.window(id: windowID) else { return }
            await addTab(
                to: window,
                role: .automation,
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

        case let .closeTab(windowID, tabID, mode, authorizedTerminals):
            guard let window = workspace.window(id: windowID),
                let tab = window.tabs.tab(id: tabID) else { return }
            // Membership the caller was cleared over, re-checked here
            // because authorization ran before this reached the drain.
            // Any change abandons the close: a terminal that arrived
            // since is a session nobody authorized destroying, and one
            // that left makes the decision moot.
            if let authorizedTerminals,
                Set(tab.terminals.map(\.sessionId)) != authorizedTerminals {
                return
            }
            await closeTabRecords(tab, mode: mode)
            // Re-resolve the tab's window: a cross-window move (run outside the
            // drain by the AppDelegate transfer coordinator) can relocate it
            // during the teardown awaits, making the captured `window` stale.
            // Remove it from wherever it now lives, else it survives with its
            // sessions closed and a late protection reply could resurrect it once
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

        case let .setTabProtected(tabID, isProtected):
            setTabProtected(tab: tabID, isProtected: isProtected)

        case let .attachSimPane(tabID, udid, displayName, family):
            attachPaneOptimistically(
                tab: tabID,
                spec: simAttachSpec(
                    tab: tabID,
                    udid: udid,
                    displayName: displayName,
                    family: family
                )
            )

        case let .resurrectSimPane(tabID, udid):
            await resurrectSimPane(tab: tabID, udid: udid)

        case let .resurrectDevicePane(tabID, deviceId):
            await resurrectDevicePane(tab: tabID, deviceId: deviceId)

        case let .detachSimPane(tabID, udid, mode, expecting):
            await detachPane(
                tab: tabID,
                udid: udid,
                mode: mode,
                expecting: expecting
            )

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

        case .recoverPanes:
            recoverPanes()
        }
    }

    /// Bring the workspace's device-backed panes back after a helper restart,
    /// and re-assert the sims that no pane carries (see
    /// `restoreSimOwnership`).
    ///
    /// Each pane becomes an ordinary attaching placeholder in the slot it
    /// already holds, and the normal attach path takes it from there: it
    /// mounts with whatever pane id and admission the attach returns, or fails
    /// in place with Retry and Close. A replacement helper returns fresh
    /// values; one that survived the reconnect returns its existing record.
    ///
    /// Nothing here is special-cased for recovery, so a sim that was shut down
    /// while the helper was dead surfaces the same failed placeholder any
    /// other unreachable attach would, rather than vanishing.
    ///
    /// The workspace is the snapshot. Everything the re-attach needs (the
    /// target, the tab, the slot, the placeholder's size hint) is already
    /// nav state, and taking it now rather than before the restart means a
    /// pane the user closed in between is simply not recovered.
    ///
    /// The old pane id is dropped without being closed. A replacement daemon
    /// cannot know it, and a daemon that survived the reconnect hands the
    /// owning session that same record back during the re-attach, so closing
    /// it would only retire the thing being recovered.
    private func recoverPanes() {
        restoreSimOwnership()
        for window in workspace.windows {
            for tab in window.tabs.tabs {
                // One numbering covering every sim in the tab, mounted or
                // still coming back from an earlier recovery, so the two can't
                // be handed the same position. See `simRecoveryOrder`.
                let order = simRecoveryOrder(in: tab)
                for pane in tab.simPanes {
                    reattachSimPaneInPlace(
                        pane,
                        atIndex: order[pane.udid.lowercased()],
                        tab: tab.id,
                        window: window
                    )
                }
                for pane in tab.devicePanes {
                    recoverDevicePane(pane, tab: tab.id, window: window)
                }
                // An already-failed placeholder is the other thing a restart
                // leaves behind. A recovery interrupted by a second restart
                // loses its attaches to the dying connection, and those panes
                // are no longer mounted, so the loops above cannot see them:
                // the promise that panes come back by themselves would hold
                // for the first restart and not the second. Retrying is also
                // right for a placeholder that failed for its own reasons,
                // since the outcome lands in the same slot with the same
                // affordances either way.
                //
                // `retryPendingPane` guards on the `.failed` phase, which is
                // what keeps this off the placeholders inserted just above
                // (they are `.attaching`) and off any attach still running.
                for pending in tab.pendingPanes {
                    if case let .sim(udid) = pending.target {
                        window.tabs.setPendingIndex(
                            order[udid.lowercased()],
                            id: pending.id,
                            inTab: tab.id
                        )
                    }
                    retryPendingPane(tab: tab.id, pendingId: pending.id)
                }
            }
        }
    }

    /// Tell the helper behind a new connection which sims deviceterm still
    /// owns. It may be a replacement or the one that answered before; the
    /// re-assertion is idempotent either way.
    ///
    /// Panes carry their own sims back: re-attaching one records ownership on
    /// its way through. This is for the sims nothing carries, the ones the
    /// user detached and left running, which a fresh helper would otherwise
    /// treat as somebody else's and drop from the running-sim count and the
    /// shut-down prompts.
    ///
    /// Off the drain, like every other daemon call recovery makes. Ordering
    /// against the pane re-attaches doesn't matter: a sim reached by both gets
    /// the same owner either way, and the helper keeps whichever attribution
    /// landed first rather than letting the second overwrite it.
    ///
    /// Tracked, so `shutdown` or a superseding recovery can cancel it.
    ///
    /// The claims are re-read each pass, so a sim owned since the last attempt
    /// joins the batch, and a newer connection taking over ends this loop
    /// rather than racing its own.
    ///
    /// Retries only calls the helper never answered, and never a claim it
    /// answered and declined.
    ///
    /// The helper judges a claim on current boot state, and refuses one that
    /// conflicts with attribution it already holds. It reports no reason, so
    /// "declined" covers a sim that shut down as well as one still Booting.
    /// Re-asserting either is asserting a claim against whatever holds that
    /// udid at some later moment, which is how another
    /// tool's boot of the same udid gets claimed as deviceterm's. A declined
    /// claim is therefore dropped, not retried: a sim still Booting when the
    /// helper EVALUATES the claim loses it, and a pane-backed one still comes
    /// back through recovery's Retry. Telling the two apart needs a per-udid reason
    /// on the wire, which this doesn't have.
    ///
    /// An unanswered call is different: the helper evaluated nothing, so
    /// nothing was learned about any sim and re-sending asserts no more than
    /// the first attempt did. Those retry, inside a wall-clock window that
    /// opens when re-assertion begins and bounds how long after that a claim
    /// can still land. Wall clock rather than an attempt count because each
    /// attempt carries the client's own request deadline, so a fixed number of
    /// attempts spans an unpredictable stretch of real time.
    private func restoreSimOwnership() {
        guard let pending = ownedSims.beginRestore() else { return }
        let generation = pending.generation
        let base = restoreRetryBaseNanos
        let cap = restoreRetryCapNanos
        let deadline = ContinuousClock.now.advanced(by: restoreWindow)
        ownershipRestoreTask?.cancel()
        ownershipRestoreTask = Task { @MainActor [weak self] in
            var backoff = base
            while true {
                // Re-acquired each pass, so the loop can't keep the Router
                // alive, and so a sim owned since the last attempt joins the
                // batch. The deadline is checked HERE rather than only before
                // sleeping, so no attempt is sent once the window has closed.
                guard let self,
                    ContinuousClock.now < deadline,
                    self.ownedSims.isRestorePending(generation),
                    let restore = self.ownedSims.beginRestore()
                else { break }
                if await self.answered(restore.claims) {
                    self.ownedSims.settle(generation: generation)
                    return
                }
                guard (try? await Task.sleep(nanoseconds: backoff)) != nil else { break }
                backoff = min(backoff * 2, cap)
            }
            self?.ownedSims.settle(generation: generation)
        }
    }

    /// Send one batch; true when the helper answered at all, whatever it took.
    ///
    /// An answer settles the matter even when some claims were declined,
    /// because the helper looked and said no and re-asking can only put the
    /// question to a different simulator later. Only silence is worth
    /// repeating.
    private func answered(_ claims: [RestoredSimOwnership]) async -> Bool {
        guard !claims.isEmpty else { return true }
        do {
            _ = try await daemon.restoreOwnership(devices: claims)
            return true
        } catch {
            logError("device.restoreOwnership failed: \(error)")
            return false
        }
    }

    /// Claim the roster-read slot for a poll about to run, or nil when another
    /// read holds it. Only one roster read runs at a time because the daemon
    /// vends no snapshot revision to order overlapping answers.
    ///
    /// Release it with `endOwnedSimsRead` on every path out, including failure
    /// and cancellation.
    func beginOwnedSimsRead() -> Int? { ownedSims.beginRead() }

    func endOwnedSimsRead(_ token: Int) { ownedSims.endRead(token) }

    /// One successful app-wide `device.list({scope: "owned"})` read, carrying
    /// the connection that answered it and the token it was issued under. The
    /// mirror is what makes the answer outlive the helper.
    ///
    /// A failed read must not arrive here as an empty roster: "the helper
    /// didn't answer" and "the helper owns nothing" are opposite facts.
    func noteOwnedSims(_ entries: [DeviceListEntry], generation: Int, read: Int) {
        ownedSims.record(entries, generation: generation, read: read)
    }

    /// Observe the one app-wide owned-sim snapshot stream. Registration is tied
    /// to a tab VC's lifetime, not its visibility, because agents keep working
    /// in background tabs and minimized windows.
    func addOwnedSimDiscoveryObserver(
        _ observer: @escaping @MainActor ([DeviceListEntry]) -> Void
    ) -> OwnedSimDiscoveryObserverToken {
        ownedSimDiscovery.addObserver(observer)
    }

    func removeOwnedSimDiscoveryObserver(_ token: OwnedSimDiscoveryObserverToken) {
        ownedSimDiscovery.removeObserver(token)
    }

    /// A shutdown the GUI just made succeed. The daemon has dropped the sim,
    /// and a claim left standing until the next poll is one recovery would
    /// re-assert against a sim something else may since have booted.
    func noteSimShutdown(udid: String) {
        ownedSims.noteShutdown(udid: udid)
    }

    /// A call that recorded sim ownership daemon-side just succeeded. Tells
    /// the mirror now rather than leaving it to a poll up to two seconds away,
    /// the window in which a sim can be owned and then detached with nothing
    /// left for recovery to act on.
    ///
    /// `generation` is the connection the call itself reported, captured with
    /// its answer. Sampling the current one here instead would name a
    /// replacement installed in between, and the mirror would go on to believe
    /// that helper's empty roster and drop the claim it just made.
    func noteSimOwned(udid: String, sessionId: String?, generation: Int) {
        ownedSims.noteOwned(udid: udid, sessionId: sessionId, generation: generation)
    }

    /// A new connection is live. Treat it as potentially backed by a
    /// replacement helper until recovery has re-asserted the claims: a
    /// reconnect installs a new connection, which may or may not reach the
    /// daemon that answered the last one.
    func noteConnectionReplaced(generation: Int) {
        ownedSims.connectionReplaced(generation: generation)
        bootClaims.connectionReplaced()
    }

    func acceptBootClaim(
        sessionId: String,
        claim: BootClaimEvidence,
        deadlineNanoseconds: UInt64
    ) {
        bootClaims.accept(
            sessionId: sessionId,
            claim: claim,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }

    func beginGUIBootClaim(udid: String, sessionId: String) -> BootClaimEvidence {
        bootClaims.beginGUIBoot(udid: udid, sessionId: sessionId)
    }

    func finishGUIBootRequest(attemptId: String, outcome: BootClaimRequestOutcome) {
        bootClaims.bootRequestFinished(attemptId: attemptId, outcome: outcome)
    }

    func resumeBootClaimsAfterSessionRestore() {
        bootClaims.resumeAfterSessionRestore()
    }

    /// Where each of a tab's sims belongs in the typed array once recovery
    /// settles, keyed by lowercased UDID.
    ///
    /// This rebuilds the *array's* order, which is not the tree's: a sim
    /// mounts adjacent to its terminal, so the tree shows the newest first,
    /// while the array is mount order. Only the array's order is being
    /// restored here; the tree keeps every pane's slot on its own, because
    /// each placeholder replaces its leaf in place.
    ///
    /// The numbering has to agree between panes that are still mounted and
    /// placeholders that have already left the array. A placeholder an earlier
    /// recovery left failed still knows the position it held, so it keeps it;
    /// the mounted panes then fill the positions nothing has claimed, in the
    /// order they sit in the array. Numbering the array alone would hand its
    /// first entry position 0 while a failed placeholder still held 0, and the
    /// two would land on top of each other.
    private func simRecoveryOrder(in tab: TabState) -> [String: Int] {
        var order: [String: Int] = [:]
        var claimed: Set<Int> = []
        for pending in tab.pendingPanes {
            guard case let .sim(udid) = pending.target,
                let position = pending.atIndex,
                !claimed.contains(position) else { continue }
            claimed.insert(position)
            order[udid.lowercased()] = position
        }
        var free = (0..<(tab.simPanes.count + claimed.count)).filter { !claimed.contains($0) }
        for pane in tab.simPanes {
            guard !free.isEmpty else { break }
            order[pane.udid.lowercased()] = free.removeFirst()
        }
        return order
    }

    /// Swap a mounted sim pane for an attaching placeholder in the leaf it
    /// already holds, then re-run the attach against it.
    ///
    /// Shared by helper recovery and the post-reboot resurrect. Both must
    /// preserve the pane's slot, including its split axis, nesting, and
    /// divider proportions keyed by tree path. They differ only in whether
    /// the caller must first close a surviving daemon record.
    /// `PaneTreeOps.replace` under `replaceSimPaneWithPending` is what makes
    /// that preservation hold: replacing in place keeps the tree and its
    /// stored extents, while removing and reinserting can collapse a
    /// two-child parent, and resets the reinserted leaf's extent.
    ///
    /// A pane with no entry in the recovery order appends rather than being
    /// given a guessed position.
    private func reattachSimPaneInPlace(
        _ pane: SimPaneState,
        atIndex index: Int?,
        tab tabID: TabID,
        window: WindowState
    ) {
        let pendingId = allocatePendingPaneID()
        window.tabs.replaceSimPaneWithPending(
            udid: pane.udid,
            pending: PendingPaneState(
                id: pendingId,
                target: pane.target,
                // The placeholder keeps the label the pane was already
                // showing, so the slot doesn't rename itself to a UDID stub
                // while the attach runs, but marks it label-only: that label
                // is the composed "Name · Type" form, and the attach resolves
                // the bare name itself. See `PendingPaneState.resolvesName`.
                displayName: pane.displayName,
                family: pane.family,
                atIndex: index,
                resolvesName: true
            ),
            inTab: tabID
        )
        spawnAttach(
            tab: tabID,
            pendingId: pendingId,
            spec: simAttachSpec(tab: tabID, udid: pane.udid, displayName: nil)
        )
    }

    private func recoverDevicePane(
        _ pane: DevicePaneState,
        tab tabID: TabID,
        window: WindowState
    ) {
        let pendingId = allocatePendingPaneID()
        window.tabs.replaceDevicePaneWithPending(
            deviceId: pane.deviceId,
            pending: PendingPaneState(
                id: pendingId,
                target: pane.target,
                displayName: pane.displayName,
                family: pane.family
            ),
            inTab: tabID
        )
        // Unlike a sim, the label is handed straight back as the name. There
        // is nothing to resolve it from on this path (see `deviceAttachSpec`),
        // and nothing composes a device type onto it, so the picker's name
        // survives the restart instead of decaying to a deviceId stub.
        spawnAttach(
            tab: tabID,
            pendingId: pendingId,
            spec: deviceAttachSpec(
                tab: tabID,
                deviceId: pane.deviceId,
                displayName: pane.displayName
            )
        )
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
            // "Open Automation Tab" menu's route passes
            // `.automation`. The daemon may reject the request (e.g.
            // an older daemon that doesn't accept the role parameter
            // returns `.agent`); trust the response's `role` rather
            // than the requested one so the tab's recorded role
            // matches what's actually on the wire.
            let name = detectWorktreeName()
            // A freshly-opened tab is always unprotected; a protected tab is only
            // ever reached by toggling protection after it exists.
            let session = try await daemon.createSession(
                label: nil,
                name: name,
                role: role,
                initialProtected: false
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
            // Install the tab's cohort eagerly, so a device pane attached
            // later is born with a cohort to auto-bind to rather than
            // waiting on a reconcile raced in behind the attach.
            scheduleCohortReconcile(tab: tab.id)
            for orphan in reattach {
                startOrphanReattach(orphan, tab: tab.id)
            }
        } catch {
            logError("session.create failed: \(error)")
        }
    }

    /// Mount one adopted orphan record's sims, cleaning its session dir only
    /// once the record is fully adopted; otherwise the dir stays so the orphan
    /// is re-offered next launch. "Fully adopted" means every sim either
    /// mounted here or was already claimed by this tab, and a sim already
    /// claimed counts however its own attach is doing, including a placeholder
    /// still attaching or already failed: the record has been handed over
    /// either way, and re-offering a target the tab is already showing would
    /// stack a duplicate.
    ///
    /// The placeholders go in synchronously, so the sims appear immediately
    /// and are already closable by the time this returns, but the attaches
    /// themselves run off the serial drain under a batch owner. Awaiting them
    /// inline holds the drain for the length of a cold-start mount, and one
    /// attach that doesn't come back then freezes every later route, tab
    /// switching included, which is exactly what the placeholder exists to
    /// avoid.
    private func startOrphanReattach(_ orphan: OrphanRecord, tab tabID: TabID) {
        var children: [Task<Bool, Never>] = []
        for sim in orphan.liveSims {
            // Re-resolved each pass so a record naming the same udid twice
            // dedups against the placeholder the previous pass just added.
            guard let window = workspace.windowContaining(tab: tabID),
                let live = window.tabs.tab(id: tabID) else {
                // The tab is gone: stand in an unmounted sim so the batch
                // can't go on to claim a full adoption.
                children.append(Task { false })
                continue
            }
            let target = PaneTarget.sim(udid: sim.udid)
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
                toTab: tabID,
                spawningTerminal: live.primaryTerminal.id
            )
            children.append(
                spawnAttach(
                    tab: tabID,
                    pendingId: pendingId,
                    spec: simAttachSpec(
                        tab: tabID,
                        udid: sim.udid,
                        displayName: sim.displayName
                    )
                )
            )
        }
        let token = nextOrphanBatchToken
        nextOrphanBatchToken += 1
        let owner = Task { @MainActor [weak self] in
            var mounted = true
            for child in children where await child.value == false {
                mounted = false
            }
            // Cancellation means the tab (or the app) went away mid-batch, so
            // the record is NOT fully adopted however its attaches landed.
            self?.finishOrphanReattach(
                orphan,
                tab: tabID,
                token: token,
                adopted: mounted && !Task.isCancelled
            )
        }
        orphanBatchTasks[tabID, default: [:]][token] = owner
    }

    /// Retire a finished orphan batch: drop the owner and, only on a fully
    /// adopted record, delete the session dir it was recovered from.
    private func finishOrphanReattach(
        _ orphan: OrphanRecord,
        tab tabID: TabID,
        token: Int,
        adopted: Bool
    ) {
        orphanBatchTasks[tabID]?.removeValue(forKey: token)
        if orphanBatchTasks[tabID]?.isEmpty == true {
            orphanBatchTasks[tabID] = nil
        }
        if adopted { OrphanRecovery.cleanup([orphan.sessionDir]) }
    }

    /// Start a placeholder's attach RPC off the serial drain and register it
    /// under `pendingId`, which is how quit reaches it to cancel. Returns the
    /// task for the one caller that needs the outcome.
    @discardableResult
    private func spawnAttach(
        tab tabID: TabID,
        pendingId: PendingPaneID,
        spec: PendingAttachSpec
    ) -> Task<Bool, Never> {
        let task = Task { @MainActor [weak self] in
            let mounted = await self?.runAttach(
                tab: tabID,
                pendingId: pendingId,
                spec: spec
            ) ?? false
            self?.attachTasks[pendingId] = nil
            return mounted
        }
        attachTasks[pendingId] = task
        return task
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
        // effective-hidden* state: protected whenever the tab is hidden,
        // including mid-transition in EITHER direction. Never inherit a
        // transition's target: a protected→unprotected target would declassify the
        // new session (born daemon-unprotected) while the tab is deliberately
        // still protected until the daemon acks. The transition's membership
        // recheck then unprotects every session together only when it
        // commits. Register the create as in-flight first so a protection
        // transition beginning while this is suspended in `createSession`
        // waits for its session id before batching.
        let createdProtected = tab.isEffectivelyProtected
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
                initialProtected: createdProtected
            )
            // Re-resolve the tab's window after the await: a cross-window
            // `tab move` runs on the main actor outside the route drain and
            // can relocate (or close) the tab while `createSession` is
            // suspended. The `window` captured above would then be stale, so
            // `addTerminal` would silently no-op against the old window,
            // stranding a live daemon session that no pane references and that
            // a concurrent protection batch never covers. If the tab is gone,
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
            // Fold the new session into the tab's cohort so it can drive
            // (and discover) the tab's device panes. Until this applies
            // daemon-side, the new terminal's scoped calls are refused; the
            // CLI contract documents that brief window as caller-retried.
            scheduleCohortReconcile(tab: tabID)
            // Defense in depth. A transition in flight already covers this
            // session: it either waited for this create (in-flight when it
            // began) or this create inherited its target, and its
            // membership recheck folds in anything it missed; re-kicking it
            // here would only supersede (and mis-report) the awaited
            // transition. So only reconcile when NO transition is in flight
            // and the tab's EFFECTIVE state changed while `createSession`
            // awaited (the terminal was minted with stale protection). Compare
            // against `isEffectivelyProtected`, NOT committed `isProtected`: a
            // `.pendingProtected` (hidden-but-unresolved) tab is effectively
            // hidden, matching a terminal minted from a hidden tab, so it is
            // NOT re-kicked toward unprotected, which would reveal a tab mid-hide.
            if protectionTransitions[tabID] == nil,
                let liveTab = liveWindow.tabs.tab(id: tabID),
                liveTab.isEffectivelyProtected != createdProtected {
                setTabProtected(tab: tabID, isProtected: liveTab.isEffectivelyProtected)
            }
        } catch {
            logError("session.create failed: \(error)")
        }
    }

    /// Close one terminal pane in a tab. Refuses to drop the only
    /// remaining terminal; the caller should `closeTab` instead.
    /// An awaited `beginClose` attempt precedes the cap-authenticated
    /// `session.close`. The scratch dir is then wiped on `.shutdown`, and
    /// nav-state removal drops the entry so reconciliation tears the VC down.
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
        // Commit the daemon's verdict first, so the tombstone below records
        // the same answer the daemon acts on: siblings remain, so an applied
        // verdict is a promotion and the leaving terminal's boot claims
        // follow the successor. If `beginClose` is refused (the reap race)
        // or unanswered, the fallback records the disposition from `mode`.
        let verdict = await cohortBeginClose(
            cohortId: tab.cohortId,
            leaving: [terminal.sessionId],
            mode: mode
        )
        if let verdict {
            bootClaims.sessionClosed(terminal.sessionId, outcome: verdict)
        } else {
            bootClaims.sessionClosed(terminal.sessionId, mode: mode)
        }
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
        reconvergeProtectionIfTransitioning(tab: tabID)
    }

    /// Begin (or supersede) a tab-protection transition. Fail-closed and
    /// acknowledged:
    ///
    ///  - An unprotected→protected transition hides the tab **immediately**
    ///    (`.pendingProtected`), before any daemon round-trip, and only
    ///    commits to `.protected` on the ack. A protected→unprotected stays
    ///    hidden (its committed-protected state) until the ack.
    ///  - `runProtectionTransition` commits presentation only from authoritative
    ///    daemon signals: a tab is EXPOSED only by the owning transition's
    ///    highest-key unprotect `applied: true` or a fenced uniform-unprotected
    ///    `session.protectionSnapshot`. An indeterminate loss retries; a definite
    ///    rejection or a stale `applied: false` reconciles via a fenced
    ///    snapshot (never a local guess).
    ///  - Ordering is DAEMON-enforced by `(epoch, revision)` last-write-wins,
    ///    so the GUI does not serialize: a superseded send still in flight
    ///    simply loses (its key can't dominate). A rapid
    ///    protected→unprotected→protected converges on the last requested state,
///    and a
    ///    stale send (even one arriving after an XPC reconnect) can never
    ///    overwrite a newer one daemon-side.
    private func setTabProtected(
        tab tabID: TabID,
        isProtected: Bool,
        onFirstOutcome: (@MainActor (TabProtectionOutcome) -> Void)? = nil
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
        let generation = nextProtectionGeneration
        nextProtectionGeneration += 1
        // Fail-closed hide happens now, synchronously, before the first
        // suspension: an unprotected→protected is hidden the instant the user
        // acts even though the daemon hasn't confirmed.
        if isProtected, liveTab.protectionState == .unprotected {
            window.tabs.setProtectionState(.pendingProtected, id: tabID)
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
        if let previous = protectionTransitions[tabID] {
            supersededTargets[previous.generation] = isProtected
            previous.task.cancel()
        }
        // A new transition takes ownership: cancel any snapshot reconcile
        // still retrying for this tab; the transition drives it now.
        protectionReconcileTasks[tabID]?.cancel()
        protectionReconcileTasks[tabID] = nil
        let task = Task { @MainActor [weak self] in
            guard let self else {
                // Router torn down. never leave an awaiter hanging.
                onFirstOutcome?(.pending)
                return
            }
            await self.runProtectionTransition(
                tab: tabID,
                isProtected: isProtected,
                generation: generation,
                awaitedCreates: awaitedCreates,
                onFirstOutcome: onFirstOutcome
            )
        }
        protectionTransitions[tabID] = ProtectionTransition(
            generation: generation,
            target: isProtected,
            task: task
        )
    }

    /// Awaited protection transition for the intent layer. Begins (or
    /// supersedes) the transition and resolves on its first decisive
    /// outcome: `.committed` (daemon applied it), `.rejected` (definitely
    /// refused, or abandoned by an opposite-state supersede), or `.pending`
    /// (unconfirmed because of a deadline, indeterminate transport loss,
    /// same-state supersession, or tab disappearance). Lets
    /// `tab set-protected` report the daemon's real state instead of an
    /// optimistic echo.
    func applyTabProtection(tab tabID: TabID, isProtected: Bool) async -> TabProtectionOutcome {
        await withCheckedContinuation { continuation in
            let gate = ProtectionOutcomeGate(continuation)
            setTabProtected(tab: tabID, isProtected: isProtected) { outcome in
                gate.resolve(outcome)
            }
            // Bound the wait so one slow/unresponsive daemon can't wedge the
            // serial command drain: report `.pending` after the deadline
            // while the transition keeps converging in the background. Kept
            // below the daemon's 5s back-channel command timeout.
            let deadline = protectionOutcomeDeadlineNanos
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: deadline)
                gate.resolve(.pending)
            }
        }
    }

    /// Drive one protection transition, then reconcile presentation ONLY from
    /// authoritative daemon signals, never a local heuristic. Fail-closed:
    /// hiding is immediate, revealing needs proof.
    ///
    ///  - A tab is EXPOSED (`.unprotected`) only by the OWNING transition's
    ///    highest-key unprotect `applied: true`, or by a fenced,
    ///    uniform-unprotected `session.protectionSnapshot`. Never from a
///    superseded
    ///    reply, an in-flight counter, or a "pending-implies-unprotected" guess.
    ///  - `applied: true` (owning, membership match, revision advances):
    ///    commit `.protected` / `.unprotected`; report `.committed`.
    ///  - `applied: false` (a higher key won, possibly another connection's)
    ///    or a **definite rejection**: clear and reconcile via a fenced
    ///    snapshot; the tab reveals only on a fenced uniform-unprotected result,
    ///    else stays hidden and unresolved.
    ///  - **indeterminate transport loss**: retry with a fresh revision.
    ///  - A SUPERSEDED reply commits nothing; the superseding transition (or
    ///    its own terminal reconcile) drives the tab.
    ///
    /// Membership recheck still applies: a terminal created fail-closed as
    /// protected while a batch is in flight is folded in by reapplying over
    /// the new session set before committing.
    private func runProtectionTransition(
        tab tabID: TabID,
        isProtected desiredProtected: Bool,
        generation: Int,
        awaitedCreates: Set<Int> = [],
        onFirstOutcome: (@MainActor (TabProtectionOutcome) -> Void)? = nil
    ) async {
        var backoffMs = 200
        // Report the first decisive outcome exactly once to an awaiting
        // intent caller. The `defer` is a safety net: any exit that didn't
        // already report (supersede, tab-gone) resolves as `.pending` so
        // an awaiter never hangs.
        var fired = false
        func fire(_ outcome: TabProtectionOutcome) {
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
            let superseder = supersededTargets[generation] ?? protectionTransitions[tabID]?.target
            supersededTargets[generation] = nil
            if let superseder, superseder != desiredProtected {
                fire(.rejected)
            } else {
                fire(.pending)
            }
        }
        // Wait for terminal creates that were already in flight when this
        // transition began: their sessions were minted in the
        // pre-transition state, so the batch must cover them. The tab is
        // already fail-closed hidden while we wait (set synchronously in
        // `setTabProtected`). Bails if a newer transition supersedes.
        while !awaitedCreates.isDisjoint(with: inFlightCreates[tabID] ?? []) {
            guard protectionTransitions[tabID]?.generation == generation else { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        while !Task.isCancelled {
            guard protectionTransitions[tabID]?.generation == generation else { return }
            guard let tab = workspace.windowContaining(tab: tabID)?.tabs.tab(id: tabID) else {
                // Tab closed mid-transition: nothing to converge.
                clearProtectionTransition(tabID, generation: generation)
                return
            }
            let sentIds = tab.terminals.map(\.sessionId)
            // Fresh revision per send: the daemon rejects a stale key, so
            // reusing one across attempts would make an idempotent retry
            // look stale. A superseded task never reaches here (guard above).
            let revision = nextProtectionRevision
            nextProtectionRevision += 1
            do {
                let result = try await daemon.setProtectedBatch(
                    sessionIds: sentIds,
                    isProtected: desiredProtected,
                    revision: revision
                )
                // A SUPERSEDED reply commits nothing itself. But it may have
                // changed the daemon (an older unprotect that finally
                // applied), so if NO transition is active to drive the tab,
                // reconcile from an authoritative snapshot; if a newer one is
                // active, it drives.
                guard protectionTransitions[tabID]?.generation == generation else {
                    // Reconcile ONLY if this reply is newer than the last
                    // committed revision. A newer transition that already
                    // committed (lastCommitted advanced past our revision) is
                    // authoritative: scheduling a reconcile would
                    // synchronously demote its correct state to `.pendingProtected`.
                    if protectionTransitions[tabID] == nil,
                        revision > (lastCommittedProtectionRevision[tabID] ?? 0) {
                        scheduleReconcile(tab: tabID)
                    }
                    return
                }
                if !result.applied {
                    // A higher-key write won daemon-side, possibly another
                    // connection's, whose state we can't infer locally. Clear
                    // and reconcile from an authoritative fenced snapshot.
                    clearProtectionTransition(tabID, generation: generation)
                    scheduleReconcile(tab: tabID)
                    return
                }
                guard let window = workspace.windowContaining(tab: tabID),
                    let liveTab = window.tabs.tab(id: tabID) else {
                    clearProtectionTransition(tabID, generation: generation)
                    return
                }
                if Set(liveTab.terminals.map(\.sessionId)) != Set(sentIds) {
                    // Membership changed while the batch was in flight:
                    // reapply over the new set with a fresh revision.
                    backoffMs = 200
                    continue
                }
                // Owning + applied + membership match. This is the one place a
                // unprotect may REVEAL the tab (the highest-key unprotect
                // write acknowledgement) and hiding is always safe. The
                // revision guard stops a late lower-key ack from overriding a
                // newer commit (e.g. a snapshot reconcile that already ran).
                if revision > (lastCommittedProtectionRevision[tabID] ?? 0) {
                    lastCommittedProtectionRevision[tabID] = revision
                    window.tabs.setProtectionState(
                        result.isProtected ? .protected : .unprotected,
                        id: tabID
                    )
                }
                clearProtectionTransition(tabID, generation: generation)
                fire(.committed)
                return
            } catch {
                if Task.isCancelled { return }
                guard protectionTransitions[tabID]?.generation == generation else {
                    // Superseded. An indeterminate loss may have committed the
                    // daemon; reconcile only if nothing is left to drive the
                    // tab AND this reply is newer than the last commit (else a
                    // newer transition already set the authoritative state).
                    if protectionTransitions[tabID] == nil,
                        revision > (lastCommittedProtectionRevision[tabID] ?? 0) {
                        scheduleReconcile(tab: tabID)
                    }
                    return
                }
                guard let liveTab = workspace.windowContaining(tab: tabID)?
                    .tabs.tab(id: tabID) else {
                    clearProtectionTransition(tabID, generation: generation)
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
                // unprotected OR protected, e.g. an older send committed). Only an
                // INDETERMINATE transport loss retries with a fresh revision,
                // reported as `.pending`. (`.rejected` also covers an opposite
                // supersede, see the `defer` above.) `scopeViolation` (-32011)
                // is a definite/terminal signature rejection on BOTH transports
                // now: the smoke UDS structural refusal AND a genuine XPC
                // signature mismatch (which retrying can't fix). The transient,
                // retryable validation-unavailable outcome is `notReadyCode`
                // (-32002), which the client's `request()` retries internally,
                // so it never surfaces here as a definite rejection.
                if case let DaemonClientError.daemon(code, message) = error,
                    Self.definiteProtectionRejectionCodes.contains(code) {
                    logError(
                        "session.setProtectedBatch refused for tab "
                        + "\(tabID.value): \(code) \(message)"
                    )
                    clearProtectionTransition(tabID, generation: generation)
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

    /// Present a tab as hidden-and-UNRESOLVED (`.pendingProtected`) when a
    /// reconcile can't get an authoritative answer. Demotes BOTH a
    /// `.unprotected` and a `.protected` tab: leaving a `.protected`
    /// tab as-is would falsely classify it committed-protected while its real
    /// daemon state is unknown. Idempotent (no-op if already pending).
    private func markProtectionUnresolved(tab tabID: TabID, window: WindowState) {
        guard window.tabs.tab(id: tabID)?.protectionState != .pendingProtected else { return }
        window.tabs.setProtectionState(.pendingProtected, id: tabID)
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
        protectionReconcileTasks[tabID]?.cancel()
        // Fail-closed SYNCHRONOUSLY, before the async snapshot task runs: the
        // triggering outcome (an `applied: false`, a rejection, a superseded
        // reply) means the tab's true daemon protection is now unknown. Leaving
        // it `.unprotected` would expose it to foreign callers, and leaving
        // it `.protected` would falsely present it as committed-protected,
        // for the whole (possibly stalled) read window. Mark it unresolved
        // now; the reconcile resolves it to an authoritative state.
        markProtectionUnresolved(tab: tabID, window: window)
        protectionReconcileTasks[tabID] = Task { @MainActor [weak self] in
            await self?.runProtectionReconcile(tab: tabID)
        }
    }

    /// Drive a tab's presentation to the daemon's authoritative protection via a
    /// fenced `session.protectionSnapshot`, retrying (fresh revision, backoff)
    /// until it gets an authoritative fenced result, a newer transition takes
    /// ownership, or a newer authoritative commit supersedes it. so a lost
    /// or unfenced reply never abandons the tab pending forever. Fail-closed:
    /// exposes the tab ONLY on a fenced uniform-unprotected result with unchanged
    /// membership *and* a revision that still leads the last commit; anything
    /// else stays hidden (and, when not yet authoritative, retries).
    private func runProtectionReconcile(tab tabID: TabID) async {
        var backoffMs = 200
        while !Task.isCancelled {
            // A transition owns the tab now: it drives; stop reconciling.
            guard protectionTransitions[tabID] == nil,
                let tab = workspace.windowContaining(tab: tabID)?.tabs.tab(id: tabID) else { return }
            let sessionIds = tab.terminals.map(\.sessionId)
            let revision = nextProtectionRevision
            nextProtectionRevision += 1
            let result: SessionProtectionSnapshotResult
            do {
                result = try await daemon.protectionSnapshot(sessionIds: sessionIds, revision: revision)
            } catch {
                // A `scopeViolation` (-32011) is a definite/terminal signature
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
            guard protectionTransitions[tabID] == nil,
                let window = workspace.windowContaining(tab: tabID),
                let liveTab = window.tabs.tab(id: tabID) else { return }
            // A newer authoritative commit already set the correct state while
            // we were reading. this snapshot is stale; NEVER apply a state
            // older than what's committed (this is the exposure guard: it
            // gates the presentation write itself, not just the counter).
            guard revision > (lastCommittedProtectionRevision[tabID] ?? 0) else { return }
            let membershipUnchanged = Set(liveTab.terminals.map(\.sessionId)) == Set(sessionIds)
            if result.fenced, membershipUnchanged {
                lastCommittedProtectionRevision[tabID] = revision
                if result.sessions.allSatisfy({ $0.state == .unprotectedState }) {
                    window.tabs.setProtectionState(.unprotected, id: tabID)
                    return
                }
                if result.sessions.allSatisfy({ $0.state == .protectedState }) {
                    window.tabs.setProtectionState(.protected, id: tabID)
                    return
                }
                // Fenced but MIXED: authoritative yet non-uniform (only a new
                // write resolves a genuine split). Present as
                // hidden-and-unresolved; a later transition reconciles.
                // Terminal: retrying can't change a genuine split.
                markProtectionUnresolved(tab: tabID, window: window)
                return
            }
            // Unfenced or membership-changed → not yet authoritative. Present
            // as hidden-and-unresolved (fail-closed) and retry until it
            // settles, never leave a stale committed classification.
            markProtectionUnresolved(tab: tabID, window: window)
            try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
            backoffMs = min(backoffMs * 2, 5_000)
        }
    }

    /// Re-kick an in-flight protection transition after a tab's terminal set
    /// changed, so the newly-added (or removed) session is folded into a
    /// fresh batch over the current membership. A no-op when no transition
    /// is in flight: a terminal added to a stable tab already inherits
    /// the right protection at `session.create`.
    private func reconvergeProtectionIfTransitioning(tab tabID: TabID) {
        guard let transition = protectionTransitions[tabID] else { return }
        // Reconverge toward the transition's target over the new membership.
        setTabProtected(tab: tabID, isProtected: transition.target)
    }

    /// Drop the transition record iff it's still the one identified by
    /// `generation` (a newer supersede may have replaced it).
    private func clearProtectionTransition(_ tabID: TabID, generation: Int) {
        if protectionTransitions[tabID]?.generation == generation {
            protectionTransitions[tabID] = nil
        }
    }

    /// Converge one tab's daemon cohort onto its live membership, retrying
    /// with backoff until the daemon applies it, the task is cancelled, the
    /// tab becomes unavailable, or a structural scope failure prevents retry.
    private func runCohortReconcile(tab tabID: TabID) async {
        var backoffMs = 200
        while !Task.isCancelled {
            switch await attemptCohortReconcile(tab: tabID) {
            case .applied, .abandoned:
                return

            case .retry:
                try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                backoffMs = min(backoffMs * 2, 5_000)
            }
        }
    }

    /// One `session.setCohort` reconcile computed from the tab's live state:
    /// complete ordered membership (array order is the daemon's inheritance
    /// order, so it must equal the GUI's own `terminals[0]` promotion rule),
    /// the primary terminal as representative, and every mounted device
    /// pane's `(paneId, attachment)` as a binding backstop for anything the
    /// admission-time auto-bind raced.
    private func attemptCohortReconcile(tab tabID: TabID) async -> CohortReconcileAttempt {
        guard !isShutdown, !closingTabs.contains(tabID),
            let tab = workspace.windowContaining(tab: tabID)?.tabs.tab(id: tabID) else {
            return .abandoned
        }
        let revision = nextCohortRevision
        nextCohortRevision += 1
        let params = SessionSetCohortParams(
            operation: .reconcile,
            cohortId: tab.cohortId.uuidString,
            revision: revision,
            members: tab.terminals.map(\.sessionId),
            representative: tab.primaryTerminal.sessionId,
            bindings: cohortBindings(for: tab)
        )
        do {
            let result = try await daemon.setCohort(params)
            guard result.applied else { return .retry }
            // An applied add-mode reply can still refuse individual bindings
            // (the pane's attachment moved, or the record was briefly
            // absent), and the wire contract makes the GUI the retry side.
            // Treat a refused binding as not-yet-converged: the next send
            // re-derives the pane set, and its fence value, from live state.
            let refused = (result.bindings ?? []).contains { !$0.bound }
            return refused ? .retry : .applied
        } catch {
            // `scopeViolation` (-32011) is a definite/terminal signature
            // rejection on both transports (the `--smoke` UDS structural
            // refusal, or a genuine XPC signature mismatch); retrying can't
            // succeed. Everything else, a definite rejection included, is
            // retried from re-derived live state: an `invalidParams` here
            // usually names a session that closed mid-flight, and the next
            // send no longer carries it.
            if case let DaemonClientError.daemon(code, _) = error, code == -32_011 {
                return .abandoned
            }
            return .retry
        }
    }

    /// The tab's mounted device panes as cohort bindings. A pane whose
    /// attach response predates the attachment field can't be fenced and is
    /// skipped; the admission-time auto-bind is what covers it.
    private func cohortBindings(for tab: TabState) -> [SessionCohortBinding] {
        let sims = tab.simPanes.compactMap { pane in
            pane.attachment.map {
                SessionCohortBinding(paneId: pane.paneId, expectedAttachment: $0)
            }
        }
        let devices = tab.devicePanes.compactMap { pane in
            pane.attachment.map {
                SessionCohortBinding(paneId: pane.paneId, expectedAttachment: $0)
            }
        }
        return sims + devices
    }

    /// Schedule (or restart) a tab's cohort reconcile after its membership
    /// changed. Cancel-and-replace: the superseded task's next send would
    /// carry stale membership, and the replacement re-derives everything.
    private func scheduleCohortReconcile(tab tabID: TabID) {
        guard !isShutdown, !closingTabs.contains(tabID) else { return }
        cohortReconcileTasks[tabID]?.cancel()
        cohortReconcileTasks[tabID] = Task { @MainActor [weak self] in
            await self?.runCohortReconcile(tab: tabID)
        }
    }

    /// Try one cohort reinstall per tab against the connection that just
    /// synced before pane recovery re-attaches. An applied attempt lets a
    /// recovered pane auto-bind at admission; a retryable failure hands off
    /// to the background loop rather than holding recovery up.
    func reconcileAllCohorts() async {
        for window in workspace.windows {
            for tab in window.tabs.tabs {
                cohortReconcileTasks[tab.id]?.cancel()
                cohortReconcileTasks[tab.id] = nil
                if await attemptCohortReconcile(tab: tab.id) == .retry {
                    scheduleCohortReconcile(tab: tab.id)
                }
            }
        }
    }

    /// Commit a close verdict for the leaving terminals ahead of their
    /// session closes, returning the daemon's authoritative outcome.
    ///
    /// Nil means the close proceeds on the binary tombstone fallback: the
    /// daemon answered `applied: false` (a reap already tore the named
    /// sessions down, so aborting would wedge the close against sessions
    /// that no longer exist), refused definitively, or never answered
    /// inside the deadline. The daemon converges its own side through the
    /// `session.close` seam either way; only the GUI tombstone degrades,
    /// bounded by the boot-claim lease.
    ///
    /// One `transitionId` per close gesture, held across retries, so a
    /// retry after a lost reply replays the journalled verdict instead of
    /// deciding (and promoting) again. Revisions stay fresh per send.
    private func cohortBeginClose(
        cohortId: UUID,
        leaving: [String],
        mode: PaneCloseMode
    ) async -> CohortCloseOutcome? {
        let transitionId = UUID().uuidString
        let deadline = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(cohortCloseDeadlineNanos)
        guard !deadline.overflow else { return nil }
        var backoffMs = 200
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.partialValue else { return nil }
            let revision = nextCohortRevision
            nextCohortRevision += 1
            let params = SessionSetCohortParams(
                operation: .beginClose,
                cohortId: cohortId.uuidString,
                revision: revision,
                transitionId: transitionId,
                leaving: leaving,
                mode: mode
            )
            do {
                // The deadline bounds the WAIT, not the request: a silent
                // helper would otherwise hold the serial route drain for the
                // client's own, longer request bound, once per tab on a
                // window close. The request is never cancelled, and a late
                // reply needs no reconciliation: the daemon journalled the
                // verdict under this transitionId, and the GUI has already
                // recorded the fallback tombstone by then.
                let result = try await Deadline.wait(
                    nanos: deadline.partialValue - now,
                    expired: DaemonClientError.timedOut(
                        method: RPCMethod.sessionSetCohort.rawValue
                    ),
                    late: { _ in },
                    work: { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.daemon.setCohort(params)
                    }
                )
                guard result.applied, let outcome = result.outcome else { return nil }
                return outcome
            } catch {
                // A definite pre-commit rejection is terminal for the
                // gesture; retrying replays the refusal. Anything else is
                // an indeterminate loss: the verdict may be journalled
                // daemon-side, so retry the same transitionId until the
                // deadline and let the journal answer.
                if case let DaemonClientError.daemon(code, _) = error,
                    Self.definiteProtectionRejectionCodes.contains(code) {
                    return nil
                }
                let afterFailure = DispatchTime.now().uptimeNanoseconds
                guard afterFailure < deadline.partialValue else { return nil }
                // The backoff respects the same budget as the waits: an
                // uncapped sleep after a near-deadline failure would overrun
                // the advertised bound by most of a backoff step.
                try? await Task.sleep(
                    nanoseconds: min(
                        UInt64(backoffMs) * 1_000_000,
                        deadline.partialValue - afterFailure
                    )
                )
                backoffMs = min(backoffMs * 2, 1_000)
            }
        }
    }

    private func simAttachSpec(
        tab tabID: TabID,
        udid: String,
        displayName: String?,
        family: String? = nil
    ) -> PendingAttachSpec {
        PendingAttachSpec(
            target: .sim(udid: udid),
            displayName: displayName,
            family: family,
            method: .deviceAttach,
            attach: { [weak self, daemon] primary in
                let answer = try await daemon.attachDeviceWithGeneration(
                    sessionId: primary.sessionId,
                    capability: primary.capability,
                    udid: udid
                )
                // `device.attach` records ownership daemon-side, so the mirror
                // is out of date the moment this returns.
                self?.noteSimOwned(
                    udid: udid,
                    sessionId: primary.sessionId,
                    generation: answer.generation
                )
                return answer.response
            },
            resolveName: { [weak self] _ in
                if let displayName { return displayName }
                if let looked = await self?.resolveDeviceName(udid: udid) { return looked }
                return "Sim \(udid.prefix(8))"
            },
            mount: { window, pendingId, response, resolvedName in
                // Mount the identity the daemon reports, not the one this
                // call asked with, so `pane info` and the `panes.list` the
                // daemon answers name the pane with one string. `createSim`
                // canonicalizes to lowercase; the attach paths reach here
                // with whatever case they were handed.
                //
                // A peer too old to send `target` canonicalized its own
                // record all the same, so the fallback applies that rule
                // locally rather than echoing the caller. Duplicating it is
                // safe in this direction: only a peer that predates `target`
                // reaches the fallback, and it can no longer change its rule.
                var canonicalUDID = udid
                if case let .sim(reported)? = response.target {
                    canonicalUDID = reported
                } else if let parsed = UUID(
                    uuidString: udid.trimmingCharacters(in: .whitespacesAndNewlines)
                ) {
                    canonicalUDID = parsed.uuidString.lowercased()
                }
                let pane = SimPaneState(
                    paneId: response.paneId,
                    udid: canonicalUDID,
                    displayName: resolvedName,
                    family: response.family ?? DeviceFamily.unknown.rawValue,
                    attachment: response.attachment,
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
    /// signature-validated GUI peer, no cap), and no ownership bookkeeping
    /// (`noteSimOwned` records a sim's boot claim for cold-start orphan
    /// recovery; device panes are never persisted).
    ///
    /// There is no name lookup on this path, and the response's `name` is a
    /// human-set pane name the daemon leaves nil at create, so a caller
    /// passing nil gets a deviceId stub. The caller's name is the only real
    /// source, which is why recovery hands the pane's own label back rather
    /// than resolving. Nothing composes a device type onto it either (a
    /// physical attach reports none), so that label round-trips unchanged.
    private func deviceAttachSpec(
        tab tabID: TabID,
        deviceId: String,
        displayName: String?
    ) -> PendingAttachSpec {
        PendingAttachSpec(
            target: .device(deviceId: deviceId),
            displayName: displayName,
            family: nil,
            method: .physicalDeviceAttach,
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
                    attachment: response.attachment,
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
    /// Discovery / menu / CLI claim / device picker funnel here.
    private func attachPaneOptimistically(tab tabID: TabID, spec: PendingAttachSpec) {
        guard let window = workspace.windowContaining(tab: tabID),
            let tab = window.tabs.tab(id: tabID) else { return }
        // Target-based dedup across mounted + pending panes so discovery
        // (every 2s), menu, CLI, and picker can't stack a second (or a
        // duplicate failed) placeholder for the same target.
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
                family: spec.family
            ),
            toTab: tabID,
            spawningTerminal: spawningTerminalID
        )
        spawnAttach(tab: tabID, pendingId: pendingId, spec: spec)
    }

    /// Run the attach RPC for a pending pane and reconcile the result: swap
    /// the placeholder for the real pane on success, flip it to `.failed` on
    /// error. Returns whether the pane mounted (the orphan-reattach loop
    /// reads this to decide cleanup). If the placeholder vanished during the
    /// await (Cancel / tab close), the pane that came back goes to the
    /// best-effort detach reconciliation, which skips it while another mounted
    /// or attaching pane claims its target and defers the decision to
    /// whichever attach stops waiting last.
    @discardableResult
    private func runAttach(
        tab tabID: TabID,
        pendingId: PendingPaneID,
        spec: PendingAttachSpec
    ) async -> Bool {
        // Wait out a detach already in flight for this target before sending.
        // See `detach`: the record it is closing is the one the daemon would
        // hand back to a re-attach.
        await awaitDetach(of: spec.target)
        guard let primary = workspace.windowContaining(tab: tabID)?
            .tabs.tab(id: tabID)?.primaryTerminal else { return false }
        let startedAt = rpcPerformance?.now()
        do {
            // The bound lives here, not in `DaemonClient`, because only this
            // layer can say whether a pane that arrives late is still wanted.
            // The call is never cancelled, so however long the daemon takes, a
            // returned pane is either mounted or sent through the best-effort
            // detach reconciliation.
            let response = try await Deadline.wait(
                nanos: attachDeadlineNanos,
                expired: DaemonClientError.timedOut(method: spec.method.rawValue),
                late: { [weak self] late in
                    await self?.detachUnclaimedPane(late, target: spec.target)
                },
                work: { try await spec.attach(primary) }
            )
            if let startedAt {
                rpcPerformance?.record(
                    method: spec.method,
                    lane: .control,
                    startedAtNanoseconds: startedAt,
                    error: nil,
                    severeDelayNanoseconds: 10_000_000_000
                )
            }
            // If the tab is being torn down, or quit cancelled us, do NOT
            // mount. Mid-teardown the pending record is still in nav state
            // and the tab is still in the workspace (it's removed only after
            // the close RPCs await), so the pending-still-present guard below
            // isn't enough on its own: mounting here would hand the pane to a
            // tab whose `closeTabRecords` already snapshotted its panes, and
            // nothing would ever close it. `closingTabs` covers exactly that
            // window and `Task.isCancelled` covers quit, which is the one
            // path that cancels attaches. Detached through the same claim
            // check as any other unclaimed pane, discounting this tab's own
            // placeholder: closing the tab kills its session, which is exactly
            // what lets ANOTHER tab's in-flight attach adopt this record (the
            // daemon transfers a pane whose owner is dead), so an
            // unconditional close here would take a pane away from the tab
            // that just adopted it.
            if Task.isCancelled || closingTabs.contains(tabID) {
                await detachUnclaimedPane(
                    response,
                    target: spec.target,
                    ignoring: pendingId
                )
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
            // attach await + the optional name-lookup await): mount iff the
            // placeholder is still present. Otherwise the attach outlived a
            // Cancel or a tab close, and the pane it made is detached unless
            // something else now claims its target.
            guard let window = workspace.windowContaining(tab: tabID),
                window.tabs.tab(id: tabID)?.pendingPanes
                    .contains(where: { $0.id == pendingId }) == true else {
                await detachUnclaimedPane(response, target: spec.target)
                return false
            }
            spec.mount(window, pendingId, response, resolvedName)
            // A pane can mount into the window where the cohort install
            // raced it: the reconcile snapshotted no panes, and auto-bind at
            // admission saw no cohort yet. Re-kick the tab's reconcile so
            // the mounted pane's binding rides the next send; on the common
            // path (cohort already installed, pane auto-bound) the send is a
            // cheap confirmation.
            scheduleCohortReconcile(tab: tabID)
            await reconcileDeferredDetaches(for: spec.target)
            return true
        } catch {
            if let startedAt {
                rpcPerformance?.record(
                    method: spec.method,
                    lane: .control,
                    startedAtNanoseconds: startedAt,
                    error: error,
                    severeDelayNanoseconds: 10_000_000_000
                )
            }
            logError("\(spec.failureLog): \(error)")
            workspace.windowContaining(tab: tabID)?.tabs.failPendingPane(
                id: pendingId,
                message: ErrorText.describing(error),
                inTab: tabID
            )
            // This attempt has stopped waiting, so a detach deferred behind
            // it (including one deferred behind THIS placeholder while it was
            // attaching) has to be retaken now: a placeholder that isn't
            // attaching claims nothing.
            await reconcileDeferredDetaches(for: spec.target)
            return false
        }
    }

    /// Detach a pane whose placeholder is gone, unless something else now
    /// claims its target, in which case hold the pane until that claim
    /// resolves.
    ///
    /// Losing the placeholder frees the target, and an attach for it can start
    /// again straight away (discovery re-offers a booted sim every couple of
    /// seconds) while this one is still running. The daemon hands the owning
    /// session back its existing pane rather than minting a second, so the
    /// newer attach lands on the SAME paneId, and detaching it here would
    /// leave the workspace showing a pane whose daemon side is closed. Testing
    /// the target rather than the paneId catches that newer attach while it is
    /// still in flight, when its placeholder is all it has.
    ///
    /// A claim isn't proof, though: the replacement may fail (its session may
    /// be refused ownership of a target another tab holds), and then nobody
    /// would be left to close this pane. So the claim only *defers* the
    /// decision, and `reconcileDeferredDetaches` retakes it once every attach
    /// for the target has settled.
    private func detachUnclaimedPane(
        _ response: PaneCreateResponse,
        target: PaneTarget,
        ignoring pendingId: PendingPaneID? = nil
    ) async {
        let paneId = response.paneId
        // Already on screen: the daemon handed this record to a later caller
        // (a re-attach for the same target, or an adoption once this pane's
        // owning session died), and that caller mounted it. Detaching now
        // would take a live pane away from whoever is showing it.
        if isPaneMounted(paneId) { return }
        guard !isTargetClaimed(target, ignoring: pendingId) else {
            deferredDetaches[detachKey(target), default: []].insert(
                DeferredDetach(paneId: paneId, attachment: response.attachment)
            )
            return
        }
        await detach(paneId, target: target, expecting: response.attachment)
    }

    /// Close a pane, holding the target's detach slot until the RPC returns.
    ///
    /// The claim check that authorized this close runs synchronously, but the
    /// close itself suspends, and an attach starting in that gap would find
    /// the target free and race the daemon into handing it this very record.
    /// Publishing the in-flight close is what lets `runAttach` wait it out
    /// instead. Everything that closes an unclaimed pane goes through here.
    ///
    /// The fence only covers the GUI's wait, and a close that times out leaves
    /// the outcome unknown, so it is not the only protection: the close also
    /// carries the admission it was issued against (`expecting`), and the
    /// daemon refuses one whose admission has been superseded. A late close
    /// therefore can't retire a record a re-attach has since handed to someone
    /// else, which is the failure this fence alone could not prevent.
    private func detach(
        _ paneId: String,
        target: PaneTarget,
        expecting attachment: UInt64?
    ) async {
        let key = detachKey(target)
        let close = Task { @MainActor [daemon] in
            _ = try? await daemon.closePane(
                paneId: paneId,
                mode: .detach,
                expecting: attachment
            )
        }
        detachTasks[key] = close
        await close.value
        // Only the installer clears it; an overlapping detach for the same
        // target has already taken the slot and owns its own release.
        if detachTasks[key] == close { detachTasks[key] = nil }
    }

    /// Wait out a detach in flight for `target`.
    ///
    /// One await is enough. A detach only starts when nothing claims the
    /// target, and every attach path inserts (or re-arms) its `.attaching`
    /// placeholder synchronously before `runAttach` runs, so from here on the
    /// target reads as claimed and no further detach can decide to close it.
    private func awaitDetach(of target: PaneTarget) async {
        guard let inFlight = detachTasks[detachKey(target)] else { return }
        await inFlight.value
    }

    /// Settle any detach deferred while `target` looked claimed.
    ///
    /// Called whenever an attach for the target stops waiting, however it
    /// stopped. A pane that ended up mounted is kept (the re-attach handed the
    /// newer caller the same record); one that nothing is showing is detached;
    /// and if another placeholder is still attaching the decision defers
    /// again, to whichever of them stops waiting last. A call still running
    /// past its own deadline isn't waited for here: whatever it returns
    /// arrives at `detachUnclaimedPane` on its own.
    private func reconcileDeferredDetaches(for target: PaneTarget) async {
        let key = detachKey(target)
        guard let deferred = deferredDetaches.removeValue(forKey: key) else { return }
        guard !isTargetAttaching(target) else {
            deferredDetaches[key] = deferred
            return
        }
        for entry in deferred where !isPaneMounted(entry.paneId) {
            await detach(entry.paneId, target: target, expecting: entry.attachment)
        }
    }

    /// Whether any window shows this target, or is still attaching it,
    /// discounting the placeholder named by `ignoring` (the caller's own).
    private func isTargetClaimed(
        _ target: PaneTarget,
        ignoring pendingId: PendingPaneID? = nil
    ) -> Bool {
        liveTabs().contains {
            TabListViewModel.isTargetShown(target, in: $0, ignoring: pendingId)
        }
    }

    private func isTargetAttaching(_ target: PaneTarget) -> Bool {
        liveTabs().contains { tab in
            tab.pendingPanes.contains {
                $0.phase == .attaching && TabListViewModel.targetsMatch($0.target, target)
            }
        }
    }

    /// Tabs whose claims still mean something, which is every tab not being
    /// torn down. A closing tab keeps its placeholders in nav state until its
    /// teardown RPCs finish, and those placeholders will never mount anything:
    /// counting one as a claim would park a detach behind an attach that has
    /// already given up, with no later event to retake the decision.
    private func liveTabs() -> [TabState] {
        workspace.windows
            .flatMap(\.tabs.tabs)
            .filter { !closingTabs.contains($0.id) }
    }

    private func isPaneMounted(_ paneId: String) -> Bool {
        workspace.windows.contains { window in
            window.tabs.tabs.contains { tab in
                tab.simPanes.contains { $0.paneId == paneId }
                    || tab.devicePanes.contains { $0.paneId == paneId }
            }
        }
    }

    /// Registry key for a target. Sim UDID casing varies across the attach
    /// paths, so it is normalized here the way the presence checks compare it;
    /// two spellings of one sim must not key two entries.
    private func detachKey(_ target: PaneTarget) -> PaneTarget {
        switch target {
        case let .sim(udid):
            return .sim(udid: udid.lowercased())

        case .device:
            return target
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

    private func detachPane(
        tab tabID: TabID,
        udid: String,
        mode: PaneCloseMode,
        expecting: PaneAdmission? = nil
    ) async {
        guard let window = workspace.windowContaining(tab: tabID),
            let pane = window.tabs.tab(id: tabID)?.simPanes
                .first(where: { $0.udid == udid }) else { return }
        // The pane moved between accepting this route and draining it: it
        // was replaced, or the same record was re-admitted under a new
        // attachment. Either way this close names something that is no
        // longer here, and applying it would carry an answer the user gave
        // about a different admission.
        if let expecting, pane.admission != expecting { return }
        do {
            try await daemon.closePane(
                paneId: pane.paneId,
                mode: mode,
                expecting: pane.attachment
            )
            // Same reason as the tab-close fan-out: a `.shutdown` close stops
            // the sim and disowns it daemon-side, so the claim has to go with
            // it. This is the path `deviceterm pane close --mode shutdown` and
            // the in-pane action take.
            if mode == .shutdown { noteSimShutdown(udid: udid) }
        } catch {
            logError("pane.closeById failed for \(udid): \(error)")
        }
        window.tabs.removeSimPane(udid: udid, fromTab: tabID)
    }

    /// Re-attach a sim that shut down out from under its pane, into the leaf
    /// that pane already holds. Dispatched by the `PaneResurrect` watch.
    ///
    /// The daemon keeps the shutdown pane record for the overlay. Close that
    /// terminal record with `.detach` before attaching its replacement; the
    /// watched simulator is already Booted, and `.shutdown` would stop it
    /// again.
    ///
    /// The window is re-resolved after the close, not just the pane: a tab
    /// drag or tear-off moves it between windows by mutating the workspace
    /// directly (`AppDelegate.moveTab`), outside the route drain, so the
    /// window this started in can no longer hold the tab by the time the
    /// close returns. Re-reading finds the tab where it is now; keeping the
    /// captured one would return here having closed the record, stranding a
    /// pane on a dead pane id with its resurrect watch already spent.
    private func resurrectSimPane(tab tabID: TabID, udid: String) async {
        guard let pane = workspace.windowContaining(tab: tabID)?
            .tabs.tab(id: tabID)?.simPanes
            .first(where: { $0.udid == udid }) else { return }
        do {
            try await daemon.closePane(
                paneId: pane.paneId,
                mode: .detach,
                expecting: pane.attachment
            )
        } catch {
            logError("pane.closeById failed for \(udid): \(error)")
        }
        guard let window = workspace.windowContaining(tab: tabID),
            let tab = window.tabs.tab(id: tabID),
            let mounted = tab.simPanes.first(where: { $0.udid == udid }) else { return }
        // The position comes from the tab-wide numbering, not from the array,
        // because the array excludes placeholders an earlier recovery left
        // behind and those still hold their positions. Indexing the array
        // would hand this pane a position one of them has already claimed,
        // and `restoredIndex` resolves a tie by arrival order.
        reattachSimPaneInPlace(
            mounted,
            atIndex: simRecoveryOrder(in: tab)[udid.lowercased()],
            tab: tabID,
            window: window
        )
    }

    /// Re-mirror a device whose mirror stopped out from under its pane, into the
    /// leaf that pane already holds. Dispatched by the `PaneResurrect` watch.
    ///
    /// The device counterpart of `resurrectSimPane`, and it re-resolves the
    /// window after the close for the same reason: a tab drag can move the
    /// tab between windows outside the route drain.
    ///
    /// The daemon keeps the shutdown pane record for the overlay, so close it
    /// before attaching its replacement. `.detach` because the mirror is what
    /// ends here; the device itself is not the daemon's to stop.
    private func resurrectDevicePane(tab tabID: TabID, deviceId: String) async {
        guard let pane = workspace.windowContaining(tab: tabID)?
            .tabs.tab(id: tabID)?.devicePanes
            .first(where: { $0.deviceId == deviceId }) else { return }
        do {
            try await daemon.closePane(
                paneId: pane.paneId,
                mode: .detach,
                expecting: pane.attachment
            )
        } catch {
            logError("pane.closeById failed for \(deviceId): \(error)")
        }
        guard let window = workspace.windowContaining(tab: tabID),
            let mounted = window.tabs.tab(id: tabID)?.devicePanes
                .first(where: { $0.deviceId == deviceId }) else { return }
        recoverDevicePane(mounted, tab: tabID, window: window)
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
        // No cancel of the previous attempt: reaching `.failed` is what proves
        // it already finished, and cancelling an attach anywhere but quit
        // throws away the paneId its cleanup needs.
        //
        // Rebuild the attach spec from the placeholder's target. Retry only
        // re-runs the attach, and the spec carries no placement: the
        // placeholder is already in the tree, and the position it claimed
        // rides on `PendingPaneState.atIndex` until the pane mounts, so a
        // pane re-attached after a failed recovery still lands in its own
        // slot rather than appending.
        let spec: PendingAttachSpec
        switch pending.target {
        case let .sim(udid):
            spec = simAttachSpec(tab: tabID, udid: udid, displayName: pending.attachName)

        case let .device(deviceId):
            spec = deviceAttachSpec(tab: tabID, deviceId: deviceId, displayName: pending.attachName)
        }
        // A retry can overlap the attempt that failed: the first one abandoned
        // its *wait*, not its work, so the daemon may still be finishing it.
        // Both converge on one pane, because the daemon hands the owning
        // session back its existing pane for the same target rather than
        // minting a second, and whichever attach ends up unclaimed detaches
        // only if nothing is showing that target (`detachUnclaimedPane`).
        spawnAttach(tab: tabID, pendingId: pendingId, spec: spec)
    }

    /// Close a pending pane: drop the placeholder leaf and leave the in-flight
    /// attach running until it replies or reaches its deadline. If it returns
    /// a paneId with the placeholder gone, `runAttach` detaches that pane.
    ///
    /// Deliberately does NOT cancel the attach. Cancelling ends this waiter
    /// but not the daemon's work, so it buys nothing: the reply still arrives,
    /// and would be reconciled by `Deadline.wait`'s late cleanup instead of by
    /// the post-await guard below. Leaving the call alone keeps every reply on
    /// one path, and the escape is immediate either way because the leaf goes
    /// now.
    ///
    /// The cleanup always detaches (we never power off a device whose attach
    /// we didn't finish), so `mode` is advisory: the leaf removal ignores it.
    private func cancelPendingPane(
        tab tabID: TabID,
        pendingId: PendingPaneID,
        mode: PaneCloseMode
    ) {
        _ = mode
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
        try? await daemon.closePane(
            paneId: pane.paneId,
            mode: mode,
            expecting: pane.attachment
        )
        window.tabs.removeDevicePane(deviceId: deviceId, fromTab: tabID)
    }

    /// Daemon-side teardown for a tab being closed: close each sim pane,
    /// fan out device.shutdown across owned booted sims on `.shutdown`, then
    /// close every terminal pane's session. `session.close` also preserves the
    /// mode for a boot claim still converging, but existing panes remain this
    /// GUI fan-out's responsibility. The owned-booted fan-out checks each
    /// terminal session for ownership because sims may be linked to
    /// non-primary terminals.
    private func closeTabRecords(_ tab: TabState, mode: PaneCloseMode) async {
        // Closing tombstone: this method cancels protection and cohort work
        // but then `await`s several daemon RPCs while the tab is STILL in the
        // workspace (removal happens synchronously at the call site after we
        // return). A cancelled transition's late reply arriving during those
        // awaits would otherwise pass `scheduleReconcile`'s guards (not
        // shut down, tab still present) and resurrect a reconcile. The
        // tombstone blocks that; the `defer` drops it just before the
        // synchronous `removeTab` (no `await` between, so no reply can slip
        // into the gap, and after removal the workspace check takes over).
        // Inserted before the `beginClose` await below, which is the first
        // suspension the tombstone must already cover.
        closingTabs.insert(tab.id)
        defer { closingTabs.remove(tab.id) }
        // Cancel the tab's cohort reconcile before deciding the close: a
        // send computed from pre-close membership would only be refused by
        // the daemon's closed-member interlock, so stop issuing them.
        cohortReconcileTasks[tab.id]?.cancel()
        cohortReconcileTasks[tab.id] = nil
        // One verdict for the whole membership. Every terminal is leaving,
        // so an applied verdict is terminal (never a promotion) and each
        // session records the same answer. If `beginClose` is refused (the
        // reap race: the daemon already tore the sessions down) or unanswered,
        // the fallback records each disposition directly from `mode`.
        let verdict = await cohortBeginClose(
            cohortId: tab.cohortId,
            leaving: tab.terminals.map(\.sessionId),
            mode: mode
        )
        for terminal in tab.terminals {
            if let verdict {
                bootClaims.sessionClosed(terminal.sessionId, outcome: verdict)
            } else {
                bootClaims.sessionClosed(terminal.sessionId, mode: mode)
            }
        }
        // In-flight attaches for this tab are left to finish, for the reason
        // `cancelPendingPane` spells out: cancelling throws away the paneId
        // the cleanup needs. A reply that beats the attach deadline is
        // detached, whether it arrives while `closingTabs` still marks this
        // tab or after the tab is gone; a reply past that deadline is detached
        // too, by the late-arrival cleanup. Session close covers none of it:
        // that revokes a pane's subscriptions and leaves the record orphaned
        // rather than retiring it.
        //
        // The batch owner IS cancelled: it holds no daemon state, and its
        // cancellation is what stops a batch still settling from deleting an
        // orphan record's session dir after the tab it was adopted into is
        // gone.
        if let batch = orphanBatchTasks.removeValue(forKey: tab.id) {
            for task in batch.values { task.cancel() }
        }
        // Cancel any in-flight protection transition or snapshot reconcile for
        // the closing tab so neither outlives it.
        protectionTransitions[tab.id]?.task.cancel()
        protectionTransitions[tab.id] = nil
        protectionReconcileTasks[tab.id]?.cancel()
        protectionReconcileTasks[tab.id] = nil
        for pane in tab.simPanes {
            do {
                try await daemon.closePane(
                    paneId: pane.paneId,
                    mode: mode,
                    expecting: pane.attachment
                )
                // A `.shutdown` close stops the sim daemon-side and disowns it,
                // so the mirror is wrong from here. This is where production
                // retires a pane-backed sim; the `device.shutdown` sweep below
                // only ever sees ones no pane was carrying, because this close
                // has already taken the rest out of the owned roster.
                if mode == .shutdown { noteSimShutdown(udid: pane.udid) }
            } catch {
                logError("pane.closeById failed for \(pane.udid): \(error)")
            }
        }
        // Device panes tear down the daemon pane + IOSurface stream the
        // same way; `mode` is moot for the physical device itself (we
        // never power it off, closing the pane just drops the mirror).
        for pane in tab.devicePanes {
            try? await daemon.closePane(
                paneId: pane.paneId,
                mode: mode,
                expecting: pane.attachment
            )
        }
        if mode == .shutdown {
            let owned = (try? await daemon.deviceList(scope: .owned)) ?? []
            let tabSessionIds = Set(tab.terminals.map(\.sessionId))
            for device in owned
            where tabSessionIds.contains(device.ownedBySession ?? "")
                && device.state == "Booted" {
                do {
                    try await daemon.shutdownDevice(udid: device.udid)
                    noteSimShutdown(udid: device.udid)
                } catch {
                    logError("device.shutdown failed for \(device.udid): \(error)")
                }
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

private extension Router {
    /// The per-backend slice of an optimistic pane attach. The scaffolding
    /// around it is identical for sims and physical devices: insert a
    /// placeholder leaf the instant the user acts, run the (slow) attach RPC
    /// off the serial drain so navigation never freezes, then reconcile with
    /// the same cancel / leak-cleanup guards, the same "Name · Type"
    /// composition, and the same failure rendering. This carries only what
    /// diverges: the placeholder's sizing hint, the RPC + its auth model, the
    /// name resolution, and the concrete pane build + mount.
    struct PendingAttachSpec {
        let target: PaneTarget
        let displayName: String?
        /// Coarse device family, read only at placeholder-insert time, so the
        /// placeholder takes the metrics the real pane will and the success
        /// swap doesn't resize. Nil → phone-default, corrected on swap.
        let family: String?
        /// The wire method `attach` sends, for the deadline error's text.
        let method: RPCMethod
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

    /// A pane whose detach is waiting for another attach on the same target to
    /// stop waiting. The admission id travels with it so the eventual close is
    /// still fenced to the admission that produced this pane.
    struct DeferredDetach: Hashable {
        let paneId: String
        let attachment: UInt64?
    }

    /// One in-flight tab-protection transition. `generation` is monotonic per
    /// Router so a superseded transition's late resolution can't overwrite a
    /// newer one (a rapid protected→unprotected→protected converges on the last
    /// requested state). `task` is held so a supersede / tab-close / quit can
    /// cancel it.
    struct ProtectionTransition {
        let generation: Int
        /// The state being converged toward. A membership re-kick reconverges
        /// toward this same target.
        let target: Bool
        let task: Task<Void, Never>
    }

    /// What one cohort reconcile send concluded.
    enum CohortReconcileAttempt {
        case applied
        /// Rejected, or the reply was lost. Either way the next send is
        /// computed from the tab's live state, which is the whole recovery:
        /// it absorbs a member that closed mid-flight, a stale key, and a
        /// refused binding alike.
        case retry
        /// The tab is gone, closing, or the daemon refused the method
        /// structurally; nothing left to converge.
        case abandoned
    }

    /// One-shot resolver for an awaited protection outcome: whichever fires
    /// first (the transition's `onFirstOutcome` callback or the deadline)
    /// wins; later calls are ignored.
    @MainActor
    final class ProtectionOutcomeGate {
        private var resumed = false
        private let continuation: CheckedContinuation<TabProtectionOutcome, Never>

        init(_ continuation: CheckedContinuation<TabProtectionOutcome, Never>) {
            self.continuation = continuation
        }

        func resolve(_ outcome: TabProtectionOutcome) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: outcome)
        }
    }
}
