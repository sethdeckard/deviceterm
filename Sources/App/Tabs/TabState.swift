// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The value record of one open tab in the navigation
/// model: its identity, the terminal panes (each backing its own
/// daemon session), the sim panes attached to it, and the role
/// assigned at tab open. The AppKit glue keys its
/// TabContentViewController / per-pane controllers off these ids and
/// reconciles to match.
///
/// `shortId` (Crockford base32, 6 chars, daemon-minted, immutable) +
/// `name` (mutable, optional) are the identifier model and ride
/// alongside `paneId` on `SimPaneState`. Both fields are Optional in
/// the GUI model since they decode from Optional wire fields (skew
/// tolerance against an older daemon during a Sparkle update window);
/// current daemons always emit them.
///
/// `terminals` is non-empty: every tab is born with one terminal
/// pane (the primary, index 0) and additional terminals are added via
/// `Route.openTerminalPane`. `closeTerminalPane` refuses to remove
/// the last entry (use `closeTab` instead). `primaryTerminal` is the
/// safe accessor for callers that need a representative session
/// (tab-info, status item grouping, sim-pane attribution for the
/// discovery snapshot).
struct TabState: Identifiable, Equatable, Sendable {
    let id: TabID
    /// The daemon-side session cohort standing for this tab: the id under
    /// which the Router reconciles the tab's terminal sessions so siblings
    /// may drive its device panes. Minted here, opaque to the daemon, and
    /// stable for the tab's whole life, across daemon restarts included;
    /// the emptied cohort record daemon-side stays revivable under the same
    /// id, which is what a restore's re-reconcile relies on.
    let cohortId: UUID
    /// Non-empty list of terminal panes. Index 0 is the primary
    /// terminal, the one created when the tab opened and the
    /// fallback target for tab-scoped operations (tab-info `sessionId`,
    /// sim-pane attribution, the automation's `tab send-input`
    /// destination).
    var terminals: [TerminalPaneState]
    /// Role the daemon assigned at session creation (descriptive
    /// metadata, not an authorization gate). Defaults
    /// to `.agent` for the standard tab-open path; the GUI's "Open
    /// Automation Tab" menu is the product-UI path that yields
    /// `.automation`. Immutable for the tab's lifetime; re-roleing
    /// requires closing and re-opening the tab through the menu. The
    /// role is tab-wide: every terminal pane inherits it at session
    /// create-time.
    let role: SessionRole
    var simPanes: [SimPaneState]
    /// Physically-connected device panes attached to this tab. A
    /// separate typed array from `simPanes` (parallel to it) so the
    /// established sim drag / resurrect / orphan-recovery code keeps
    /// hard-referencing `simPanes` untouched; both render through the
    /// same `SimulatorPaneViewController`. Unlike sims, device panes are
    /// **never** persisted. Two things re-attach one, and both work from a
    /// pane the tab is already showing rather than a pane restored from
    /// somewhere: helper-restart recovery, and the resurrect watch that
    /// re-mirrors a device whose mirror stopped. A new tab defaults this to
    /// empty; the seeding loop in `init` handles state passed in explicitly.
    var devicePanes: [DevicePaneState]
    /// Placeholder panes for sim/device attaches that are in flight (or
    /// failed, awaiting Retry). A GUI-only concept the daemon never sees:
    /// the Router inserts a pending pane the instant the user acts, runs
    /// the attach off the serial route drain, then swaps the placeholder
    /// for the real `SimPaneState`/`DevicePaneState`. Each has a
    /// `.pending(id)` leaf in `paneTree`. Always born empty (a tab is
    /// never created mid-attach), so there is no init seeding loop.
    var pendingPanes: [PendingPaneState]
    /// Recursive pane layout tree: the single source of truth for
    /// pane ordering and nesting inside this tab. Mutated only via
    /// `TabListViewModel` (which calls into `PaneTreeOps` so the
    /// invariants below hold). The tree's leaves index into
    /// `terminals`, `simPanes`, `devicePanes`, and `pendingPanes`; those
    /// arrays stay as typed lookup
    /// storage so the rest of the codebase can fetch a pane's state
    /// by id without walking the tree.
    ///
    /// Invariants enforced by `TabListViewModel`:
    ///  - every `.terminal(id)` leaf has a matching entry in
    ///    `terminals`, no duplicates;
    ///  - every `.sim(udid)` leaf has a matching entry in
    ///    `simPanes`, no duplicates;
    ///  - every `.device(deviceId)` leaf has a matching entry in
    ///    `devicePanes`, no duplicates;
    ///  - every `.split` has ≥2 children (single-child splits
    ///    compact at mutation time);
    ///  - `extents.count == children.count` for every `.split`.
    var paneTree: PaneNode
    /// Protection as a committed-vs-presentation state (see
    /// `TabProtectionState`). The Router drives transitions through it; the
    /// resolver and tab chrome read the derived `isProtected` /
    /// `isEffectivelyProtected` below. Mirror of the daemon's per-session
    /// protection, kept GUI-side for fast tab-strip + Route lookups.
    var protectionState: TabProtectionState

    /// The *committed* protection the daemon has confirmed. True only when
    /// the tab has actually landed protected. An unprotected→protected
    /// transition still in flight reads `false` here even though the tab is
    /// already hidden: `isEffectivelyProtected` is the axis presentation and
    /// the context-menu title read.
    var isProtected: Bool { protectionState == .protected }

    /// Whether the tab is hidden *right now*: absolute, no caller and no
    /// owner exception. False only when fully unprotected. This is the
    /// fail-closed axis: an unprotected→protected transition flips it before the
    /// daemon confirms. Drives tab chrome and the protection a newly-added
    /// terminal inherits (`session.create` `initialProtected`).
    var isEffectivelyProtected: Bool { protectionState != .unprotected }
    /// Most-recently-focused terminal in this tab. Updated by the
    /// terminal pane wrapper's responder-chain hook every time
    /// libghostty's surface gains first responder. Read by
    /// `Router.attachPaneOptimistically` as the spawning-terminal heuristic so a
    /// `xcrun simctl boot Foo` typed in pane B places the booted
    /// sim adjacent to B (not next to the tab's primary terminal,
    /// which is the fallback). Nil until the first focus event, or after
    /// the recorded terminal is removed; `primaryTerminal` is the fallback.
    var lastFocusedTerminal: TerminalPaneID?
    /// The pane this tab last held keyboard focus in, restored when the
    /// tab is selected again. Written on every pane's focus-gained
    /// edge, so unlike `lastFocusedTerminal` it names sim and device
    /// panes too, and it answers a different question: which pane the
    /// user was working in, not which terminal should adopt a sim.
    ///
    /// Never a `.pending` slot, because a placeholder has no wrapper to
    /// report focus from. Focusing one and switching away therefore
    /// restores whichever pane was remembered before it.
    ///
    /// Not cleared when the named pane goes away. Every read resolves
    /// it against the currently mounted panes
    /// (`PaneFocusRestoreDecision`), so a stale value is inert, and
    /// keeping it lets the memory survive the detach/re-attach cycle
    /// that replaces a sim pane's record behind the same udid.
    var lastFocusedPane: PaneSlot?

    /// The primary terminal pane at index 0, always present. Tab-scoped
    /// operations (sim-pane attribution, `tab info`'s reported
    /// session, automation `send-input` default target) use this.
    var primaryTerminal: TerminalPaneState { terminals[0] }

    init(
        id: TabID,
        terminals: [TerminalPaneState],
        simPanes: [SimPaneState],
        devicePanes: [DevicePaneState] = [],
        role: SessionRole = .agent,
        isProtected: Bool = false
    ) {
        precondition(!terminals.isEmpty, "TabState must have at least one terminal pane")
        self.id = id
        self.cohortId = UUID()
        self.terminals = terminals
        self.role = role
        self.simPanes = simPanes
        self.devicePanes = devicePanes
        self.pendingPanes = []
        self.protectionState = isProtected ? .protected : .unprotected
        self.lastFocusedTerminal = nil
        self.lastFocusedPane = nil
        // Seed the layout tree: primary terminal as a single leaf, then
        // sibling-append every other terminal, sim, and device along the
        // horizontal axis. The mutation methods on `TabListViewModel`
        // (`addTerminal`, `addPendingPane`, `reorderPane`) take over once
        // the tab is live.
        var tree: PaneNode = .leaf(.terminal(terminals[0].id))
        for terminal in terminals.dropFirst() {
            tree = PaneTreeOps.append(
                leaf: .terminal(terminal.id),
                axis: .horizontal,
                in: tree
            )
        }
        for sim in simPanes {
            tree = PaneTreeOps.append(
                leaf: .sim(udid: sim.udid),
                axis: .horizontal,
                in: tree
            )
        }
        for device in devicePanes {
            tree = PaneTreeOps.append(
                leaf: .device(deviceId: device.deviceId),
                axis: .horizontal,
                in: tree
            )
        }
        self.paneTree = tree
    }
}
