// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Lifecycle + shell-integration callbacks from an embedded terminal pane back
/// to its host.
///
/// Pinned to the main actor for the same reason `TerminalSurface` is: the
/// callbacks originate from the engine's main-thread callbacks and land on
/// AppKit views.
@MainActor
public protocol TerminalSurfaceDelegate: AnyObject {
    /// OSC 0/2: process/window title. Drives the tab title.
    func terminalSurface(_ surface: any TerminalSurface, didChangeTitle title: String)

    /// OSC 7: shell working directory. Enables "new tab here".
    func terminalSurface(_ surface: any TerminalSurface, didChangeWorkingDirectory path: String)

    /// The shell/child process exited. `code` is nil if it was
    /// signalled rather than exiting normally. The host closes the
    /// pane in response.
    func terminalSurface(_ surface: any TerminalSurface, didExitWithCode code: Int32?)

    /// Terminal bell (BEL / OSC). Host decides audible vs. visual.
    func terminalSurfaceWantsBell(_ surface: any TerminalSurface)

    /// Scrollback geometry update: emitted whenever the scrollback
    /// grows, the viewport moves, or the visible row count changes.
    /// The host uses this to drive a visible scrollbar (via the
    /// `SurfaceScrollView` wrapper). Default impl is a no-op so a
    /// host that doesn't render a scrollbar (e.g. the libghostty
    /// harness) doesn't need to implement it.
    func terminalSurface(
        _ surface: any TerminalSurface,
        didUpdateScrollbar state: ScrollbarState
    )

    /// The engine reported a new terminal background color (OSC 11
    /// or equivalent). The host uses it to keep UI chrome in sync:
    /// the scroll wrapper switches the scroller appearance to
    /// match. Default impl is a no-op for hosts that don't tint
    /// chrome.
    func terminalSurface(
        _ surface: any TerminalSurface,
        didChangeBackgroundColor color: TerminalBackgroundColor
    )
}

public extension TerminalSurfaceDelegate {
    func terminalSurface(
        _ surface: any TerminalSurface,
        didUpdateScrollbar state: ScrollbarState
    ) {}

    func terminalSurface(
        _ surface: any TerminalSurface,
        didChangeBackgroundColor color: TerminalBackgroundColor
    ) {}
}
