// SPDX-License-Identifier: GPL-3.0-or-later
//
// ProcInfo: shared process-metadata wrappers over `proc_pidinfo(PROC_PIDTBSDINFO)`
// and `sysctl(KERN_PROC_PID)`.
//
// Both the UDS peer resolver and the terminal-anchor probe need the same facts
// about a process: its controlling-terminal device and its start time. The
// kernel calls and struct handling live here once so neither duplicates them.
// `proc_pidinfo` serves same-uid reads; `sysctl(KERN_PROC_PID)` reads a start
// time across the uid boundary (the terminal session leader is a root-owned
// `/usr/bin/login`).

import Foundation
#if canImport(Darwin)
import Darwin

enum ProcInfo {
    /// The BSD info block for `pid`, or nil when the process has exited (or is
    /// otherwise unreadable): the caller's fail-closed signal.
    static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard rc == size else { return nil }
        return info
    }

    /// The process' start time in microseconds since the epoch. Paired with a
    /// pid or session id, this is the process-execution identity: a recycled
    /// pid has a different start time.
    static func startMicros(_ info: proc_bsdinfo) -> UInt64 {
        UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    /// The start time of `pid` in microseconds since the epoch, read via
    /// `sysctl(KERN_PROC_PID)` instead of `proc_pidinfo`. This matters for the
    /// POSIX session leader of a login-shell terminal, which is a ROOT-owned
    /// `/usr/bin/login`: `proc_pidinfo(PROC_PIDTBSDINFO)` refuses a cross-uid
    /// read and returns nothing, but `KERN_PROC` returns any process' start
    /// time to any user (it is what `ps` reads to list every process). Reading
    /// the leader's real start time keeps the session-leader-reuse guard intact
    /// on the terminal arm rather than degrading to a weaker sid+tty match.
    ///
    /// Returns nil when `sysctl` fails, returns no record, returns a record for
    /// a different pid, or yields a non-positive start time. A real process
    /// start is always a large positive epoch-microsecond value, so callers may
    /// treat a returned value as strictly positive: a bound anchor therefore
    /// never carries `0`, and the `0` a caller substitutes for a nil result is a
    /// distinct "leader metadata unavailable" sentinel that can never equal a
    /// real anchor's leader start.
    static func leaderStartMicros(_ pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        // A non-existent pid yields rc == 0 with an empty record; confirm the
        // record actually names `pid` before trusting the start time.
        guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let micros = UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
        // Treat a non-positive start as unavailable so `0` is unambiguously the
        // "no usable leader record" sentinel, never a matchable anchor value.
        return micros > 0 ? micros : nil
    }
}
#endif
