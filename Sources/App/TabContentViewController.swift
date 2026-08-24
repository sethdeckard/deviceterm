// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabContentViewController: one tab's session-bound view. The Router
// creates the daemon session (session.create) and records the TabState;
// the glue builds this VC for that state. The VC reconciles its
// per-terminal-pane and per-sim-pane controllers to TabState.terminals
// and TabState.simPanes (the Router does session.create / device.attach
// / pane.close; reconcile creates / drops VCs to match).
//
// Each terminal pane carries its own daemon session: `sessionEnvsByID`
// holds a `SessionEnvironment` per `TerminalPaneID` (provisioned the
// first time the reconcile sees that terminal). GUI-created sim panes
// attribute to the primary terminal's session env; shim boot claims arrive
// through the relay owned by the exact terminal that initiated the boot.
//
// App-wide discovery snapshots + resurrect dispatch attachSimPane /
// detachSimPane routes through the Router: one path for all pane mounting.

import AppKit
import DaemonProtocol
import TerminalSurface

@MainActor
final class TabContentViewController: NSViewController {
    let tabID: TabID
    /// The parent window's identifier. Used to scope Route intents
    /// minted from per-tab surfaces (e.g. the terminal pane right-
    /// click "Open in New Tab", which dispatches `Route.newTab`
    /// against this window). A `var` because a cross-window tab move
    /// re-parents this VC into another window and calls `rebind`, so the
    /// "new tab / new window here" intents target the tab's new home.
    private(set) var windowID: WindowID
    /// Per-tab @Observable title state; TabStripViewController observes it.
    let titleModel = TabTitleViewModel()
    let splitVC: PaneLayoutViewController
    /// Forwarder for per-terminal shell-exit handling, the strip
    /// installs this so a terminal-pane exit can dispatch
    /// `closeTerminalPane` for non-primary panes and `closeTab` for
    /// the last surviving terminal. Set by the strip after init.
    var onTerminalExit: ((TerminalPaneID) -> Void)?
    /// Forwarder for the user's explicit Close Pane on a terminal.
    /// Separate from `onTerminalExit` so the last-terminal case can
    /// apply the tab-close prompt policy; a shell exit closes
    /// silently, an explicit close of the last terminal is a tab
    /// close. Set by the strip after init.
    var onTerminalCloseRequested: ((TerminalPaneID) -> Void)?

    private let role: SessionRole
    private let daemonClient:
        any DeviceControlling & PaneControlling & PaneSubscribing & TerminalBinding & ReconnectObserving
            & PaneAccessibilityControlling & PaneLocationControlling
            & AutomationGranting & DisplayTitlePublishing
    private let simResurrect: SimResurrect
    private let router: Router
    /// The window's tab-list nav state this VC reconciles against. A
    /// `var` because a cross-window move relocates the tab's `TabState`
    /// into another window's `TabListViewModel`; `rebind` repoints this
    /// (and the action coordinator) and re-arms observation so reconcile
    /// tracks the tab's new home.
    private var tabListVM: TabListViewModel
    /// The sim pane's menu/chrome action wiring + recording-map ownership,
    /// one per tab. Device / pending panes wire far less, so their wiring
    /// stays inline below.
    private let simPaneActions: SimPaneActionCoordinator
    /// Issues + retries this tab's automation grant once a terminal binds
    /// (automation tabs only; a no-op otherwise). Per-tab: its retry loops are
    /// cancelled when the tab (and this VC) tears down.
    private let grantCoordinator: AutomationGrantCoordinator
    /// Keeps the daemon's copy of this tab's live label current, so
    /// `tabs.list` can serve it in place of the static name from
    /// `session.create`. Per-tab: its pending push is dropped when the tab
    /// (and this VC) tears down.
    private let titlePublisher: DisplayTitlePublisher
    private let daemonSocketPath: String
    /// Handle for this tab's reconnect observer, removed on teardown.
    private var reconnectObserverToken: ReconnectObserverToken?
    /// Session env per terminal pane (provisioned lazily on first
    /// reconcile of that terminal). Held strongly so the env outlives
    /// the surface attach, required for the on-disk scratch dir
    /// (manifest, ZDOTDIR, bin/ symlinks) to stay valid for the life
    /// of the shell.
    private var sessionEnvsByID: [TerminalPaneID: SessionEnvironment] = [:]
    private var terminalVCByID: [TerminalPaneID: TerminalPaneViewController] = [:]
    /// Discovery-snapshot dedup: udids the tab has already dispatched an
    /// attach for during this boot. A later detach (sim still booted)
    /// must not re-attach on the next snapshot.
    private var handledUDIDs: Set<String> = []
    private var isTornDown = false
    private var discoveryObserverToken: OwnedSimDiscoveryObserverToken?
    private var observation: ObservationToken?
    /// Separate from `observation` on purpose: the reconcile closure never
    /// reads the title, and Observation tracks only what a pass actually
    /// accesses, so a title change would not re-fire it.
    private var titleObservation: ObservationToken?
    private var simPaneVCByUDID: [String: SimulatorPaneViewController] = [:]
    /// Physically-connected device panes, keyed by `deviceId`. Parallel
    /// to `simPaneVCByUDID`; both hold `SimulatorPaneViewController`s
    /// (the renderer is shared), but device panes carry no recording /
    /// resurrect state so the cleanup paths skip them.
    private var devicePaneVCByID: [String: SimulatorPaneViewController] = [:]
    /// Placeholder panes for in-flight / failed attaches, keyed by
    /// `PendingPaneID`. Reconciled before the layout tree so the real
    /// VC is ready when a pending leaf swaps to `.sim`/`.device`. Unlike
    /// the sim/device dicts, this reconcile also *updates* a live VC when
    /// its phase flips (attaching ↔ failed).
    private var pendingPaneVCByID: [PendingPaneID: PendingPaneViewController] = [:]
    /// Most recent full working-directory path. Seeded at init from
    /// the primary terminal's startup `cwd` (the explicit `deviceterm tab
    /// open --cwd <path>` value) so Duplicate Tab honors that even
    /// before any OSC 7 lands; updated thereafter by each OSC 7 hop.
    /// `TabTitleViewModel` retains the OSC-7 basename for labelling and the
    /// full path for the proxy icon; only this property carries the startup
    /// seed.
    /// Duplicate Tab needs the absolute path to thread through
    /// `Route.newTab(cwd:)`. nil only when both the startup cwd was
    /// nil and no OSC 7 has fired (falls back to libghostty's GUI-cwd
    /// default).
    private(set) var latestWorkingDirectory: String?

    /// Sessions exposed for legacy tab-scoped consumers (status item
    /// grouping, the discovery snapshot's ownership filter, the
    /// automation-only `sendInput` / `captureScreen` default-target
    /// path). All resolve to the **primary** terminal's session, the
    /// authoritative "which session represents this tab" answer for
    /// surfaces that don't yet model per-terminal sessions.
    var sessionId: String { primaryTerminalSessionId }
    var capability: String { primaryTerminalCapability }
    var displayTitle: String { titleModel.displayTitle }
    var manualTitle: String? { titleModel.manualTitle }
    /// Directory backing the titlebar proxy icon: the primary terminal's OSC-7
    /// path, and nothing else.
    ///
    /// Deliberately without a startup-cwd fallback. OSC 7 is the only source
    /// that tracks `cd`, so a startup path would give a tab with no shell
    /// integration a folder button that silently goes stale. Such a button
    /// drags and opens at a directory the shell has left, which is worse than
    /// showing no button at all. An empty OSC 7 is a shell reporting that it
    /// does not know where it is, and clears this for the same reason.
    var proxyIconPath: String? { titleModel.lastCWDPath }
    private var primaryTerminalSessionId: String {
        tabListVM.tab(id: tabID)?.primaryTerminal.sessionId ?? ""
    }
    private var primaryTerminalCapability: String {
        tabListVM.tab(id: tabID)?.primaryTerminal.capability ?? ""
    }

    /// Build a tab VC for an already-created daemon session.
    /// Provisions the primary terminal pane's scratch dir + libghostty
    /// surface at init so the surface attach lands during a normal
    /// split-view layout (this is the OLD-code timing that lets
    /// `ghostty_surface_new` succeed). The reconcile pass picks up
    /// any *additional* terminals minted later via
    /// `Route.openTerminalPane`.
    init(
        tabID: TabID,
        windowID: WindowID,
        primary: TerminalPaneState,
        sessionName: String?,
        role: SessionRole,
        tabListVM: TabListViewModel,
        daemonClient: any DeviceControlling & PaneControlling & PaneSubscribing & TerminalBinding & ReconnectObserving
            & PaneAccessibilityControlling & PaneLocationControlling
            & AutomationGranting & DisplayTitlePublishing,
        simResurrect: SimResurrect,
        router: Router,
        daemonSocketPath: String = DaemonClient.socketPath()
    ) throws {
        self.tabID = tabID
        self.windowID = windowID
        self.role = role
        self.daemonClient = daemonClient
        self.grantCoordinator = AutomationGrantCoordinator(client: daemonClient)
        self.titlePublisher = DisplayTitlePublisher(
            .init(send: { [weak daemonClient] sessionId, title in
                try await daemonClient?.setDisplayTitle(sessionId: sessionId, title: title)
            })
        )
        self.simResurrect = simResurrect
        self.router = router
        self.tabListVM = tabListVM
        self.simPaneActions = SimPaneActionCoordinator(
            tabID: tabID,
            router: router,
            daemonClient: daemonClient,
            simResurrect: simResurrect,
            tabListVM: tabListVM,
            windowID: windowID
        )
        self.daemonSocketPath = daemonSocketPath
        let primaryEnv = SessionEnvironment(
            sessionId: primary.sessionId,
            capability: primary.capability,
            daemonSocketPath: daemonSocketPath,
            role: role,
            onBootClaim: { [weak router] sessionId, claim, deadline in
                router?.acceptBootClaim(
                    sessionId: sessionId,
                    claim: claim,
                    deadlineNanoseconds: deadline
                )
            }
        )
        try primaryEnv.provision()
        let primaryVC = TerminalPaneViewController(
            terminalID: primary.id,
            environment: primaryEnv.shellEnvironment(),
            cwd: primary.cwd,
            command: primary.command
        )
        primaryVC.tabID = tabID
        // The tab strip owns the title; name and shortId feed
        // `TabTitleViewModel` through the upstream wiring.
        let primarySlot = PaneSlot.terminal(primary.id)
        self.splitVC = PaneLayoutViewController(
            tabID: tabID,
            router: router,
            initialTree: .leaf(primarySlot),
            initialPaneVCs: [primarySlot: primaryVC]
        )
        super.init(nibName: nil, bundle: nil)
        // Pre-populate the per-terminal dicts so the first reconcile
        // pass treats the primary as "already mounted" and only
        // handles additional terminals.
        self.sessionEnvsByID[primary.id] = primaryEnv
        self.terminalVCByID[primary.id] = primaryVC
        // Seed cwd from the primary's startup value so a tab opened
        // with an explicit `--cwd <path>` (or with shell integration
        // disabled / OSC 7 not yet emitted) duplicates into the same
        // directory rather than the GUI's CWD.
        self.latestWorkingDirectory = primary.cwd
        // Split Right / Split Down with a device pane focused reaches the
        // layout controller instead of a terminal VC. The new terminal
        // still inherits the tab's working directory, which only this
        // controller holds, so the layout controller reports the anchor
        // and the placement decision stays here.
        self.splitVC.onSplitRequested = { [weak self] anchor, axis in
            self?.requestSplit(anchor: anchor, axis: axis)
        }
        wire(terminalVC: primaryVC, id: primary.id)
        // Re-bind every live terminal after a reconnect / daemon restart: the
        // daemon's anchor store is in-memory, so a restart (or the prior XPC
        // connection's teardown) loses the bindings and in-tab CLI calls would
        // otherwise never recover. The token is removed on teardown so the
        // client's observer registry doesn't grow across tab open/close cycles.
        reconnectObserverToken = daemonClient.addReconnectObserver { [weak self] in
            self?.rebindAllTerminals()
            // The daemon's title cache is memory-only, so a reconnect leaves it
            // empty and an unchanged title would never be pushed again. These
            // observers fire only after the session inventory has been
            // re-supplied, which is what makes the republish land on a session
            // the daemon holds.
            self?.titlePublisher.republish()
        }
        // Bind the automatic label sources to the primary terminal, seeding
        // the session-bound field so the worktree branch (from
        // session.create's `name` field) labels the tab immediately. OSC
        // titles from the shell still win when they arrive; CWD basename
        // loses to the worktree name. Binding here rather than letting the
        // first reconcile do it keeps that seed from being overwritten by
        // the terminal's own (still empty) values.
        titleModel.adoptPrimaryTerminal(
            id: primary.id,
            oscTitle: nil,
            workingDirectory: nil,
            sessionName: sessionName
        )
        discoveryObserverToken = router.addOwnedSimDiscoveryObserver { [weak self] owned in
            self?.discoverBootedSims(in: owned)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    // Isolated so the main-actor `daemonClient` is reachable during teardown.
    isolated deinit {
        // Fallback cancellation for any grant-retry loop still in flight if the
        // VC is released without an explicit `teardown()` (the retain the loop
        // holds normally keeps that from happening, but never rely on it).
        grantCoordinator.cancelAll()
        titlePublisher.cancel()
        // Remove this tab's reconnect observer so the client's registry doesn't
        // retain a dead closure across tab open/close cycles.
        if let reconnectObserverToken {
            daemonClient.removeReconnectObserver(reconnectObserverToken)
        }
        if let discoveryObserverToken {
            router.removeOwnedSimDiscoveryObserver(discoveryObserverToken)
        }
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The coordinator reads `hostView?.window` when it prompts, so
        // it needs the view rather than the window: this runs before the
        // view is in one.
        simPaneActions.hostView = view
        addChild(splitVC)
        splitVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitVC.view)
        NSLayoutConstraint.activate(
            [
            splitVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            splitVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ]
            )
        observation = App.observe { [weak self] in self?.reconcileAll() }
        titleObservation = App.observe { [weak self] in self?.reportDisplayTitle() }
    }

    /// Hand the publisher the tab's current label and current representative
    /// session. Both are read on every pass, since Observation tracks only
    /// what a pass accesses. This re-fires both when the title changes and when
    /// closing the primary terminal of a split tab re-seats `primaryTerminal`
    /// onto a different session. It reports the *publishable* label, not the
    /// rendered one: a label that merely restates the session name (or the
    /// generic fallback) publishes as a clear, since `tabs.list` already
    /// carries the name.
    private func reportDisplayTitle() {
        let title = titleModel.publishableTitle
        let sessionId = primaryTerminalSessionId
        titlePublisher.update(sessionId: sessionId, title: title)
    }

    private func reconcileAll() {
        reconcileTerminals()
        reconcileSimPanes()
        reconcileDevicePanes()
        reconcilePendingPanes()
        reconcileLayoutTree()
    }

    /// Re-home this live tab VC into a different window's nav state after
    /// a cross-window drag. The `TabState` has already moved into
    /// `newVM`; this repoints every reference that resolves through the
    /// old window's `TabListViewModel` (the reconcile source, the sim-
    /// action coordinator's credential/ownership lookups, and the
    /// window id for "Open in New Tab"), then re-arms observation so the
    /// reconcile tracks and immediately syncs against the new instance.
    /// Without it, the moved VC would keep observing the source VM (where
    /// `tab(id:)` now returns nil), freezing reconcile and discovery for the
    /// tab.
    func rebind(to newVM: TabListViewModel, windowID newWindowID: WindowID) {
        tabListVM = newVM
        windowID = newWindowID
        simPaneActions.rebind(tabListVM: newVM, windowID: newWindowID)
        observation?.cancel()
        observation = App.observe { [weak self] in self?.reconcileAll() }
        titleObservation?.cancel()
        titleObservation = App.observe { [weak self] in self?.reportDisplayTitle() }
    }

    /// Push the current `TabState.paneTree` into the layout controller.
    /// `reconcileTerminals` / `reconcileSimPanes` have already built or
    /// torn down the matching VCs; the layout controller does its
    /// recursive view rebuild against the tree using those VCs.
    private func reconcileLayoutTree() {
        guard !isTornDown, let tabState = tabListVM.tab(id: tabID) else { return }
        splitVC.reconcile(tree: tabState.paneTree) { [weak self] slot in
            guard let self else { return nil }
            switch slot {
            case let .terminal(id):
                return self.terminalVCByID[id]

            case let .sim(udid):
                return self.simPaneVCByUDID[udid]

            case let .device(deviceId):
                return self.devicePaneVCByID[deviceId]

            case let .pending(pendingId):
                return self.pendingPaneVCByID[pendingId]
            }
        }
    }

    // MARK: - Title state (forwarded to titleModel)

    func updateOSCTitle(_ title: String) { titleModel.updateOSCTitle(title) }
    func updateWorkingDirectory(path: String) {
        titleModel.updateWorkingDirectory(path: path)
        latestWorkingDirectory = path
    }
    func renameManually(to title: String) { titleModel.renameManually(to: title) }

    /// Forward an intent-layer `sendInput` to the primary terminal
    /// pane's surface so the bytes flow through libghostty's input
    /// pipeline. Called by `AppDelegate`'s `IntentActionDelegate`
    /// bridging for the automation-only `deviceterm tab send-input`
    /// verb. Throws when the underlying surface refuses input (e.g.
    /// attach hasn't completed even after forced view load); the
    /// dispatcher relays the typed error.
    func sendInput(_ text: String, typeDelayMillis: Int?) throws {
        guard let primary = primaryTerminalVC() else {
            throw TerminalSurfaceError.notAttached
        }
        try primary.sendInput(text, typeDelayMillis: typeDelayMillis)
    }

    /// Resolve the **original** primary terminal pane VC, the one
    /// the daemon session bound to at tab open. Tab-scoped operations
    /// (automation's `sendInput` / `captureScreen`, tab-switch
    /// focus) must target this session regardless of where the user
    /// has dragged the pane in the tree. Reading nav-state's
    /// `primaryTerminal.id` on every call keeps the answer stable
    /// across rearranges.
    func primaryTerminalVC() -> TerminalPaneViewController? {
        guard let primaryID = tabListVM.tab(id: tabID)?.primaryTerminal.id else { return nil }
        return splitVC.terminalVC(for: primaryID)
    }

    /// Read the primary terminal pane's currently-visible viewport as
    /// plain text. Called by `AppDelegate`'s `IntentActionDelegate`
    /// for `deviceterm tab capture`. Mirrors `sendInput`'s
    /// force-load-then-throw shape.
    func captureScreen() throws -> String {
        guard let primary = primaryTerminalVC() else {
            throw TerminalSurfaceError.notAttached
        }
        return try primary.captureScreen()
    }

    // MARK: - Lifecycle

    /// Called by TabStripViewController when reconcile drops this VC. Removes
    /// its discovery observer, asks libghostty to close each terminal pane's
    /// shell, and clears any SimResurrect watches we still hold.
    func teardown() {
        isTornDown = true
        // Stop any in-flight automation-grant retry loops. The tab is going
        // away, so a lingering retry could regrant a closing session and would
        // keep the coordinator (and this VC) alive through a persistent outage.
        grantCoordinator.cancelAll()
        // Drop any queued title push: the tab's sessions are closing, so a
        // late push would only be rejected for an unknown session. A push
        // already in flight still completes and earns that rejection.
        titlePublisher.cancel()
        // Remove the reconnect observer NOW, not at deinit: a torn-down
        // controller retained elsewhere (e.g. a lingering closure) would
        // otherwise leave an app-lifetime entry in the client's registry.
        // Clear the token so `deinit` doesn't double-remove.
        if let reconnectObserverToken {
            daemonClient.removeReconnectObserver(reconnectObserverToken)
            self.reconnectObserverToken = nil
        }
        observation?.cancel()
        titleObservation?.cancel()
        if let discoveryObserverToken {
            router.removeOwnedSimDiscoveryObserver(discoveryObserverToken)
            self.discoveryObserverToken = nil
        }
        for terminalVC in terminalVCByID.values {
            terminalVC.requestClose()
        }
        for environment in sessionEnvsByID.values {
            environment.stopBootClaimRelay()
        }
        for paneVC in simPaneVCByUDID.values {
            simPaneActions.stopRecordingForCleanup(paneVC)
        }
        for udid in simPaneVCByUDID.keys {
            simResurrect.unwatch(udid: udid)
        }
    }

    // MARK: - Terminal-pane reconcile

    /// Reflect `TabState.terminals` into the per-VC dict. Each new
    /// terminal gets its own provisioned `SessionEnvironment` +
    /// libghostty surface; each removed terminal's VC is torn down.
    /// View-hierarchy placement is handled by the unified layout-
    /// tree reconcile.
    private func reconcileTerminals() {
        guard !isTornDown, let tabState = tabListVM.tab(id: tabID) else { return }
        let current = Set(terminalVCByID.keys)
        let target = Set(tabState.terminals.map(\.id))

        // Drop VCs for removed terminals. The Router has already closed
        // each removed terminal's daemon session; closing the libghostty
        // surface is enough: the layout-tree reconcile drops the view
        // alongside its sibling-tree entry.
        for terminalID in current.subtracting(target) {
            if let terminalVC = terminalVCByID.removeValue(forKey: terminalID) {
                terminalVC.requestClose()
            }
            // Stop any grant-retry loop for the removed terminal's session (the
            // Router already closed it) before we drop the env, so a parked
            // retry can't regrant a session that's being torn down.
            if let environment = sessionEnvsByID.removeValue(forKey: terminalID) {
                environment.stopBootClaimRelay()
                let sessionId = environment.sessionId
                grantCoordinator.sessionRemoved(sessionId: sessionId)
            }
        }
        // Add VCs for new terminals; the layout-tree reconcile places
        // their views per the nav-state tree.
        for terminal in tabState.terminals where !current.contains(terminal.id) {
            do {
                let env = SessionEnvironment(
                    sessionId: terminal.sessionId,
                    capability: terminal.capability,
                    daemonSocketPath: daemonSocketPath,
                    role: role,
                    onBootClaim: { [weak router] sessionId, claim, deadline in
                        router?.acceptBootClaim(
                            sessionId: sessionId,
                            claim: claim,
                            deadlineNanoseconds: deadline
                        )
                    }
                )
                try env.provision()
                sessionEnvsByID[terminal.id] = env
                let terminalVC = TerminalPaneViewController(
                    terminalID: terminal.id,
                    environment: env.shellEnvironment(),
                    cwd: terminal.cwd,
                    command: terminal.command
                )
                terminalVC.tabID = tabID
                // Minimal terminal chrome no longer shows a title;
                // tab strip carries it. (name / shortId still drive
                // upstream `TabTitleViewModel`.)
                wire(terminalVC: terminalVC, id: terminal.id)
                terminalVCByID[terminal.id] = terminalVC
            } catch {
                FileHandle.standardError.write(
                    Data(
                    "deviceterm: terminal provision failed: \(error)\n".utf8
                )
                    )
            }
        }
        // Closing the primary terminal promotes `terminals[0]`, which re-seats
        // the tab's representative session. Rebind the automatic label sources
        // in the same pass so the promoted session isn't published under the
        // departed terminal's activity string.
        let primary = tabState.primaryTerminal
        let primaryVC = terminalVCByID[primary.id]
        titleModel.adoptPrimaryTerminal(
            id: primary.id,
            oscTitle: primaryVC?.lastOSCTitle,
            workingDirectory: primaryVC?.lastWorkingDirectory,
            sessionName: primary.name
        )
    }

    /// Wire a terminal pane VC's delegate callbacks. Title / CWD
    /// updates from the primary terminal feed the tab's title model;
    /// non-primary terminals' titles are noted but don't relabel the
    /// tab: there is no surface that shows a non-primary title.
    /// Shell exit dispatches the terminal-close route, the
    /// closeTerminalPane handler decides between "just this terminal"
    /// and "the whole tab" based on remaining terminal count.
    /// Replay every live terminal's binding, invoked when the daemon
    /// connection is re-established. Each VC re-reads its surface identity and
    /// re-fires its bind callback (idempotent daemon-side).
    private func rebindAllTerminals() {
        for terminalVC in terminalVCByID.values { terminalVC.rebindTerminal() }
    }

    private func wire(terminalVC: TerminalPaneViewController, id: TerminalPaneID) {
        // The terminal's wrapper fires `onFocusGained` on every
        // false → true edge of its responder-chain hook. Stamp the
        // tab's `lastFocusedTerminal` so the spawning-terminal
        // heuristic in `Router.attachPane` lands new sims next to
        // whichever terminal the user is actually typing in (rather
        // than always next to the tab's primary).
        terminalVC.onFocusGained = { [weak self] in
            guard let self else { return }
            self.tabListVM.updateLastFocusedTerminal(id, inTab: self.tabID)
        }
        // Bind this terminal's kernel identity so an in-tab CLI process can
        // authenticate as the pane's session (the provenance "terminal" arm).
        // Single attempt: the VC owns the retry loop (it re-reads a fresh
        // identity each time). `bindTerminal` is idempotent, so a reconnect
        // replay is safe. Returns whether the bind succeeded.
        terminalVC.performBind = { [weak self] sessionId, identity in
            guard let self else { return false }
            self.sessionEnvsByID[id]?.bindBootClaimRelay(
                foregroundPid: identity.foregroundPid,
                ttyName: identity.ttyName
            )
            do {
                try await self.daemonClient.bindTerminal(
                    sessionId: sessionId,
                    foregroundPid: identity.foregroundPid,
                    ttyName: identity.ttyName
                )
            } catch {
                return false
            }
            // `bindTerminal` suspended; the bind poll task may have been
            // cancelled or the tab torn down while it was in flight. If so,
            // don't schedule a grant: teardown()'s `cancelAll` has already run,
            // and arming a new retry loop here would re-open one after it. The
            // bind itself succeeded, so still report success.
            if Task.isCancelled || self.isTornDown { return true }
            // The session is now terminal-bound. For an automation tab, hand
            // it to the grant coordinator, which issues (and, on transient
            // failure, retries with fresh revisions) the live automation
            // grant so an in-tab CLI can drive the cross-tab `tab.send-input` /
            // `tab.capture` verbs, gated on bind (not create) so the grant
            // never precedes the moment the session can be authenticated. Fires
            // on every successful bind, so a reconnect rebind reissues. This
            // schedules the work and returns immediately.
            self.grantCoordinator.sessionBound(role: self.role, sessionId: sessionId)
            return true
        }
        terminalVC.onExit = { [weak self] _ in
            guard let self else { return }
            // Read `onTerminalExit` at call time, not at wire time.
            // The primary terminal is wired during init (before the
            // strip's `wireTerminalExit` assigns the handler), so a
            // snapshot would leave the primary's exit path stuck at
            // nil and the fallback would dispatch
            // `closeTerminalPane`, which the router intentionally
            // refuses for the last surviving terminal (so the dead
            // tab would linger). Reading live picks up whatever the
            // strip has installed.
            if let handler = self.onTerminalExit {
                handler(id)
                return
            }
            // No strip handler (standalone teardown / smoke tests):
            // route to terminal close directly so the shell-exited
            // pane doesn't linger.
            self.router.dispatch(
                .closeTerminalPane(tab: self.tabID, terminal: id, mode: .detach)
            )
        }
        terminalVC.onTitleChange = { [weak self] title in
            // Only the primary terminal's OSC/title drives the tab title.
            // Non-primary title changes are silently ignored: the tab
            // strip shows one title and it belongs to the primary.
            guard let self,
                self.tabListVM.tab(id: self.tabID)?.primaryTerminal.id == id
            else { return }
            self.titleModel.updateOSCTitle(title)
        }
        terminalVC.onWorkingDirectoryChange = { [weak self] path in
            guard let self,
                self.tabListVM.tab(id: self.tabID)?.primaryTerminal.id == id
            else { return }
            self.titleModel.updateWorkingDirectory(path: path)
            self.latestWorkingDirectory = path
        }
        // Right-click "Close Pane" is an explicit user action, so it
        // routes through `onTerminalCloseRequested`: the strip drops
        // just this terminal on a multi-terminal tab and applies the
        // tab-close prompt policy for the last one. The shell-exit
        // path (`onExit` above) stays separate because a shell exit
        // is not a close gesture. Read live for the same reason as
        // the `onExit` wiring.
        terminalVC.onClosePaneRequested = { [weak self] in
            guard let self else { return }
            if let handler = self.onTerminalCloseRequested {
                handler(id)
                return
            }
            self.router.dispatch(
                .closeTerminalPane(tab: self.tabID, terminal: id, mode: .detach)
            )
        }
        // Right-click "Open in New Tab": fresh tab in this window,
        // seeded with the tab's latest cwd so the new shell lands in
        // the same directory.
        terminalVC.onOpenInNewTabRequested = { [weak self] in
            guard let self else { return }
            self.router.dispatch(
                .newTab(
                    self.windowID,
                    cwd: self.latestWorkingDirectory,
                    cmd: nil
                )
            )
        }
        // "Split Right" / "Split Down" from this pane, whether by
        // shortcut or right-click: split just this pane (`id`) along the
        // chosen axis, so a Split Right followed by a Split Down on the
        // left pane yields `[[A / C] | B]` rather than three stacked
        // rows. `isVertical` = "divider is vertical" = side-by-side =
        // `.horizontal`; the opposite (Split Down) stacks = `.vertical`.
        terminalVC.onSplitRequested = { [weak self] isVertical in
            self?.requestSplit(
                anchor: .terminal(id),
                axis: isVertical ? .horizontal : .vertical
            )
        }
    }

    /// Open a terminal pane beside `anchor` along `axis`. The single
    /// placement path for both split sources, so the new pane inherits
    /// the tab's working directory either way. That is the same value
    /// Open in New Tab passes, so a split lands where the user is
    /// working. A nil anchor appends at the root, which is where a split
    /// requested with no pane focused belongs.
    private func requestSplit(anchor: PaneSlot?, axis: SplitAxis) {
        router.dispatch(
            .openTerminalPane(
                tab: tabID,
                cwd: latestWorkingDirectory,
                cmd: nil,
                anchor: anchor,
                axis: axis
            )
        )
    }

    // MARK: - Sim-pane reconcile

    /// Reflect TabState.simPanes into the per-VC dict: create a
    /// SimulatorPaneViewController for each new SimPaneState, drop
    /// the VC for any removed one. The Router already did the
    /// daemon attach/close; this is pure AppKit. View-hierarchy
    /// placement is handled by the unified layout-tree reconcile.
    private func reconcileSimPanes() {
        guard !isTornDown, let tabState = tabListVM.tab(id: tabID) else { return }
        // A VC is bound to one daemon pane id for its lifetime: its view model
        // subscribes to that id at construction and drives every input at it.
        // The dictionary is keyed by udid, so on its own it cannot see a pane
        // whose record was replaced behind the same device, which is what
        // re-attaching after a helper restart does. Compare the id, so this
        // reconcile is right on its own terms rather than only in combination
        // with how the Router happens to sequence a re-attach.
        for simPane in tabState.simPanes {
            guard let paneVC = simPaneVCByUDID[simPane.udid],
                paneVC.paneId != simPane.paneId else { continue }
            simPaneActions.stopRecordingForCleanup(paneVC)
            // Same cleanup the removal below does, because this drops a VC
            // just as finally. A resurrect watch outliving its pane would fire
            // against whatever now holds the udid and detach it; and a watch
            // is only ever armed by a pane that went `.shutdown`, so a
            // replacement arriving under that udid means the sim is booted
            // again, which is the transition the watch was waiting for.
            simResurrect.unwatch(udid: simPane.udid)
            simPaneVCByUDID.removeValue(forKey: simPane.udid)
        }
        let current = Set(simPaneVCByUDID.keys)
        let target = Set(tabState.simPanes.map(\.udid))

        // Drop panes no longer in state. Manifest ownership is NOT
        // released here: on `.detach` the sim stays booted+owned and the
        // udid must remain in owned-udids.json as the durable orphan
        // record; on `.shutdown` the whole session dir (and manifest) is
        // wiped by Router.closeTabRecords. The mode isn't visible in
        // reconcile, so we let the dir cleanup handle the shutdown case.
        for udid in current.subtracting(target) {
            if let paneVC = simPaneVCByUDID[udid] {
                simPaneActions.stopRecordingForCleanup(paneVC)
            }
            simPaneVCByUDID.removeValue(forKey: udid)
            simResurrect.unwatch(udid: udid)
        }
        // Add new panes from state; the layout-tree reconcile drops them
        // into place per nav-state order.
        for simPane in tabState.simPanes where !current.contains(simPane.udid) {
            let paneVC = SimulatorPaneViewController(simPane: simPane, daemonClient: daemonClient)
            simPaneActions.wire(paneVC: paneVC, simPane: simPane)
            simPaneVCByUDID[simPane.udid] = paneVC
            // Sim ownership is recorded against the tab's primary
            // terminal env, so discovery attribution is
            // tab-scoped rather than per-terminal: a sim booted from
            // a non-primary terminal still attributes to the tab.
            if let primaryID = tabListVM.tab(id: tabID)?.primaryTerminal.id {
                sessionEnvsByID[primaryID]?.recordOwnership(simPane.udid)
            }
            handledUDIDs.insert(simPane.udid)
        }
    }

    // MARK: - Device-pane reconcile

    /// Reflect `TabState.devicePanes` into the per-VC dict, mirroring
    /// `reconcileSimPanes`: build a `SimulatorPaneViewController` (the
    /// shared renderer) for each new `DevicePaneState`, drop the VC for
    /// any removed one. The Router already did `physicalDevice.attach` /
    /// `closePane`; this is pure AppKit, and the unified layout-tree
    /// reconcile handles view placement. Device panes carry no recording
    /// or resurrect state, so removal is just dropping the VC: no
    /// `stopRecordingForCleanup` / `simResurrect.unwatch`.
    private func reconcileDevicePanes() {
        guard !isTornDown, let tabState = tabListVM.tab(id: tabID) else { return }
        // Same one-VC-per-pane-id rule as the sim reconcile above, keyed by
        // deviceId here, so the pane id is likewise the only thing that says
        // the record behind a device changed.
        for devicePane in tabState.devicePanes {
            guard let paneVC = devicePaneVCByID[devicePane.deviceId],
                paneVC.paneId != devicePane.paneId else { continue }
            devicePaneVCByID.removeValue(forKey: devicePane.deviceId)
        }
        let current = Set(devicePaneVCByID.keys)
        let target = Set(tabState.devicePanes.map(\.deviceId))

        for deviceId in current.subtracting(target) {
            devicePaneVCByID.removeValue(forKey: deviceId)
        }
        for devicePane in tabState.devicePanes where !current.contains(devicePane.deviceId) {
            let paneVC = SimulatorPaneViewController(
                mirroredPane: devicePane,
                daemonClient: daemonClient
            )
            wire(deviceVC: paneVC, devicePane: devicePane)
            devicePaneVCByID[devicePane.deviceId] = paneVC
        }
    }

    /// Wire a device pane VC's owner-facing callbacks. Deliberately a
    /// thin subset of the sim wiring: a device pane gets **Close Pane**
    /// (detach the mirror, the physical device keeps running) and
    /// nothing else. The sim-only lifecycle actions (reboot /
    /// live-reboot / erase / open-in-Simulator / shutdown /
    /// reveal-in-Finder) and the SimResurrect watch have no
    /// physical-device meaning and are left unattached: their
    /// context-menu items stay visible and no-op. Nothing hides
    /// them. Device reboot / screenshot / record are not implemented.
    private func wire(deviceVC paneVC: SimulatorPaneViewController, devicePane: DevicePaneState) {
        let tabID = self.tabID
        let deviceId = devicePane.deviceId
        // Stamp tabID before viewDidLoad runs so the chrome's drag host
        // has it when constructed (same rationale as the sim wiring).
        paneVC.tabID = tabID
        paneVC.onClose = { [weak self] in
            self?.router.dispatch(
                .detachDevicePane(tab: tabID, deviceId: deviceId, mode: .detach)
            )
        }
    }

    // MARK: - Pending-pane reconcile

    /// Reflect `TabState.pendingPanes` into the per-VC dict: build a
    /// `PendingPaneViewController` for each new placeholder, drop the VC
    /// for any removed one (swapped to a real pane, or cancelled), and
    /// (unlike the sim/device reconcile) *update* a live VC whose phase
    /// flipped (attaching ↔ failed) so the error + Retry surface without
    /// rebuilding the VC. Runs before `reconcileLayoutTree` so a leaf
    /// that just swapped `.pending` → `.sim`/`.device` already has its
    /// real VC ready.
    private func reconcilePendingPanes() {
        guard !isTornDown, let tabState = tabListVM.tab(id: tabID) else { return }
        let current = Set(pendingPaneVCByID.keys)
        let target = Set(tabState.pendingPanes.map(\.id))

        for pendingId in current.subtracting(target) {
            pendingPaneVCByID.removeValue(forKey: pendingId)
        }
        for pending in tabState.pendingPanes {
            if let existing = pendingPaneVCByID[pending.id] {
                existing.update(pending: pending)
                continue
            }
            let paneVC = PendingPaneViewController(pending: pending)
            wire(pendingVC: paneVC, pendingId: pending.id)
            pendingPaneVCByID[pending.id] = paneVC
        }
    }

    /// Wire a pending placeholder's Retry / Close buttons to the Router.
    /// Retry re-runs the attach whose first try threw; Close cancels the
    /// in-flight attach and drops the placeholder.
    private func wire(pendingVC paneVC: PendingPaneViewController, pendingId: PendingPaneID) {
        let tabID = self.tabID
        paneVC.onRetry = { [weak self] in
            self?.router.dispatch(.retryPendingPane(tab: tabID, pendingId: pendingId))
        }
        paneVC.onCancel = { [weak self] in
            self?.router.dispatch(
                .cancelPendingPane(tab: tabID, pendingId: pendingId, mode: .detach)
            )
        }
    }

    // MARK: - Discovery snapshots

    private func discoverBootedSims(in owned: [DeviceListEntry]) {
        guard !isTornDown else { return }
        // Discovery is tab-scoped: any sim owned by any terminal in
        // this tab counts as discoverable here. In practice that is
        // the same set as "owned by primary terminal" because
        // discovery attributes to the primary; the broader filter
        // is shaped for a world where non-primary terminals can be
        // booters.
        let tabSessionIds: Set<String>
        if let tab = tabListVM.tab(id: tabID) {
            tabSessionIds = Set(tab.terminals.map(\.sessionId))
        } else {
            tabSessionIds = []
        }
        let ownedBooted = OwnedSimDecision.booted(ownedBy: tabSessionIds, in: owned)
        let mounted = tabListVM.tab(id: tabID)?.simPanes.map(\.udid) ?? []
        // Sims with an in-flight / failed pending pane count as
        // "attaching" so a racing poll doesn't insert a second
        // placeholder (or stomp a visible failed one) for the same sim.
        let attaching = tabListVM.tab(id: tabID)?.pendingPanes.compactMap { pending -> String? in
            if case let .sim(udid) = pending.target { return udid }
            return nil
        } ?? []
        let decision = DiscoveryDecision.decide(
            ownedBooted: ownedBooted,
            handled: handledUDIDs,
            attaching: Set(attaching),
            mounted: Set(mounted)
        )
        handledUDIDs = decision.updatedHandled
        for device in decision.toAttach {
            if isTornDown { return }
            // Mark handled at dispatch time so a follow-up poll doesn't
            // re-fire before the Router updates simPanes.
            handledUDIDs.insert(device.udid)
            router.dispatch(
                .attachSimPane(
                tab: tabID,
                udid: device.udid,
                displayName: device.name,
                family: device.family
            )
                )
        }
    }
}
