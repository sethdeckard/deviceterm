// SPDX-License-Identifier: GPL-3.0-or-later

/// Live per-terminal values the AppKit controller tree owns, read in one hop
/// for one projection pass.
///
/// These arrive together because they share a source: `tty` and `cwd` both
/// come from a single `terminalIdentity()` read, and splitting them would pay
/// for that read twice per terminal on a path the collection projections
/// already run once per pane. The two OSC fields are retained state on the
/// terminal's view controller and cost nothing.
///
/// The two directory fields are different facts and are deliberately not
/// merged. `oscWorkingDirectory` is what the shell announced via OSC 7: label
/// input, published ungated, and already what a tab's own title falls back to.
/// `cwd` is a fresh kernel read of the terminal's own processes, gated on a
/// caller's automation grant, and absent whenever the caller lacks one.
struct TerminalPaneFacts: Equatable, Sendable {
    /// Latest OSC 0/2 title the program in this terminal set. Nil when it has
    /// set none. Survives surface detachment, because it is retained rather
    /// than re-read.
    let oscTitle: String?
    /// Latest OSC 7 directory the shell announced, full path. Nil when it has
    /// announced none.
    let oscWorkingDirectory: String?
    /// Controlling tty device path, e.g. `/dev/ttys003`. Nil before the shell
    /// has spawned and after the surface detaches: transient, not unsupported.
    let tty: String?
    /// Kernel-derived working directory, read afresh on every projection. The
    /// foreground process group when it is usable, otherwise the session leader
    /// or its one same-user child on the terminal.
    ///
    /// Nil when the projection does not request it, when the caller lacks
    /// authority to read it, when identity cannot be verified, or when no
    /// unambiguous candidate resolves.
    let cwd: String?
    /// The PTY's foreground process id, from the same `terminalIdentity()`
    /// read as `tty`. Lets supervision compare the foreground process with
    /// the terminal's own shell; it identifies neither the shell nor any
    /// particular program. Nil before the shell has spawned and after the
    /// surface detaches.
    let foregroundPid: Int32?
}
