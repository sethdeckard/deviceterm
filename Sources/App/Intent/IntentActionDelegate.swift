// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Delegate for intent actions the Router doesn't model:
/// tab rename and concrete-pane operations. Wired by
/// `AppDelegate` at composition time; provides bridges into the
/// `TabStripViewController` / `TabContentViewController` /
/// `TerminalPaneViewController` surfaces that own the relevant
/// state.
@MainActor
protocol IntentActionDelegate: AnyObject {
    /// Apply a manual title to a tab. `name == nil` restores the
    /// automatic label (CWD basename / OSC title / session name).
    func renameTab(window: WindowID, tab: TabID, to name: String?)

    /// Rename one concrete pane. `daemonPaneId` is present for Simulator and
    /// physical-device panes, whose daemon-direct resolver mirrors the name.
    func renamePane(
        window: WindowID,
        tab: TabID,
        slot: PaneSlot,
        daemonPaneId: String?,
        to name: String?
    ) async throws

    /// Inject text into one concrete terminal pane.
    func sendInput(
        window: WindowID,
        tab: TabID,
        terminal: TerminalPaneID,
        text: String,
        typeDelayMillis: Int?
    ) throws

    /// Capture one concrete terminal pane's visible viewport.
    func captureTerminal(
        window: WindowID,
        tab: TabID,
        terminal: TerminalPaneID,
        ansi: Bool
    ) throws -> String

    /// Give a concrete pane leaf keyboard focus.
    func focusPane(window: WindowID, tab: TabID, slot: PaneSlot)

    /// Live presentation values owned by the AppKit controller tree.
    func tabDisplayTitle(window: WindowID, tab: TabID) -> String?
    /// One terminal's live label, tty, working directory, and foreground
    /// process, read together.
    ///
    /// `includeProcessFacts` gates only `TerminalPaneFacts.cwd` and
    /// `foregroundProcess`, the grant-scoped fields here; the caller owns that
    /// decision and this hop does not re-derive it. Passing false also skips
    /// the kernel reads that produce them, which are the expensive half.
    func terminalFacts(
        window: WindowID,
        tab: TabID,
        terminal: TerminalPaneID,
        includeProcessFacts: Bool
    ) -> TerminalPaneFacts?
    func focusedPane(window: WindowID, tab: TabID) -> PaneSlot?
    /// Every pane's slot frame in one tab, in points from the top-left of the
    /// tab's pane area. Read once per tab, because one layout pass produces
    /// them all. A tab that is not on screen reports its last layout's frames.
    /// One whose view has not loaded reports none, and a slot that has not
    /// been laid out reports a zero-area rectangle. Nil when no live
    /// controller holds the tab.
    func paneFrames(window: WindowID, tab: TabID) -> [PaneSlot: CGRect]?
    func paneLifecycle(window: WindowID, tab: TabID, slot: PaneSlot) -> PaneLifecycle?
    func paneOrientation(window: WindowID, tab: TabID, slot: PaneSlot) -> Orientation?
    /// The latest known pixel dimensions, initially from the attach response
    /// and updated from received surfaces. Nil when valid dimensions are
    /// unavailable.
    ///
    /// Live, unlike the attach response's size on the pane state: a fold
    /// moves a foldable onto a panel of a different size.
    func panePixelSize(window: WindowID, tab: TabID, slot: PaneSlot) -> (width: Int, height: Int)?

    /// Relocate a live tab into a different window at `atIndex`. The
    /// Router can't do this (it has no AppKit access to move the tab's
    /// view controller), so the CLI `deviceterm tab move --window`
    /// path hops through the AppDelegate transfer coordinator here.
    func moveTabAcrossWindows(_ tab: TabID, from: WindowID, to destination: WindowID, atIndex: Int)

    /// Bring a window to the front, make it key, and activate the app.
    /// The `WindowController` map lives on the AppDelegate and the
    /// Router has no AppKit access, so `window.focus` hops through here
    /// instead of routing. Silently no-ops unless a live window
    /// controller is registered for the id: the window may be closing,
    /// or newly added and not yet reconciled.
    func raiseWindow(_ window: WindowID)
}

extension IntentActionDelegate {
    func renamePane(
        window: WindowID,
        tab: TabID,
        slot: PaneSlot,
        daemonPaneId: String?,
        to name: String?
    ) {}

    func focusPane(window: WindowID, tab: TabID, slot: PaneSlot) {}
    func tabDisplayTitle(window: WindowID, tab: TabID) -> String? { nil }
    func terminalFacts(
        window: WindowID,
        tab: TabID,
        terminal: TerminalPaneID,
        includeProcessFacts: Bool
    ) -> TerminalPaneFacts? { nil }
    func focusedPane(window: WindowID, tab: TabID) -> PaneSlot? { nil }
    func paneFrames(window: WindowID, tab: TabID) -> [PaneSlot: CGRect]? { nil }
    func paneLifecycle(window: WindowID, tab: TabID, slot: PaneSlot) -> PaneLifecycle? { nil }
    func paneOrientation(window: WindowID, tab: TabID, slot: PaneSlot) -> Orientation? { nil }
    func panePixelSize(window: WindowID, tab: TabID, slot: PaneSlot) -> (width: Int, height: Int)? { nil }
}
