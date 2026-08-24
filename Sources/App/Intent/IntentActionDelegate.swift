// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Delegate for intent actions the Router doesn't model:
/// tab rename, send-input. Wired by
/// `AppDelegate` at composition time; provides bridges into the
/// `TabStripViewController` / `TabContentViewController` /
/// `TerminalPaneViewController` surfaces that own the relevant
/// state.
@MainActor
protocol IntentActionDelegate: AnyObject {
    /// Apply a manual title to a tab. `name == nil` restores the
    /// automatic label (CWD basename / OSC title / session name).
    func renameTab(window: WindowID, tab: TabID, to name: String?)

    /// Inject `text` into the resolved tab's terminal as though the
    /// user had typed it (the engine's normal input pipeline
    /// processes it, control bytes included). Throws when the
    /// tab's terminal surface isn't attached yet or the delegate
    /// can't reach it; the dispatcher relays the error to the
    /// originating CLI handler. `typeDelayMillis`, when positive,
    /// paces the injection one character at a time; the call returns
    /// once the animation is *enqueued* (non-blocking, so the
    /// back-channel ack isn't held for the typing duration).
    /// `nil`/`0` = the instant one-shot.
    func sendInput(
        window: WindowID,
        tab: TabID,
        text: String,
        typeDelayMillis: Int?
    ) throws

    /// Read the resolved tab's currently-visible viewport as plain
    /// text. Throws when the tab's terminal surface isn't attached
    /// yet, the read fails at the engine layer, or the delegate
    /// can't reach the tab; the dispatcher relays the error to
    /// the originating CLI handler.
    func captureTab(window: WindowID, tab: TabID) throws -> String

    /// Relocate a live tab into a different window at `atIndex`. The
    /// Router can't do this (it has no AppKit access to move the tab's
    /// view controller), so the CLI `deviceterm tab move --to-window`
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
