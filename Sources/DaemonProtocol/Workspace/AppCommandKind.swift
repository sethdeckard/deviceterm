// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Stable discriminator strings for daemon-to-GUI back-channel frames.
public enum AppCommandKind: String, Codable, Sendable, CaseIterable {
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

    /// Internal attach publication used by the shim and device attach path.
    /// It is not exposed as a `pane` CLI subcommand.
    case paneAttach = "pane.attach"
}
