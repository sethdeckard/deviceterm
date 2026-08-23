// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabState: the value record of one open tab in the navigation
// model: its identity, the terminal panes (each backing its own
// daemon session), the sim panes attached to it, and the role
// assigned at tab open. The AppKit glue keys its
// TabContentViewController / per-pane controllers off these ids and
// reconciles to match.
//
// `shortId` (Crockford base32, 6 chars, daemon-minted, immutable) +
// `name` (mutable, optional) are the identifier model and ride
// alongside `paneId` on `SimPaneState`. Both fields are Optional in
// the GUI model since they decode from Optional wire fields (skew
// tolerance against an older daemon during a Sparkle update window);
// current daemons always emit them.
//
// `terminals` is non-empty: every tab is born with one terminal
// pane (the primary, index 0) and additional terminals are added via
// `Route.openTerminalPane`. `closeTerminalPane` refuses to remove
// the last entry (use `closeTab` instead). `primaryTerminal` is the
// safe accessor for callers that need a representative session
// (tab-info, status item grouping, sim-pane attribution for the
// discovery snapshot).

import DaemonProtocol
import Foundation

/// A tab's protection as two axes collapsed into one value: what the daemon
/// has *committed* (confirmed on the wire) and what the tab *presents*
/// right now. Keeping them separate is what lets a protection transition be
/// fail-closed without lying about the committed state:
///
///  - `.unprotected`: committed unprotected, no transition; the only
///    non-hidden state.
///  - `.protected`: committed protected (also the resting state of a
///    protected→unprotected transition, which stays hidden until its ack).
///  - `.pendingProtected`: hidden but not committed: either an
///    unprotected→protected transition is in flight (hidden immediately,
///    fail-closed, commits to `.protected` only on the ack), or a
///    reconciliation left the tab hidden-and-unresolved (a mixed /
///    unfenced / membership-changed `session.protectionSnapshot`). The tab
///    is never exposed from this state except by an authoritative signal: a
///    fenced uniform-unprotected snapshot or the owning transition's
///    highest-key unprotect ack.
///
/// `isEffectivelyProtected` (absolute) drives tab chrome and the protection a
/// new terminal inherits; `externallyAccessible` (caller-relative, in
/// `IntentResolver`) drives what an external caller may reach.
enum TabProtectionState: Equatable, Sendable {
    case unprotected
    case protected
    case pendingProtected
}

struct SimPaneState: MirroredPaneState, Equatable, Sendable {
    /// Daemon pane id from device.attach. The glue creates a pane VM for
    /// this id (the attach already happened in the Router).
    let paneId: String
    /// See `MirroredPaneState.attachment`.
    let attachment: UInt64?
    let udid: String
    let displayName: String
    /// Coarse device family (drives watch-aware pane sizing).
    let family: String
    /// Daemon-minted Crockford base32 short_id (6 chars). Optional in
    /// the GUI model: nil when decoded from a pre-identifier-model
    /// daemon response. Consumers (status item grouping, pane-ref
    /// resolution) treat nil as "fall back to udid / paneId for
    /// display." Defaults nil so synthetic test fixtures stay terse;
    /// production instances are constructed by the Router with the
    /// response's values.
    let shortId: String?
    /// Optional pane name, echoed back from `pane.create` /
    /// `device.attach`. The daemon emits nil at create and populates it
    /// on `deviceterm pane rename`, so this is nil until the pane state
    /// is rebuilt from a later response.
    let name: String?
    /// Native pixel width of the device's display, from the daemon's
    /// attach response. Drives the size-preset math (Physical / Point
    /// Accurate / Pixel Accurate / Fit Screen). Nil when the renderable
    /// hasn't bound a surface yet at attach time, in which case the chrome
    /// falls back to family-default sizing.
    let pixelWidth: Int?
    /// Pairs with `pixelWidth`.
    let pixelHeight: Int?
    /// Per-pane device-control capabilities from the daemon's attach
    /// response. Nil when decoded from an older daemon that omits the
    /// block. The VM resolves nil to `.simulator` (historical
    /// all-enabled behavior).
    let capabilities: PaneCapabilities?

    /// `MirroredPaneState` identity: a sim pane keys on its UDID.
    var target: PaneTarget { .sim(udid: udid) }

    init(
        paneId: String,
        udid: String,
        displayName: String,
        family: String,
        attachment: UInt64? = nil,
        shortId: String? = nil,
        name: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        capabilities: PaneCapabilities? = nil
    ) {
        self.paneId = paneId
        self.attachment = attachment
        self.udid = udid
        self.displayName = displayName
        self.family = family
        self.shortId = shortId
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.capabilities = capabilities
    }
}

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
    /// load-bearing sim drag / resurrect / orphan-recovery code keeps
    /// hard-referencing `simPanes` untouched; both render through the
    /// same `SimulatorPaneViewController`. Unlike sims, device panes are
    /// **never** persisted and have no resurrect watch, so a device that
    /// drops and returns doesn't re-mount itself. Helper-restart recovery
    /// re-attaches one, but only a pane the tab is already showing, not a
    /// pane restored from somewhere: a `TabState` is still always born with
    /// this empty, and the seeding loop below is for symmetry.
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
    /// `terminals` / `simPanes`; those arrays stay as typed lookup
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
    /// `Router.attachPane` as the spawning-terminal heuristic so a
    /// `xcrun simctl boot Foo` typed in pane B places the booted
    /// sim adjacent to B (not next to the tab's primary terminal,
    /// which is the fallback). Nil only before the first focus
    /// event, at which point `primaryTerminal` is the fallback.
    var lastFocusedTerminal: TerminalPaneID?

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
        // Seed the layout tree: primary terminal as a single leaf,
        // then sibling-append every other terminal and every sim along
        // the horizontal axis (matches the pre-tree default). The
        // mutation methods on `TabListViewModel` (`addTerminal`,
        // `addSimPane`, `reorderPane`) take over once the tab is live.
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
