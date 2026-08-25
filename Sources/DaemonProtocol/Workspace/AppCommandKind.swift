// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Discriminator for `AppCommand.kind`. Stable strings so an older
/// GUI/CLI pair can read newer wire frames and fail gracefully.
public enum AppCommandKind: String, Codable, Sendable, CaseIterable {
    case tabOpen        = "tab.open"
    case tabClose       = "tab.close"
    case tabRename      = "tab.rename"
    case tabSelect      = "tab.select"
    case tabInfo        = "tab.info"
    /// `deviceterm tab move`: reorder within the window (`toIndex`) or
    /// relocate to another window (`toWindow`). The GUI reorders via
    /// `Route.reorderTab` or moves the live tab across windows.
    case tabMove        = "tab.move"
    case paneOpenTerminal = "pane.openTerminal"
    case paneClose      = "pane.close"
    case paneRename     = "pane.rename"
    case paneInfo       = "pane.info"
    case paneMove       = "pane.move"
    case paneAttach     = "pane.attach"
    case windowOpen     = "window.open"
    case windowClose    = "window.close"
    case windowFocus    = "window.focus"
    case windowsList    = "windows.list"
    /// `deviceterm tab send-input`: write into a tab's shell as
    /// though the user had typed. Grant-gated on the daemon side
    /// (a live automation grant, not a role); the GUI's
    /// IntentDispatcher writes through to the resolved tab's terminal
    /// surface via `IntentActionDelegate`.
    case tabSendInput = "tab.sendInput"
    /// `deviceterm tab capture`: read the resolved tab's currently-
    /// visible viewport as plain text. Grant-gated on the daemon side
    /// (a live automation grant, not a role); the GUI's
    /// IntentDispatcher reads via `IntentActionDelegate.captureTab` and
    /// returns the text as a `TabCapturePayload` on the back-channel result.
    case tabCapture = "tab.capture"
    /// `deviceterm tab set-protected`: toggle the resolved tab's protection
    /// flag. Ownership is enforced GUI-side by the origin/owner gate (an
    /// external caller may only target a tab it owns a terminal in). A CLI
    /// socket can request the transition, but only the validated GUI can
    /// call the `session.setProtectedBatch` that performs it. When set, the
    /// tab disappears from `tabs.list` for every caller except the owner.
    case tabSetProtected = "tab.setProtected"
}
