// SPDX-License-Identifier: GPL-3.0-or-later
//
// TerminalProbe: derives a trusted terminal anchor from a foreground pid and
// a tty name supplied by the validated GUI over `session.bindTerminal`.
//
// The GUI reads its terminal surface's foreground process pid and tty name
// from libghostty and asks the daemon to bind them to a session. Neither value
// is authority on its own: the daemon re-derives the anchor from the kernel and
// keeps only kernel-verified facts. The numeric foreground pid is NEVER
// retained: the anchor is the POSIX session id, the controlling TTY device,
// and the session leader's start time, which together are the stable kernel
// boundary a UDS peer is later matched against.
//
// Pid exit/reuse is guarded by reading the foreground process' identity before
// AND after the session/TTY lookups: if its start time or controlling tty
// changed in between, the pid was reused or the process exited and the probe
// fails closed rather than binding a mismatched anchor.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Kernel-verified facts describing a terminal, derived by the probe and
/// stored (with the session id and issuing connection) as a `TerminalAnchor`.
/// These are the exact fields a UDS peer's `PeerProcessIdentity` is matched
/// against.
public struct TerminalAnchorFacts: Sendable, Equatable {
    /// The terminal's POSIX session id (`getsid(foregroundPid)`).
    public let terminalSessionId: pid_t
    /// The session leader's start time, microseconds since the epoch. Guards
    /// against SID/pid reuse: a recycled session-leader pid has a different
    /// start time.
    public let sessionLeaderStartTime: UInt64
    /// The controlling terminal device (`stat(ttyName).st_rdev`), cross-checked
    /// against the foreground process' `e_tdev`.
    public let controllingTTYDevice: dev_t

    public init(
        terminalSessionId: pid_t,
        sessionLeaderStartTime: UInt64,
        controllingTTYDevice: dev_t
    ) {
        self.terminalSessionId = terminalSessionId
        self.sessionLeaderStartTime = sessionLeaderStartTime
        self.controllingTTYDevice = controllingTTYDevice
    }
}

/// Injectable probe seam. Production wires `defaultTerminalProbe` (the real
/// syscall path); tests inject synthetic facts so anchor binding can be
/// exercised without real terminals.
public typealias TerminalProbe = @Sendable (_ foregroundPid: pid_t, _ ttyName: String)
    -> TerminalAnchorFacts?

#if canImport(Darwin)
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

public let defaultTerminalProbe: TerminalProbe = {
    DefaultTerminalProbe.derive(foregroundPid: $0, ttyName: $1)
}
#else
public let defaultTerminalProbe: TerminalProbe = { _, _ in nil }
#endif
