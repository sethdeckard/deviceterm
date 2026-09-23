// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin

/// Which process in a bound terminal is its shell.
///
/// **The session leader is not the shell.** For a login-shell terminal the
/// POSIX session leader is a root-owned `/usr/bin/login` and the shell is its
/// child, so `getsid(pid) == pid` is false for the shell and comparing a
/// foreground pid against the session id answers "a program is running" even
/// when the terminal is sitting idle at its prompt. Anything deciding whether
/// a terminal is busy has to ask this instead of assuming.
///
/// The rule is the one `TerminalWorkingDirectory` already relies on: the
/// leader itself when it is same-euid and on this tty (a terminal spawned
/// without `login`), otherwise its single same-euid child on the same tty.
/// Ambiguity answers nil rather than guessing, because every caller would
/// rather not know than be told the wrong process.
public enum TerminalShellIdentity {
    /// The terminal's shell, or nil when it cannot be identified
    /// unambiguously.
    public static func pid(for facts: TerminalAnchorFacts) -> pid_t? {
        resolve(
            leader: facts.terminalSessionId,
            tty: facts.controllingTTYDevice,
            readerEUID: geteuid()
        )
    }

    /// What the terminal is running: its own shell, some program, or an
    /// answer the kernel will not give.
    ///
    /// `unknown` is distinct from `idle` on purpose. A foreground process
    /// this process cannot read, a `sudo` running as root being the common
    /// case, makes the terminal's state unestablished rather than free.
    public static func foregroundState(
        foregroundPid: pid_t,
        ttyName: String
    ) -> TerminalForegroundState {
        guard let facts = DefaultTerminalProbe.derive(
            foregroundPid: foregroundPid,
            ttyName: ttyName
        ) else { return .unknown }
        return state(foregroundPid: foregroundPid, shell: pid(for: facts))
    }

    /// The decision itself, separated from reading the process tree so the
    /// three-way outcome is testable without one.
    static func state(foregroundPid: pid_t, shell: pid_t?) -> TerminalForegroundState {
        guard let shell else { return .unknown }
        return foregroundPid == shell ? .idle : .running(foregroundPid)
    }

    /// `snapshot` and `children` are injected so the login-shaped tree this
    /// rule exists for can be exercised without one.
    static func resolve(
        leader: pid_t,
        tty: dev_t,
        readerEUID: uid_t,
        snapshot: (pid_t) -> ProcInfo.Snapshot? = { ProcInfo.snapshot(of: $0) },
        children: (pid_t) -> [pid_t] = { ProcInfo.childPids(of: $0) }
    ) -> pid_t? {
        // A terminal spawned without `login` leads its own session, so the
        // leader is the shell. A login-shell terminal's leader is root-owned
        // and fails this, which is what sends the rule to the children.
        if let leaderInfo = snapshot(leader),
            leaderInfo.euid == readerEUID,
            leaderInfo.controllingTTYDev == tty {
            return leader
        }
        return TerminalWorkingDirectory.selectShell(
            among: children(leader).compactMap(snapshot),
            leader: leader,
            tty: tty,
            readerEUID: readerEUID
        )
    }
}
#endif
