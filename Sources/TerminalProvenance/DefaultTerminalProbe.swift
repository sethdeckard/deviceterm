// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin

/// Derives trusted terminal facts from a foreground pid
/// and a tty name supplied by a trusted terminal surface.
///
/// Neither input is authority on its own: the probe re-derives the terminal
/// identity from the kernel and returns only verified facts.
///
/// Pid exit/reuse is guarded by reading the foreground process' identity before
/// AND after the session/TTY lookups: if its start time or controlling tty
/// changed in between, the pid was reused or the process exited and the probe
/// fails closed rather than binding a mismatched anchor.
public enum DefaultTerminalProbe {
    /// Derive the anchor facts, or nil (fail-closed) when the kernel view is
    /// inconsistent: the tty isn't a character device, the foreground
    /// process' controlling tty doesn't match the claimed tty, the session
    /// leader isn't live, or the foreground process changed identity across
    /// the lookups (pid exit/reuse).
    public static func derive(foregroundPid: pid_t, ttyName: String) -> TerminalAnchorFacts? {
        // The tty name must resolve to a character device.
        var ttyStat = stat()
        guard stat(ttyName, &ttyStat) == 0 else { return nil }
        guard (ttyStat.st_mode & S_IFMT) == S_IFCHR else { return nil }
        let ttyDevice = ttyStat.st_rdev

        // Snapshot the foreground process BEFORE the session/leader lookups.
        guard let before = ProcInfo.bsdInfo(of: foregroundPid) else { return nil }
        // Its controlling tty must be the tty the GUI named.
        guard dev_t(bitPattern: before.e_tdev) == ttyDevice else { return nil }

        let sid = getsid(foregroundPid)
        guard sid != -1 else { return nil }
        // The POSIX session leader of a login-shell terminal is a ROOT-owned
        // `/usr/bin/login`, which `proc_pidinfo` refuses to read across the uid
        // boundary. Read the leader's start time via `sysctl(KERN_PROC_PID)`,
        // which does not have that restriction (`ProcInfo.leaderStartMicros`),
        // so the anchor keeps a real, nonzero leader start time and its SID-reuse
        // guard stays intact. A nil result (no usable leader record was returned)
        // fails the bind closed rather than storing an anchor with unavailable
        // leader metadata.
        guard let leaderStart = ProcInfo.leaderStartMicros(sid) else { return nil }

        // Snapshot AFTER: if the foreground process' start time or controlling
        // tty changed, its pid was reused (or it exited) mid-probe: fail
        // closed rather than binding a mismatched anchor.
        guard let after = ProcInfo.bsdInfo(of: foregroundPid) else { return nil }
        guard ProcInfo.startMicros(before) == ProcInfo.startMicros(after) else { return nil }
        guard before.e_tdev == after.e_tdev else { return nil }

        return TerminalAnchorFacts(
            terminalSessionId: sid,
            sessionLeaderStartTime: leaderStart,
            controllingTTYDevice: ttyDevice
        )
    }
}
#endif
