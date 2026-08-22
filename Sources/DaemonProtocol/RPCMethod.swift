// SPDX-License-Identifier: GPL-3.0-or-later
//
// RPCMethod: the canonical, single-source-of-truth set of RPC method
// names every process uses. Defined in DaemonProtocol (Foundation-only,
// shared by daemon, GUI client, deviceterm-cli, and shim) so a method name
// is spelled exactly once on the wire instead of re-typed as a raw
// string literal at each call site.
//
// The daemon's `MethodRegistry` is keyed by `rawValue`; the GUI client,
// CLI, and shim build requests from these cases. The rawValues ARE the
// wire contract. They must never change without a `wireVersion` bump
// (see `DaemonProtocolInfo` + the Wire-compatibility policy). Mirrors
// the `RPCEnvelope.MessageType` string-enum pattern.
//
// `CaseIterable` backs the drift guard (DaemonTests) that asserts the
// daemon registry's keys exactly equal these cases: adding a registry
// method without a case here (or vice versa) fails that test.

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
    /// retry). A protected session disappears from `tabs.list` for every
    /// caller except the owner: the "protected tab is opaque to other
    /// principals" rule.
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
    /// `session.setDisplayTitle({sessionId, title}) → {ok: true}`. Publish
    /// the tab's live label (shell OSC 0/2 title, manual rename, whichever
    /// won the GUI's title precedence) so `tabs.list` can serve it in place
    /// of the static name stamped at `session.create`. What crosses the
    /// wire is the normalized, bounded form, and only when it says
    /// something `name` does not; readers fall back to `name` otherwise.
    /// A null `title` clears the cached value; the daemon holds titles in
    /// memory only and drops one with its session. `.validatedGUI`-scoped:
    /// the GUI is the only process that sees OSC sequences, so it is the
    /// only writer, and no capability rides on the wire. The title is
    /// normalized (controls and bidi controls stripped, bounded) on both
    /// sides of the wire.
    case sessionSetDisplayTitle = "session.setDisplayTitle"
    case tabsList = "tabs.list"
    case panesList = "panes.list"

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
    /// Session-scoped because the annotation reuses the `tabs.list`
    /// protected-tab opacity rules. Backs the CLI `deviceterm devices list`.
    case devicesList = "devices.list"

    // pane.* (lifecycle)
    case paneCreate = "pane.create"
    /// `pane.closeById`: close a sim pane by its concrete daemon
    /// `paneId`. The lower-level primitive used by the GUI's Router
    /// fan-out (tab/window close → per-pane shutdown) and by
    /// `SimulatorPaneViewModel`'s in-pane shutdown action. The CLI's
    /// user-facing `pane close` verb is the higher-level
    /// `RPCMethod.paneClose` below (which takes a `Wire.PaneRef` and
    /// dispatches through the Intent layer to resolve the ref).
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
    /// `pane.input.rotate`: an absolute `orientation`, or a `direction`
    /// the daemon resolves against the orientation it last successfully
    /// commanded on that pane. Exactly one of the two.
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
    /// `windows.list` / etc. publish into the stream and await the
    /// GUI's `app.commandResult` reply correlated by `commandId`.
    case appCommands = "app.commands"

    /// `app.commandResult`: the GUI calls this once per published
    /// `AppCommand` after dispatch. Daemon-wide method (no session
    /// creds required, since the GUI's subscription connection is what
    /// authorizes it implicitly). The daemon's `AppCommandCoordinator`
    /// resumes the pending continuation keyed by `commandId`.
    case appCommandResult = "app.commandResult"

    // MARK: - tab.*: verbs the CLI invokes; daemon publishes to GUI
    // via the back-channel above.

    case tabOpen = "tab.open"
    case tabClose = "tab.close"
    case tabRename = "tab.rename"
    case tabSelect = "tab.select"
    case tabInfo = "tab.info"
    /// `tab.move`: reorder a tab within its window (`--to <index>`) or
    /// move it to another window (`--to-window <ref>`). Publishes to the
    /// GUI back-channel like the other tab verbs; the GUI reorders via
    /// `Route.reorderTab` or relocates the live tab across windows.
    case tabMove = "tab.move"

    // MARK: - pane.* (multi-pane CLI verbs)

    case paneOpenTerminal = "pane.openTerminal"
    /// `pane.close`: the CLI's user-facing pane close verb. Takes
    /// `{pane: Wire.PaneRef, mode: String}` and flows through the
    /// Intent layer (publishVerb → AppCommand → IntentDispatcher →
    /// Router) so a ref like `--pane <shortId>` resolves against
    /// the GUI's live workspace. The lower-level `paneCloseById`
    /// (above) is the by-paneId primitive the Router uses internally
    /// for tab/window-close fan-out; the two coexist deliberately so
    /// the CLI verb keeps the natural wire name while the
    /// daemon-internal primitive is explicit about taking a paneId.
    case paneClose = "pane.close"
    case paneRename = "pane.rename"
    case paneInfo = "pane.info"
    case paneMove = "pane.move"
    case paneAttach = "pane.attach"

    // MARK: - window.*

    case windowOpen = "window.open"
    case windowClose = "window.close"
    case windowFocus = "window.focus"
    case windowsList = "windows.list"

    // MARK: - tab.* (automation-only read/write verbs)

    /// `tab.sendInput`: automation-only. CLI's `deviceterm tab
    /// send-input --tab <ref> <text>` flows through the back-channel
    /// publish-verb to the GUI's `IntentDispatcher`, which writes
    /// `text` into the resolved tab's terminal surface via
    /// `IntentActionDelegate.sendInput`. Daemon registers this case
    /// at `.automationTab` scope so a caller without a live
    /// automation grant is rejected at the dispatcher's scope check
    /// before reaching the handler.
    case tabSendInput = "tab.sendInput"
    /// `tab.capture`: automation-only. CLI's `deviceterm tab
    /// capture [--tab <ref>]` returns the resolved tab's currently-
    /// visible viewport as plain text. Flows through publishVerb;
    /// the GUI reads via `IntentActionDelegate.captureTab` and
    /// returns a `TabCapturePayload` in `app.commandResult.data`.
    case tabCapture = "tab.capture"
    /// `tab.setProtected`: toggle the resolved tab's protection flag.
    /// Session-scoped (auth required) but owner-only enforcement
    /// happens GUI-side in the IntentDispatcher: it gates the
    /// dispatch when the resolved tab's terminals don't include
    /// the caller's session id, returning `intent.notFound` rather
    /// than leaking the tab's existence. The GUI resolves the tab to
    /// its terminal-pane sessions and flips them atomically via the
    /// daemon's `session.setProtectedBatch`.
    case tabSetProtected = "tab.setProtected"
    /// `automation.grant`: issue live automation grants for a tab's
    /// sessions. `.validatedGUI`-scoped: only a signature-validated GUI
    /// peer over XPC may call it, and the grant is attributed to that
    /// connection. Automation authority is the presence of a live
    /// grant, checked per request (never a persisted role) so a forged
    /// manifest role grants nothing. UDS can never reach this method.
    case automationGrant = "automation.grant"
    /// `automation.revoke`: revoke the live automation grants for the
    /// given sessions (tab closed or downgraded). `.validatedGUI`-scoped;
    /// UDS can never reach it. Revocation is immediate: a socket
    /// authenticated before the revoke loses authority on its next call.
    case automationRevoke = "automation.revoke"
}
