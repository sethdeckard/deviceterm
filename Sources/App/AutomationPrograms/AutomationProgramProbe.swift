// SPDX-License-Identifier: GPL-3.0-or-later

import TerminalProvenance

/// Answers what a configured program's terminal is doing.
///
/// There is no process-exit event to listen for. The command is typed into
/// the tab's shell, so the shell outlives the program and the surface's own
/// child-exited signal reports the shell, not the program. What the terminal
/// does expose is its PTY's foreground process, which is the shell whenever
/// the shell sits at its prompt and the running program the rest of the time.
///
/// **Identifying the shell is not `getsid`.** For a login-shell terminal the
/// session leader is a root-owned `/usr/bin/login` and the shell is its
/// child, so comparing the foreground pid against the session id calls an
/// idle terminal busy and no exit is ever seen. `TerminalShellIdentity` owns
/// the real rule and this defers to it.
///
/// **`unknown` is not `idle`.** A foreground process deviceterm cannot read,
/// a `sudo` running as root being the ordinary case, leaves the terminal's
/// state unestablished. Supervision may not type into it, and may not count
/// it as an exit either.
///
/// Both halves are injected so supervision is testable without a terminal.
struct AutomationProgramProbe {
    /// The tab's terminal identity: the PTY's foreground process and the
    /// controlling tty it was read from. Nil when the tab has no live
    /// terminal to ask, which is itself an unestablished state.
    var terminalIdentity: @MainActor (TabID) -> (foregroundPid: Int32, ttyName: String)?

    /// What that terminal is running.
    var foregroundState: @Sendable (Int32, String) -> TerminalForegroundState = { pid, tty in
        TerminalShellIdentity.foregroundState(foregroundPid: pid, ttyName: tty)
    }

    /// What `tab`'s terminal is doing.
    ///
    /// A program that daemonizes itself, or calls `setsid`, leaves the
    /// terminal's foreground and reads as idle, so supervision will re-run
    /// it. Detaching does not by itself cost it authority: provenance
    /// follows the live parent chain and keeps authorizing a detached
    /// descendant while that chain still reaches the bound terminal. Staying
    /// in the foreground is a requirement of supervision, not of trust.
    @MainActor
    func state(ofTab tab: TabID) -> TerminalForegroundState {
        guard let identity = terminalIdentity(tab) else { return .unknown }
        return foregroundState(identity.foregroundPid, identity.ttyName)
    }
}
