// SPDX-License-Identifier: GPL-3.0-or-later
//
// Route: every navigation intent as a pure value. All navigation
// flows through `Router.dispatch(_:)`: menu actions, the
// discovery/resurrect loops, and (future) CLI/daemon-driven or
// restored navigation. Unidirectional: intent (Route) → router →
// state (nav view models) → reconcile (AppKit glue).
//
// `openWindow` carries `reattach` because a window is never empty: the
// handler creates the window *and* its initial tab in one ordered step
// (matching makeWindow + openInitialTab), avoiding a second
// dispatch that would have to chain on an id not yet allocated.

import DaemonProtocol

enum Route: Sendable {
    /// New window + its initial tab; `reattach` mounts cold-start orphans.
    /// `cwd`/`command` parameterize that initial tab the same way
    /// `newTab` does, so a windowless invocation (e.g. Settings… with no
    /// key window) can open a window whose first tab already runs a
    /// command, avoiding a second dispatch that would chain on a
    /// not-yet-allocated window id.
    case openWindow(
        reattach:
        [OrphanRecord] = [],
        cwd:
        String? = nil,
        command:
        [String]? = nil
        )
    /// Close every tab in the window then drop it. `mode` is `.detach`
    /// (sims keep running) or `.shutdown` (sims stop + scratch dirs are
    /// cleaned); the quit path uses the user-chosen mode here.
    case closeWindow(
        WindowID,
        mode:
        PaneCloseMode = .detach
        )
    case selectWindow(WindowID)
    /// Add a tab to an existing window; `reattach` mounts orphan sims.
    /// The minted session is always `.agent` role.
    ///
    /// `cwd` overrides the new shell's working directory (defaults to
    /// the GUI's CWD when nil). `cmd` is the command line typed into
    /// the shell after attach (libghostty's `initial_input`). It runs
    /// once and leaves the user at an interactive prompt. Both ride
    /// from `deviceterm tab open --cwd <path> --cmd '<cmd>'`.
    case newTab(
        WindowID,
        reattach: [OrphanRecord] = [],
        cwd: String? = nil,
        cmd: [String]? = nil
    )
    /// Add a fresh tab whose session has `.orchestrator` role. The only
    /// product-UI path for minting the orchestrator role, fed by the
    /// File-menu item of the same name and intentionally unreachable from
    /// any CLI verb. The role is descriptive metadata, not authority:
    /// cross-tab verbs are gated by a live orchestration grant, not the
    /// role. The daemon refuses an orchestrator mint that doesn't arrive
    /// over XPC from a signature-validated peer, and the CLI provides no
    /// verb that would emit one.
    ///
    /// `cwd` / `cmd` semantics match `newTab`; the menu item passes
    /// nil for both, but the shape is symmetric so an
    /// orchestrator-spawn intent could populate them.
    case openOrchestratorTab(
        WindowID,
        cwd: String? = nil,
        cmd: [String]? = nil
    )
    case selectTab(WindowID, TabID)

    /// Drives Select Next / Previous Tab. Resolves `delta` against the
    /// selection when the serial drain handles the route, wrapping at both
    /// ends. Deferring resolution preserves each repeated press queued
    /// behind an in-flight route.
    case selectRelativeTab(WindowID, delta: Int)

    /// Drives Move Tab Left / Right. Moves the named tab by `delta` slots
    /// when the destination is in bounds; an out-of-range move is a no-op,
    /// and it never wraps.
    ///
    /// Carries the tab's identity but not its index. The identity is what
    /// the user pointed at when they pressed, and a route draining in
    /// between can change the selection: `newTab` selects its new tab once
    /// `createSession` returns. The index has to be read on the drain, or
    /// presses queued behind an in-flight route would share a destination.
    /// `reorderTab` remains the absolute form the drag handler and the
    /// `tab.move` RPC use.
    case moveTabRelative(WindowID, TabID, delta: Int)
    case closeTab(
        WindowID,
        TabID,
        mode:
        PaneCloseMode
        )
    /// Add an additional terminal pane to an existing tab. Mints a
    /// fresh daemon session whose role inherits the tab's role; the
    /// reconcile pass adds the new TerminalPaneViewController to the
    /// split. The CLI verb `deviceterm pane open --terminal` flows
    /// through here via the Intent layer.
    ///
    /// `cwd` / `cmd` semantics match `newTab`.
    ///
    /// `anchor`/`axis`/`side` place the new pane relative to an existing
    /// one. The Split Right / Split Down path passes the pane being
    /// split as `anchor` so only that pane is split, nesting a
    /// sub-split when `axis` differs from the anchor's parent. With all
    /// three nil, the CLI / Intent path appends at the root along the
    /// tree's current axis.
    ///
    /// `anchor` is a `PaneSlot` rather than a `TerminalPaneID` so a
    /// device pane can be one: splitting beside a focused sim puts the
    /// new terminal where the user is looking, and only the slot type
    /// can name that position.
    case openTerminalPane(
        tab: TabID,
        cwd: String? = nil,
        cmd: [String]? = nil,
        anchor: PaneSlot? = nil,
        axis: SplitAxis? = nil,
        side: AdjacentSide = .after
    )
    /// Remove a terminal pane from a tab. Refuses to remove the last
    /// one (use `closeTab` instead). The handler closes the
    /// terminal's daemon session (cap-authenticated) before dropping
    /// the entry from `TabState.terminals`.
    case closeTerminalPane(
        tab: TabID,
        terminal: TerminalPaneID,
        mode: PaneCloseMode
    )
    /// Mount a sim pane on a tab (device.attach). Discovery, resurrect,
    /// and orphan re-attach all funnel through here, one mounting path.
    /// `atIndex` restores a pane to its original slot in the typed
    /// `simPanes` array on resurrect; nil appends. `anchor` carries
    /// the pane's pre-detach tree neighbor so resurrect lands the
    /// fresh leaf back where the user saw it instead of next to the
    /// spawning terminal. `nil` falls back to the spawning-terminal
    /// placement that the discovery / orphan-recovery / claim paths
    /// expect. `displayName == nil` tells the Router to look up the
    /// real device name via `daemon.deviceList`, used by callers
    /// (`deviceterm pane attach`) that don't have the name handy and
    /// would otherwise have to pass a UDID-prefix placeholder.
    ///
    /// `family` (wire string, optional) sizes the in-flight placeholder
    /// pane with the same metrics the real pane will take so the success
    /// swap doesn't resize. The discovery poll passes the booted sim's
    /// `device.list` family (the watch hot path); other callers pass nil
    /// (→ phone-default, corrected on swap).
    case attachSimPane(
        tab: TabID,
        udid: String,
        displayName: String?,
        family: String? = nil,
        atIndex: Int? = nil,
        anchor: ResurrectAnchor? = nil
    )
    /// `expecting` fences the close to one admission. `dispatch` only
    /// enqueues onto the serial drain, so before the handler runs a
    /// resurrect can replace the tab's pane for this udid, or a re-attach
    /// can re-admit the same paneId under a new attachment. Either way the
    /// handler would otherwise resolve the udid to something the user was
    /// never asked about and close that, `.shutdown` included. Nil resolves
    /// by udid alone, which is what the CLI and the internal cleanup paths
    /// want.
    case detachSimPane(
        tab:
        TabID,
        udid: String,
        mode: PaneCloseMode,
        expecting: PaneAdmission? = nil
        )
    /// Mount a physically-connected device pane on a tab
    /// (`physicalDevice.attach`). The picker, the CLI `device attach`
    /// verb, and the `devicectl` shim intercept all funnel through here,
    /// one mounting path paralleling `attachSimPane`. The handler
    /// calls `daemon.attachPhysicalDevice(deviceId:sessionId:)` with the
    /// tab's primary-terminal session (the GUI threads the target
    /// session explicitly because its one shared connection can't pick
    /// the tab via connection-auth). `displayName == nil` falls back to
    /// the attach response's `name` / `deviceType`. Unlike sims, there is no
    /// `atIndex` / `anchor` placement metadata: helper-restart recovery keeps
    /// a device pane's slot by replacing its leaf in place, so there is no
    /// original position to record.
    case attachDevicePane(
        tab: TabID,
        deviceId: String,
        displayName: String?
    )
    case detachDevicePane(
        tab: TabID,
        deviceId: String,
        mode: PaneCloseMode
    )
    /// Retry a failed pending pane: re-run the attach whose first try
    /// threw. Dispatched by the placeholder pane's Retry button. No-op
    /// unless the pending pane is in `.failed` (re-entrancy guard).
    case retryPendingPane(tab: TabID, pendingId: PendingPaneID)
    /// Cancel/close a pending pane (the placeholder's Close button, or
    /// teardown). Cancels the in-flight attach Task and drops the leaf;
    /// if the attach later returns a pane id, the Task closes it so the
    /// daemon pane + IOSurface stream don't leak.
    case cancelPendingPane(tab: TabID, pendingId: PendingPaneID, mode: PaneCloseMode)
    /// Toggle the tab's privacy flag. The handler flips every terminal
    /// session in the tab in one atomic `session.setPrivateBatch` so the
    /// daemon can never hold a torn private/public set; the GUI mirror
    /// updates only on a successful ack.
    case setTabPrivate(
        tab:
        TabID,
        isPrivate: Bool
        )
    /// Same-window tab reorder: move `tab` to `toIndex` in its
    /// window's strip. The tab-strip drag destination (same-window
    /// drops) and the Move Tab Left/Right menu both dispatch this; the
    /// handler delegates to `TabListViewModel.move`, and the strip's
    /// order-sensitive render diff rebuilds the pills. Cross-window
    /// moves do NOT come through here; they relocate a live view
    /// controller and live in the AppDelegate transfer coordinator.
    case reorderTab(WindowID, TabID, toIndex: Int)
    /// Drag-to-rearrange: move `slot` next to `target` per `zone`.
    /// `.center` swaps; `.leftHalf` / `.rightHalf` reorder along the
    /// horizontal axis (possibly creating a new sub-split); top/bottom
    /// reorder along the vertical axis. The handler delegates to
    /// `TabListViewModel.reorderPane`; the recursive layout
    /// reconciles to the resulting tree.
    case reorderPane(
        tab: TabID,
        slot: PaneSlot,
        target: PaneSlot,
        zone: DropZone
    )
    /// Toggle Split Direction (⌃⇧D): flip the axis of the split that
    /// directly contains `slot` (the focused pane). Only that split
    /// re-orients; panes outside it stay put. A no-op on a single-pane
    /// tab (no split to flip). The recursive layout picks up the change
    /// on the next reconcile.
    case flipSplitAxis(tab: TabID, slot: PaneSlot)
    /// Re-attach every mounted sim and device pane onto a freshly-connected
    /// helper.
    ///
    /// Pane records live in the helper's memory and nothing persists them, so
    /// a reconnect that reached a replacement holds none of the ones the
    /// workspace is showing. It may instead have reached the same helper,
    /// which can drop a connection without exiting, leaving its records
    /// intact. Re-attaching covers both, because a surviving record is handed
    /// back to its owning session rather than duplicated. Sessions return
    /// through the restore batch and terminal anchors are rebound separately;
    /// this is what brings the mirrors back alongside them. Dispatched once per reconnect, after
    /// that restore is verified, since the attaches are session-scoped and
    /// would be refused before it.
    case recoverPanes
}
