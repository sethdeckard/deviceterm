// SPDX-License-Identifier: GPL-3.0-or-later
//
// TerminalSurface: the engine-agnostic contract for an embedded
// terminal pane.
//
// This module is deliberately libghostty-free. `App` depends on this
// protocol to host + drive a terminal pane; `LibghosttyBridge`
// provides the concrete `GhosttyTerminalSurface` conformance. Keeping
// the C framework out of the contract means the GUI target doesn't
// transitively link libghostty just to reference `TerminalSurface`,
// and a future engine swap is a single-conformance change.
//
// Ownership model (forced by libghostty's C API): the surface OWNS
// its PTY. libghostty `posix_spawn`s the shell itself from the
// `TerminalCommand` it's handed; there is no byte-stream-in API. So
// this protocol describes *what to run*, not a pipe to feed. The
// daemon issues the session credentials, the GUI assembles them into
// the shell environment, and both ride through `TerminalCommand`.
//
// Threading: `@MainActor`. libghostty's surface API is main-thread-
// only and the view is an AppKit NSView; the whole protocol is pinned
// to the main actor so conformances and call sites inherit it.

import AppKit

@MainActor
public protocol TerminalSurface: AnyObject {
    /// The view to embed in a window/pane. The engine installs its own
    /// Metal-backed layer on this view. Don't pre-set `.layer` /
    /// `.wantsLayer` or host other sublayers in it.
    var view: NSView { get }

    /// Lifecycle + OSC notifications (title, cwd, child exit, bell).
    /// Weak by convention on the conformer; the host owns the surface.
    var delegate: TerminalSurfaceDelegate? { get set }

    /// The terminal cell metrics in points (width × height). The host
    /// uses cell height to map between row indices and pixel offsets
    /// when driving the scrollbar (the `SurfaceScrollView` wrapper
    /// reads it for thumb sizing). Returns `.zero` before `attach`
    /// has spawned the engine. The host treats that as "no math
    /// available yet, don't render."
    var cellSize: CGSize { get }

    /// Spawn the shell described by `command` and begin rendering.
    /// Single-shot: throws `.alreadyAttached` if called twice. Throws
    /// `.surfaceCreationFailed` if the engine can't create a surface.
    func attach(command: TerminalCommand) throws

    /// Ask the engine to tear the surface down gracefully (flush, kill
    /// the child, release GPU resources). The host should expect a
    /// subsequent `terminalSurfaceDidExit` and then drop the surface.
    func requestClose()

    /// Explicit cell-grid resize. Pixel sizing follows the view's
    /// layout automatically; this is the path for the "snap to whole
    /// cells" preference, not the common case.
    func resize(cols: Int, rows: Int)

    /// Programmatically scroll the engine to row `row` (0 = top of
    /// scrollback). `SurfaceScrollView` calls this when the user
    /// drags the scroller. The engine responds by re-emitting
    /// SCROLLBAR with the new `offset`, which the host uses to
    /// re-sync the visible rect.
    func scroll(toRow row: Int)

    /// Inject `text` into the surface as if the user had typed it.
    /// The engine routes it through its normal input pipeline
    /// to the PTY. Powers the automation-only `deviceterm tab
    /// send-input` verb (the read-write side of the back-channel),
    /// and any future programmatic input surface. Throws
    /// `TerminalSurfaceError.notAttached` before `attach` has
    /// completed (rather than silently dropping the bytes) so a
    /// caller that believes they delivered input never gets
    /// false success.
    func sendInput(_ text: String) throws

    /// Capture the surface's currently-visible viewport as plain
    /// text. Powers the automation-only `deviceterm tab capture`
    /// verb. Returns the rendered cell contents (no styling, no
    /// cursor marker) with `"\n"` separating screen rows. Throws
    /// `TerminalSurfaceError.notAttached` before `attach` has
    /// completed, or `.captureFailed` when the engine refuses the
    /// read (rare; usually means the surface is mid-resize).
    /// Captures the visible viewport only; there is no scrollback
    /// or line-count option.
    func readScreenText() throws -> String

    /// Copy the current selection to the system clipboard. No-op if
    /// nothing is selected. Best-effort: implementations log on
    /// failure rather than throwing so menu items can be wired with
    /// the responder-chain `@objc` pattern (which doesn't carry
    /// exceptions). Drives the right-click "Copy" item.
    func copyToClipboard()

    /// Paste the system clipboard into the surface's input pipeline.
    /// Engine policy may surface an "unsafe paste" confirm sheet for
    /// multi-line content. Best-effort like `copyToClipboard()`.
    /// Drives the right-click "Paste" item.
    func pasteFromClipboard()

    /// Select the entire scrollback plus viewport, as the Edit menu's
    /// Select All (⌘A) does elsewhere on macOS. The selection is the
    /// engine's own, so a following `copyToClipboard()` picks it up.
    /// Best-effort like `copyToClipboard()`.
    func selectAll()

    /// Clear the visible viewport AND the scrollback history. Matches
    /// the macOS Terminal.app ⌘K and iTerm2 "Clear Buffer" convention
    /// users expect from a "Clear" menu item, and matches stock
    /// Ghostty's `clear_screen` binding, which wipes history too.
    /// Shell-side history (zsh's `$HISTFILE`, bash's `~/.bash_history`)
    /// is untouched. No-op on the alternate screen (Ghostty's binding
    /// returns false there). Best-effort. Drives the right-click
    /// "Clear" item.
    func clearScreen()

    /// Increase the font size by one step. Drives View > Zoom In
    /// (⌘=). Best-effort: implementations log on failure rather
    /// than throwing.
    func zoomIn()

    /// Decrease the font size by one step. Drives View > Zoom Out
    /// (⌘-).
    func zoomOut()

    /// Restore the font size to the config-defined baseline. Drives
    /// View > Reset Zoom (⌘0).
    func resetZoom()

    /// The kernel identity of the terminal's foreground process: its pid and
    /// controlling tty name. The host sends these to the daemon
    /// (`session.bindTerminal`) so it can derive and store a terminal anchor,
    /// which lets an in-tab CLI process authenticate as the pane's session
    /// while an out-of-tab cap thief cannot. Returns `nil` before the shell
    /// has spawned (no foreground pid yet) or when the engine can't report a
    /// tty. The host then defers binding until a later attempt succeeds.
    /// The engine owns the PTY, so it is the only component that can name the
    /// foreground process.
    func terminalIdentity() -> TerminalIdentity?
}
