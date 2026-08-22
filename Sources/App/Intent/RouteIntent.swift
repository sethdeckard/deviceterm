// SPDX-License-Identifier: GPL-3.0-or-later
//
// RouteIntent: source-agnostic, typed value describing what an
// external (or in-process) caller wants the app to do.
//
// This is the boundary type between input sources (CLI verbs over the
// daemon back-channel, deep-link URLs, menu actions, future
// AppleScript / accessibility input) and the GUI's `Router`. Each
// input source has a small translator (`CLIIntentTranslator` today,
// one per source as they land) that produces values of this type;
// `IntentDispatcher` is the single consumer that resolves refs,
// validates, and either synthesizes a `Route` for the Router to
// execute (mutating intents) or reads from the workspace directly
// (info / list intents). Nobody outside this layer needs to know
// where the intent came from.
//
// Why a separate enum from `Route`: `Route` uses `WindowID` / `TabID`,
// internal monotonic IDs the Router mints. `RouteIntent` uses
// external refs (`TabRef`, `PaneRef`, `WindowRef`) so input sources
// don't have to chase the GUI's allocation order. The split keeps
// the resolver as the only place that needs read access to the
// workspace's id maps; consumers stay pure.

import DaemonProtocol
import Foundation

enum RouteIntent: Sendable, Equatable {
    // MARK: - Window-level

    /// Open a fresh window. The newly-allocated window gets one
    /// agent-role tab by default. Maps to `Route.openWindow`.
    case openWindow

    /// Close a window. `mode` decides what happens to any sims it
    /// holds: `.detach` keeps them booted; `.shutdown` stops them
    /// and reaps their scratch dirs.
    case closeWindow(
        WindowRef,
        mode:
        PaneCloseMode
        )

    /// Bring a window to the front. No mutation beyond key-window
    /// reassignment.
    case focusWindow(WindowRef)

    /// Read-only: list the workspace's windows, restricted to what the
    /// origin may see. `all == false` returns just the caller's own
    /// window; `all == true` returns every window in the caller-visible
    /// projection: windows/tabs another session protects are omitted
    /// and indices count only the visible ones. In-process callers see
    /// the raw workspace.
    case windowsList(
        all:
        Bool
        )

    // MARK: - Tab-level

    /// Open a new tab in a target window (`nil` = the caller's own window
    /// via the origin-aware `.current`, not the human's key window).
    /// `role` mirrors the locked refinement: `.agent` for the
    /// standard path; `.automation` only when the caller is the
    /// menu's "Open Automation Tab" item (the CLI never emits
    /// `.automation` here). `cmd` is the automation-only initial
    /// command: present only on automation-issued intents.
    case openTab(
        inWindow: WindowRef?,
        role: SessionRole,
        cwd: String?,
        cmd: [String]?
    )

    /// Close a tab. Same mode semantics as `closeWindow`.
    case closeTab(
        TabRef,
        mode:
        PaneCloseMode
        )

    /// Rename a tab. `name == nil` restores the automatic label
    /// (CWD basename / OSC title).
    case renameTab(
        TabRef,
        name:
        String?
        )

    /// Make a tab the selected one in its window.
    case selectTab(TabRef)

    /// Read-only: tab metadata for the resolved ref.
    case tabInfo(TabRef)

    /// Move a tab: reorder within its window (`toWindow == nil`,
    /// `toIndex` required) or relocate to another window (`toWindow`
    /// set; `toIndex == nil` appends at the end). The CLI `deviceterm
    /// tab move` verb is the only source; same-window reorders
    /// dispatch `Route.reorderTab`, cross-window moves hop through the
    /// action delegate to the AppDelegate transfer coordinator.
    case moveTab(TabRef, toIndex: Int?, toWindow: WindowRef?)

    // MARK: - Pane-level (terminal + sim)

    /// Open a fresh terminal pane as an in-tab split, alongside the
    /// tab's existing panes.
    case openPaneTerminal(
        inTab: TabRef?,
        cwd: String?,
        cmd: [String]?
    )

    /// Close a sim pane.
    case closePane(
        PaneRef,
        mode:
        PaneCloseMode
        )

    /// Rename a sim pane. `name == nil` restores the device's
    /// display name as the label.
    case renamePane(
        PaneRef,
        name:
        String?
        )

    /// Read-only: pane metadata.
    case paneInfo(PaneRef)

    /// Move a sim pane to a different tab in the workspace.
    /// Currently a no-op intent on the daemon side (the pane's
    /// session-link is what travels with it; the GUI re-parents
    /// the surface VC). Reserved for the linkage-refinement work.
    case movePane(
        PaneRef,
        toTab:
        TabRef
        )

    /// Claim an unlinked sim: the `.sim` arm of `device attach <ref>`.
    /// The udid must currently have no live linked session (external sim
    /// or sim left over from a closed agent tab); on success a fresh pane
    /// record is bound to the calling session.
    case paneAttach(
        udid:
        String
        )

    /// Mount a physically-connected device: the `.device` arm of
    /// `device attach <ref>`, and the shim's contextual auto-attach.
    /// `deviceId` is the device's stable CoreDevice UDID. Mounting one is
    /// always explicit and there is no resurrect watch; the one thing that
    /// re-attaches a device by itself is helper-restart recovery, which
    /// works from panes the workspace already holds and never comes through
    /// here. `relinkExisting`
    /// moves the mirror here when the device is already shown in another
    /// tab (set by the shim's contextual trigger); when false, an attach
    /// against a device mirrored elsewhere is rejected.
    case devicePaneAttach(
        deviceId: String,
        relinkExisting: Bool
        )

    // MARK: - Grant-gated cross-tab read/write

    /// Write `text` into the resolved tab's terminal as though the
    /// user had typed it. Authorized by a live automation grant, not
    /// a role; the dispatcher's scope check rejects an ungranted caller
    /// before this intent is constructed. The GUI's `IntentActionDelegate`
    /// receives the resolved (window, tab, text) triple and writes
    /// through to the tab's terminal surface. `typeDelayMillis`, when
    /// positive, animates the injection one character at a time (for
    /// screencasts); `nil` = instant one-shot.
    case sendInput(
        TabRef,
        text:
        String,
        typeDelayMillis: Int?
        )

    /// Read the resolved tab's currently-visible viewport as plain
    /// text. Authorized by a live automation grant, not a role.
    /// Dispatcher resolves the ref, asks `IntentActionDelegate.captureTab`
    /// for the text, and returns a `.data(.tabCapture(...))`
    /// payload the CLI prints to stdout.
    case captureTab(TabRef)

    /// Toggle the resolved tab's protection flag. CLI verb is
    /// `deviceterm tab set-protected <true|false>`. Ownership is enforced
    /// GUI-side by the origin/owner gate in `IntentDispatcher`: an
    /// external caller can only target a tab whose terminal sessions
    /// include its own. The CLI requests the transition through
    /// `tab.setProtected`; only the validated GUI can issue the underlying
    /// `.validatedGUI` `session.setProtectedBatch` that performs it.
    case setTabProtected(
        TabRef,
        isProtected:
        Bool
        )
}
