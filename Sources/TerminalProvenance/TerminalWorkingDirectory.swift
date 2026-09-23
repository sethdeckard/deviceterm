// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin

/// Resolves the working directory of what a bound terminal is running.
///
/// Reporting only. No authorization path consults this. A missing result omits
/// `cwd`; an incorrect result can only misreport that field, never widen
/// authority. It is also not a new reach: the same-euid constraint below means
/// it reads nothing a same-uid process could not already see through `ps` or
/// `lsof`.
///
/// The anchor names the POSIX session leader, and reading that process directly
/// is the obvious approach that does not work. For a login-shell terminal the
/// leader is a root-owned `/usr/bin/login`, whose directory is refused across
/// the uid boundary and would be the wrong answer even if it were readable.
///
/// What answers instead is the terminal's foreground process group leader, with
/// the session's own shell as the fallback. Reading only that shell is wrong
/// whenever the terminal is running something that keeps its own directory: a
/// nested interactive shell is the common case, and a `cd` there never reaches
/// the outer shell, so the reported directory would silently go stale. The
/// foreground process is what the terminal is actually running, which is what a
/// reader means by "where is this terminal".
///
/// The cost of that choice is that a foreground command which changes its own
/// directory reports its directory rather than the shell's, for as long as it
/// runs. That is the honest answer to the same question, and the alternative
/// staleness is unbounded rather than temporary.
///
/// Pid exit and reuse are guarded the way `DefaultTerminalProbe.derive` guards
/// them, before AND after the read. Without the second pass a terminal can die
/// and a new session recycle the session id mid-resolution, and the result would
/// name a directory belonging to somebody else.
public enum TerminalWorkingDirectory {
    /// The terminal's working directory, or nil whenever it cannot be
    /// established.
    ///
    /// Nil is a correct and expected answer rather than a failure: the field is
    /// optional on every wire type that carries it, so omitting it always beats
    /// reporting a directory that might not be the session's.
    public static func resolve(for facts: TerminalAnchorFacts) -> String? {
        let leader = facts.terminalSessionId
        guard ProcInfo.leaderStartMicros(leader) == facts.sessionLeaderStartTime else {
            return nil
        }
        guard let target = targetPid(leader: leader, tty: facts.controllingTTYDevice),
            let before = ProcInfo.snapshot(of: target),
            let path = ProcInfo.currentDirectoryPath(of: target)
        else { return nil }
        guard let after = ProcInfo.snapshot(of: target),
            isSameProcessInstance(before, after),
            ProcInfo.leaderStartMicros(leader) == facts.sessionLeaderStartTime
        else { return nil }
        return path
    }

    /// Whether two snapshots describe one process that never went away.
    ///
    /// `foregroundProcessGroup` is volatile, so it is deliberately excluded
    /// from the process-identity comparison.
    static func isSameProcessInstance(
        _ before: ProcInfo.Snapshot,
        _ after: ProcInfo.Snapshot
    ) -> Bool {
        before.pid == after.pid
            && before.ppid == after.ppid
            && before.euid == after.euid
            && before.startMicros == after.startMicros
            && before.controllingTTYDev == after.controllingTTYDev
    }

    /// The unambiguous shell candidate among the session leader's children.
    static func selectShell(
        among candidates: [ProcInfo.Snapshot],
        leader: pid_t,
        tty: dev_t,
        readerEUID: uid_t
    ) -> pid_t? {
        let matches = candidates.filter {
            $0.ppid == leader && $0.euid == readerEUID && $0.controllingTTYDev == tty
        }
        guard matches.count == 1 else { return nil }
        return matches.first?.pid
    }

    private static func targetPid(leader: pid_t, tty: dev_t) -> pid_t? {
        let readerEUID = geteuid()
        if let foreground = foregroundPid(leader: leader, tty: tty, readerEUID: readerEUID) {
            return foreground
        }
        return shellPid(leader: leader, tty: tty, readerEUID: readerEUID)
    }

    private static func foregroundPid(leader: pid_t, tty: dev_t, readerEUID: uid_t) -> pid_t? {
        guard let leaderInfo = ProcInfo.snapshot(of: leader),
            leaderInfo.controllingTTYDev == tty
        else { return nil }
        let group = leaderInfo.foregroundProcessGroup
        guard group > 0,
            let groupInfo = ProcInfo.snapshot(of: group),
            groupInfo.euid == readerEUID,
            groupInfo.controllingTTYDev == tty
        else { return nil }
        return group
    }

    private static func shellPid(leader: pid_t, tty: dev_t, readerEUID: uid_t) -> pid_t? {
        TerminalShellIdentity.resolve(leader: leader, tty: tty, readerEUID: readerEUID)
    }
}
#endif
