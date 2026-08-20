// SPDX-License-Identifier: GPL-3.0-or-later
//
// ProcInfo: shared process-metadata wrappers over `proc_pidinfo(PROC_PIDTBSDINFO)`
// and `sysctl(KERN_PROC_PID)`.
//
// The UDS peer resolver, the terminal-anchor probe, and the ancestry walk all
// need the same facts about a process: its controlling-terminal device, its
// start time, and (for the walk) its parent and effective uid. The kernel calls
// and struct handling live here once so none of them duplicates it.
// `proc_pidinfo` serves same-uid reads; `sysctl(KERN_PROC_PID)` reads across
// the uid boundary, which both the root-owned `/usr/bin/login` session leader
// and an arbitrary ancestor require.

import Foundation
#if canImport(Darwin)
import Darwin

enum ProcInfo {
    /// One process' kernel metadata, read in a single `sysctl(KERN_PROC_PID)`.
    ///
    /// This `KERN_PROC` path can read across uid boundaries, unlike
    /// `bsdInfo(of:)`: it reports any process to any user (it is what `ps`
    /// reads), while `proc_pidinfo` refuses a cross-uid read.
    struct Snapshot: Sendable, Equatable {
        let pid: pid_t
        /// Parent pid. `1` once the real parent has exited, because the kernel
        /// reparents orphans to launchd.
        let ppid: pid_t
        let euid: uid_t
        /// Start time in microseconds since the epoch. Paired with a pid this
        /// is the process-execution identity: a recycled pid starts later.
        let startMicros: UInt64
        /// Controlling terminal device, or `NODEV` for a process with none.
        let controllingTTYDev: dev_t
    }

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

    /// Kernel metadata for `pid`, or nil when `sysctl` fails or answers with a
    /// record that doesn't name `pid` (the caller's fail-closed signal).
    static func snapshot(of pid: pid_t) -> Snapshot? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        // A non-existent pid yields rc == 0 with an empty record; confirm the
        // record actually names `pid` before trusting any of its fields.
        guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Snapshot(
            pid: pid,
            ppid: info.kp_eproc.e_ppid,
            euid: info.kp_eproc.e_ucred.cr_uid,
            startMicros: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec),
            controllingTTYDev: info.kp_eproc.e_tdev
        )
    }

    /// The start time of `pid` in microseconds since the epoch, read via
    /// `sysctl(KERN_PROC_PID)` instead of `proc_pidinfo`. This matters for the
    /// POSIX session leader of a login-shell terminal, which is a ROOT-owned
    /// `/usr/bin/login`: `proc_pidinfo(PROC_PIDTBSDINFO)` refuses a cross-uid
    /// read and returns nothing. Reading the leader's real start time keeps the
    /// session-leader-reuse guard intact on the terminal arm rather than
    /// degrading to a weaker sid+tty match.
    ///
    /// Returns nil when the snapshot is unavailable or yields a non-positive
    /// start time. A real process start is always a large positive
    /// epoch-microsecond value, so callers may treat a returned value as
    /// strictly positive: a bound anchor therefore never carries `0`, and the
    /// `0` a caller substitutes for a nil result is a distinct "leader metadata
    /// unavailable" sentinel that can never equal a real anchor's leader start.
    static func leaderStartMicros(_ pid: pid_t) -> UInt64? {
        guard let snapshot = snapshot(of: pid) else { return nil }
        // Treat a non-positive start as unavailable so `0` is unambiguously the
        // "no usable leader record" sentinel, never a matchable anchor value.
        return snapshot.startMicros > 0 ? snapshot.startMicros : nil
    }
}
#endif
