// SPDX-License-Identifier: GPL-3.0-or-later

/// The canonical, single-source-of-truth set of RPC method
/// names every process uses. Defined in DaemonProtocol (Foundation-only,
/// shared by daemon, GUI client, deviceterm-cli, and shim) so a method name
/// is spelled exactly once on the wire instead of re-typed as a raw
/// string literal at each call site.
///
/// The daemon's `MethodRegistry` is keyed by `rawValue`; the GUI client,
/// CLI, and shim build requests from these cases. The rawValues ARE the
/// wire contract, so changing one is wire-incompatible and needs explicit
/// approval for a `DaemonProtocolInfo.wireVersion` bump. Mirrors the
/// `RPCEnvelope.MessageType` string-enum pattern.
///
/// `CaseIterable` backs the drift guard (DaemonTests) that asserts the
/// daemon registry's keys exactly equal these cases: adding a registry
/// method without a case here (or vice versa) fails that test.
public enum RPCMethod: String, Sendable, Equatable, CaseIterable {
    // daemon.*
    case daemonPing = "daemon.ping"
    case daemonShutdown = "daemon.shutdown"

    // session.* / tabs.* / panes.*
    case sessionCreate = "session.create"
    case sessionClose = "session.close"
    /// `session.authenticate`: binds a UDS connection to a session
    /// for the connection's lifetime. The CLI auto-sends this as
    /// the first frame on every connection whose env carries
    /// session creds; the daemon stores the resulting SessionState
    /// on the `RPCConnection`. Session-scoped methods on the same
    /// connection thereafter dispatch without re-checking creds at
    /// the wire (the dispatcher reads the connection's auth state).
    /// `error.unauthorized` on stale/wrong creds; daemon-wide
    /// methods work whether the connection auth'd or not.
    case sessionAuthenticate = "session.authenticate"
    /// `session.bindTerminal({sessionId, foregroundPid, ttyName})
    /// → {ok: true}`. The validated GUI binds a session to the kernel
    /// identity of its terminal: it reads the surface's foreground process id
    /// and controlling tty name from libghostty and asks the daemon to derive
    /// and store a terminal anchor. `.validatedGUI`-scoped: the audit token
    /// is the authority; UDS can never reach it. The daemon re-derives the
    /// anchor from the kernel (never trusting the raw pid/tty) and matches a
    /// later in-tab UDS caller's `session.authenticate` against it: the
    /// "terminal" provenance arm that lets a non-owner in-tab process
    /// authenticate as the session while an out-of-tab cap thief cannot.
    case sessionBindTerminal = "session.bindTerminal"
    /// `session.setProtectedBatch({sessionIds, isProtected, revision})
    /// → {applied, revision, isProtected}`. Atomically flip the protection flag
    /// for every session backing one tab, subject to daemon-side
    /// `(epoch, revision)` last-write-wins (a stale batch returns
    /// `applied: false` without mutating). `.validatedGUI`-scoped: the
    /// peer's audit token is the
    /// authority, so no `(sessionId, cap)` handshake rides on the wire.
    /// All-or-none: the daemon validates every id before mutating, so a
    /// multi-terminal tab can never be left in a torn protected/unprotected
    /// state. `isProtected` is the desired absolute state (idempotent on
    /// retry). Protection-filtered daemon session and device projections hide
    /// a protected session from every caller except its owner.
    case sessionSetProtectedBatch = "session.setProtectedBatch"
    /// `session.restoreBatch({sessions: [RestoredSession]})
    /// → {restoredCount, sessionIds}`. A live, signature-validated GUI
    /// re-supplies its COMPLETE session inventory. This is BOTH restart
    /// restoration (bringing sessions back to a fresh daemon after a daemon-only
    /// restart) AND ongoing authoritative inventory reconciliation: the GUI
    /// re-sends it whenever its live session set changes, so a closed session's
    /// tombstone is reclaimed by the first inventory that OMITS it rather than
    /// accumulating until a reconnect. `.validatedGUI`-scoped: the audit token is
    /// the authority, UDS can never reach it, and the issuer/owner come
    /// from the dispatch context, never the payload. The daemon holds NO
    /// session from disk (a fresh daemon starts empty and the GUI restores
    /// session state); this is the sole path by which sessions come back. It is
    /// an AUTHORITATIVE, `(epoch, tier, revision)`-fenced, all-or-none
    /// transaction: a strictly older restore key is rejected while an equal key
    /// may replay idempotently; a live session the complete inventory OMITS is
    /// reconciled away as an abandoned ghost when this batch's key dominates the
    /// one that asserted it (so a newer connection or a higher-revision
    /// same-connection retry can reap it); a batch updates a live session's
    /// protection under the same rule; and a session closed since the inventory was
    /// captured is NOT resurrected. A
    /// malformed / duplicate / verifier-conflicting batch is rejected in full.
    /// Processing any non-stale batch (even empty)
    /// releases the restoration barrier: before it, an unknown-session
    /// `session.authenticate` is retryable `notReady`; after it, terminal
    /// `unauthorized`.
    case sessionRestoreBatch = "session.restoreBatch"
    /// `session.protectionSnapshot({sessionIds, revision})
    /// → {fenced, revision, sessions: [{sessionId, state}]}`. An
    /// ordering-fenced authoritative read of tab protection: in one actor turn
    /// the daemon snapshots every requested session AND advances each live
    /// one's `(epoch, revision)` key to this request's key, so a delayed
    /// older write subsequently loses (`applied: false`). Only a
    /// `fenced: true` result is authoritative. `.validatedGUI`-scoped. The
    /// GUI reconciles tab presentation from this after a rejection, a stale
    /// `applied: false`, or a superseded indeterminate send.
    case sessionProtectionSnapshot = "session.protectionSnapshot"
    /// `session.setDisplayTitle({sessionId, title}) → {ok: true}`. Cache the
    /// tab's live label under its representative terminal session. What
    /// crosses the wire is normalized and bounded, and the GUI omits a label
    /// that merely repeats the session's creation-time name.
    /// A null `title` clears the cached value; the daemon holds titles in
    /// memory only and drops one with its session. `.validatedGUI`-scoped:
    /// the GUI is the only process that sees OSC sequences, so it is the
    /// only writer, and no capability rides on the wire. The title is
    /// normalized (controls and bidi controls stripped, bounded) on both
    /// sides of the wire.
    case sessionSetDisplayTitle = "session.setDisplayTitle"
    /// `session.setCohort({operation, cohortId, revision, …})
    /// → {applied, revision, outcome?, bindings?}`. Curates the session
    /// cohort that jointly controls a device pane, which is how pane
    /// authority reaches every terminal in a tab instead of only the one
    /// that attached. The daemon never learns the cohort is a tab: it stores
    /// verified session incarnations, an ordered membership, and a
    /// representative, all under an opaque GUI-minted id.
    ///
    /// Two operations share the method because they mutate the same cohort
    /// and must order against each other on one `(epoch, revision)`
    /// sequence. `reconcile` installs a complete membership, optionally
    /// replacing a named prior cohort (retired for good in the same commit)
    /// and binding pane records at an expected attachment. `beginClose`
    /// commits a close verdict for the named members and returns the
    /// authoritative `CohortCloseOutcome` the GUI records before closing
    /// them; it is idempotent under its GUI-minted `transitionId`, journalled
    /// before the reply, so a retry after a lost reply returns the identical
    /// verdict rather than promoting twice, for as long as the journal entry
    /// is retained (the boot-claim lease).
    ///
    /// `.validatedGUI`-scoped. A UDS caller must never reach it: membership
    /// decides who may drive another session's pane, and a close verdict
    /// decides who inherits its simulator.
    case sessionSetCohort = "session.setCohort"
    /// Daemon-direct device-pane roster used internally by device-control
    /// verbs. The public workspace inventory is `pane.list` below.
    case paneDeviceList = "pane.deviceList"

    // shim.*
    case shimEvent = "shim.event"

    // device.* (CoreSimulator lifecycle, sim only)
    case deviceList = "device.list"
    case deviceBoot = "device.boot"
    case deviceShutdown = "device.shutdown"
    case deviceAttach = "device.attach"
    /// `device.reconcileBootClaim({claim, sessionId?})` converges one
    /// GUI-retained boot attempt after a timeout or daemon replacement.
    /// `.validatedGUI`-scoped; a claim is promoted to ownership only after
    /// CoreSimulator reports the simulator as Booted.
    case deviceReconcileBootClaim = "device.reconcileBootClaim"
    /// `device.restoreOwnership({devices: [{udid, sessionId?}]})
    /// → {restoredCount, udids}`. The simulator counterpart to
    /// `session.restoreBatch`: a validated GUI restores deviceterm's owned-sim
    /// claims to a daemon that came back holding nothing, preserving a live
    /// session attribution where one exists. A sim carried by a pane is
    /// restored by re-attaching the pane; this is what brings back one the
    /// user detached, which has no pane to carry it. `.validatedGUI`-scoped,
    /// because ownership attribution on another session's behalf is exactly
    /// what a UDS caller must not be able to assert. Additive and
    /// fail-closed: it never reaps an omitted udid, never overwrites an
    /// attribution the daemon already holds, and claims only a sim
    /// CoreSimulator reports as Booted right now. Neither boots anything nor
    /// mints a pane.
    case deviceRestoreOwnership = "device.restoreOwnership"

    // physicalDevice.* / devices.*: physically-connected iPhone/iPad.
    /// `physicalDevice.list`: connected physical devices (daemon-wide;
    /// device *availability* reveals no protected-tab state). Feeds the GUI
    /// "Mirror Physical Device…" picker.
    case physicalDeviceList = "physicalDevice.list"
    /// `physicalDevice.attach`: mount one physical device as a pane.
    /// Device-identity params only; the originating session comes from
    /// the connection's authenticated context (the connection-auth
    /// convention for new verbs, no `sessionId`/`cap` params).
    case physicalDeviceAttach = "physicalDevice.attach"
    /// `devices.list`: the aggregate live roster (booted sims +
    /// connected physical devices) annotated with pane/ownership state.
    /// Session-scoped because the annotation reuses the `tab.list`
    /// protected-tab opacity rules. Backs the CLI `deviceterm devices list`.
    case devicesList = "devices.list"

    // pane.* (lifecycle)
    case paneCreate = "pane.create"
    /// `pane.setName({paneId, name}) → {ok: true}`. The validated GUI
    /// mirrors a public `pane rename` into the daemon so daemon-direct device
    /// commands resolve the same pane names as the GUI-owned workspace view.
    case paneSetName = "pane.setName"
    /// `pane.closeById`: close a sim pane by its concrete daemon
    /// `paneId`. The lower-level primitive used by the GUI's Router
    /// fan-out (tab/window close → per-pane shutdown) and by
    /// `SimulatorPaneViewModel`'s in-pane shutdown action. The CLI's
    /// user-facing `pane close` verb is the higher-level
    /// `RPCMethod.paneClose` below, which relays the raw public pane ref
    /// through the Intent layer for GUI-owned workspace resolution.
    case paneCloseById = "pane.closeById"

    // pane.input.*
    case paneInputTap = "pane.input.tap"
    case paneInputTouch = "pane.input.touch"
    case paneInputSwipe = "pane.input.swipe"
    /// `pane.input.edgeSwipe`: an edge-tagged drag that drives the
    /// simulator's system gestures (home indicator / App Switcher).
    /// Distinct from `swipe` because it carries the originating screen
    /// `edge`; sim-only.
    case paneInputEdgeSwipe = "pane.input.edgeSwipe"
    /// `pane.input.edgeTouch`: a single edge-tagged live touch event, the
    /// per-event analogue of `pane.input.touch`. A live GUI mouse drag from
    /// the displayed bottom edge streams these (down/move/lift) so the
    /// App Switcher follows the cursor; sim-only (carries the originating
    /// screen `edge`).
    case paneInputEdgeTouch = "pane.input.edgeTouch"
    case paneInputLongPress = "pane.input.longPress"
    case paneInputKey = "pane.input.key"
    case paneInputButton = "pane.input.button"
    /// `pane.input.rotate`: an absolute `orientation`, or a relative
    /// `direction`. The daemon resolves a Simulator direction from confirmed
    /// framebuffer orientation. It sends a physical-device direction directly
    /// and uses the relay-reported landing as the target. Exactly one of the two.
    case paneInputRotate = "pane.input.rotate"
    case paneInputPinch = "pane.input.pinch"
    /// `pane.input.multitouch`: live two-finger streaming
    /// (`down`/`move`/`up`), the interactive counterpart to the
    /// replayed `pane.input.pinch`. The GUI's Option-drag pinch/rotate
    /// streams contact updates through this; the CLI keeps the replay
    /// `pinch` verb. Params carry exactly two contact points.
    case paneInputMultitouch = "pane.input.multitouch"
    case paneInputText = "pane.input.text"
    case paneInputCrown = "pane.input.crown"

    // pane.ax.*
    case paneAXTree = "pane.ax.tree"
    case paneAXPoint = "pane.ax.point"
    case paneAXSweep = "pane.ax.sweep"

    // MARK: - pane.location.*: simulated GPS position
    //
    // Both are `.validatedGUI`, which UDS can never reach
    // (`MethodScope.validatedGUIReachable` returns false for `.uds`
    // unconditionally). Location is a GUI affordance with no CLI verb,
    // because the CLI's "no simctl wrappers" reject list names `location`
    // explicitly. Tagging the scope makes "GUI only" a dispatch fact: no
    // CLI, script, or in-tab agent can reach it even by hand-rolling a
    // UDS frame, and the methods stay out of the `allowedMethods` a UDS
    // caller is advertised, so the promise `deviceterm agents` prints
    // holds at every surface.

    /// `pane.location.set`: apply a `SimulatedLocation` (coordinate,
    /// named scenario, GPX route, or cleared) to the pane's device. One
    /// method for all of them because they are values of one device
    /// property, not separate operations.
    case paneLocationSet = "pane.location.set"
    /// `pane.location.state`: the location deviceterm last applied plus
    /// the scenarios the device offers. The value is deviceterm's own
    /// claim, not a device reading, because neither backend has a getter.
    /// It can go stale if something else moves the device.
    case paneLocationState = "pane.location.state"

    // subscriptions
    case paneSubscribe = "pane.subscribe"
    /// `pane.surfaceRelease`: one-way notification (no `id`, no
    /// response). The GUI acks the cumulative low-water mark of surface
    /// generations it still holds, per `(paneId, subscriptionToken,
    /// leaseEpoch)`; the daemon frees committed generations below it.
    /// Honored only from the connection that registered the token (the
    /// pool stores the registering connection and rejects a foreign
    /// peer's ack). Session-scoped: only a connection that authenticated
    /// to subscribe can meaningfully send it.
    case paneSurfaceRelease = "pane.surfaceRelease"
    /// `pane.surfaceDrain`: one-way notification (no `id`, no response)
    /// tearing down a surface subscription, keyed by the originating
    /// `pane.subscribe` request id so it works even before any token or
    /// side-band exists. Transport-intercepted on XPC (the subscription
    /// task lives on the connection, keyed by that request id); over UDS,
    /// which vends no surface lane, the registered handler is a no-op.
    case paneSurfaceDrain = "pane.surfaceDrain"
    /// `daemon.events`: long-running, session-scoped event stream
    /// (the caller's own pane state changes + session lifecycle, plus
    /// every device boot/shutdown). Powers `deviceterm events`.
    case daemonEvents = "daemon.events"

    /// `daemon.capabilities`: daemon-wide method advertising the
    /// caller's role and the methods they may invoke. Works with or
    /// without session creds; out-of-tab callers get the daemon-wide
    /// subset and `role: nil`. Powers role-aware `deviceterm --help`
    /// and `deviceterm doctor`'s allowedMethods axis.
    case daemonCapabilities = "daemon.capabilities"

    // MARK: - app.*: daemon ↔ GUI back-channel for tab/pane/window
    // verbs the daemon can't perform on its own.

    /// `app.commands` (subscription): daemon-published stream of
    /// `AppCommand` frames the GUI executes via its
    /// `IntentDispatcher`. The GUI subscribes once at startup;
    /// daemon-side handlers for `tab.close` / `pane.close` /
    /// `window.list` / etc. publish into the stream and await the
    /// GUI's `app.commandResult` reply correlated by `commandId`.
    case appCommands = "app.commands"

    /// `app.commandResult`: the GUI calls this once per published
    /// `AppCommand` after dispatch. `.validatedGUI`-scoped and accepted only
    /// from the active `app.commands` subscriber connection. The daemon's
    /// `AppCommandCoordinator` resumes the pending continuation keyed by
    /// `commandId`.
    case appCommandResult = "app.commandResult"

    // MARK: - Public workspace API

    case windowList = "window.list"
    case windowShow = "window.show"
    case windowOpen = "window.open"
    case windowFocus = "window.focus"
    case windowClose = "window.close"

    case tabList = "tab.list"
    case tabShow = "tab.show"
    case tabOpen = "tab.open"
    case tabFocus = "tab.focus"
    case tabClose = "tab.close"
    case tabRename = "tab.rename"
    case tabMove = "tab.move"
    case tabProtect = "tab.protect"
    case tabUnprotect = "tab.unprotect"

    case paneList = "pane.list"
    case paneShow = "pane.show"
    case paneSplit = "pane.split"
    case paneFocus = "pane.focus"
    case paneClose = "pane.close"
    case paneRename = "pane.rename"
    case paneSendInput = "pane.sendInput"
    case paneCaptureText = "pane.captureText"

    /// Internal publication used by device attach and shim flows.
    case paneAttach = "pane.attach"
    /// `automation.grant`: issue live automation grants for a tab's
    /// sessions. `.validatedGUI`-scoped: only a signature-validated GUI
    /// peer over XPC may call it, and the grant is attributed to that
    /// connection. Automation authority is the presence of a live
    /// grant, checked per request (never a persisted role) so a forged
    /// manifest role grants nothing. UDS can never reach this method.
    case automationGrant = "automation.grant"
}
