// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Kernel-established identity of a connected UDS peer. All fields come from the
/// audit token and kernel process metadata (`proc_pidinfo` and
/// `sysctl(KERN_PROC_PID)`); none is client-supplied. Callers that need
/// provenance MUST fail closed when this is unavailable; never fall back to
/// trusting a capability alone.
///
/// Captured once, at accept time, from the peer's audit token
/// (`LOCAL_PEERTOKEN`) plus the process' POSIX session and controlling
/// terminal, then plumbed through the dispatch context. This type carries the
/// identity and decides nothing with it; `ProvenanceMatcher` is what matches it
/// against the session's bound terminal anchor.
///
/// Why the audit token and not `getpeereid`/`LOCAL_PEERPID`: the token carries
/// a `pidVersion` that increments when the kernel recycles a pid, so a
/// `(pid, pidVersion)` pair names one specific process instance. A later
/// process that inherits a recycled pid gets a different version and cannot
/// impersonate the original. A bare peer pid has no such guard.
public struct PeerProcessIdentity: Sendable, Equatable {
    /// Peer process id, from the audit token.
    public let pid: pid_t
    /// Audit-token pid generation. Distinguishes a process that recycled an
    /// earlier pid, so `(pid, pidVersion)` names one process instance.
    public let pidVersion: Int32
    /// Peer effective uid, from the audit token.
    public let euid: uid_t
    /// The peer's POSIX session id (`getsid`). Its numeric value is the
    /// session leader's pid.
    public let posixSessionId: pid_t
    /// The peer's controlling terminal device (`proc_bsdinfo.e_tdev`), or
    /// `NODEV` when the peer has no controlling tty (e.g. a `setsid`
    /// daemon). Captured as-is; a detached peer is rejected by the matcher,
    /// not here.
    public let controllingTTYDev: dev_t
    /// Start time of the POSIX session leader, in microseconds since the epoch
    /// (`sysctl(KERN_PROC_PID)`). Pairs with `posixSessionId` to survive SID/pid
    /// reuse: a recycled session-leader pid has a different start time. `0` means
    /// the leader's start time was unavailable (a dead leader); only a nonzero
    /// value provides the reuse guard, and a `0` here matches no real anchor.
    public let posixSessionLeaderStartTime: UInt64

    public init(
        pid: pid_t,
        pidVersion: Int32,
        euid: uid_t,
        posixSessionId: pid_t,
        controllingTTYDev: dev_t,
        posixSessionLeaderStartTime: UInt64
    ) {
        self.pid = pid
        self.pidVersion = pidVersion
        self.euid = euid
        self.posixSessionId = posixSessionId
        self.controllingTTYDev = controllingTTYDev
        self.posixSessionLeaderStartTime = posixSessionLeaderStartTime
    }
}

#if canImport(Darwin)
public extension PeerProcessIdentity {
    // From <sys/un.h>; not surfaced as Swift constants.
    private static var solLocal: Int32 { 0 }
    private static var localPeerToken: Int32 { 0x0006 }

    /// Resolve the identity of the peer on a connected UDS `fd`. Returns nil
    /// when the kernel can't vend a consistent snapshot: a non-socket fd, a
    /// `proc_pidinfo` failure, or the token's process instance no longer being
    /// live (a peer that exited / had its pid recycled around the lookups). A
    /// nil result MUST fail closed at the call site; it must never degrade to
    /// cap-only trust.
    static func resolve(fd: Int32) -> PeerProcessIdentity? {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = getsockopt(fd, solLocal, localPeerToken, &token, &len)
        guard rc == 0, len == socklen_t(MemoryLayout<audit_token_t>.size) else {
            return nil
        }
        let pid = audit_token_to_pid(token)
        let pidVersion = audit_token_to_pidversion(token)
        let euid = audit_token_to_euid(token)
        let sid = getsid(pid)
        guard sid != -1 else { return nil }
        guard let tdev = controllingTTY(of: pid) else { return nil }
        // The owner triple `(pid, pidVersion, euid)` above is leader-independent.
        // The session leader of a login-shell terminal is a root-owned
        // `/usr/bin/login`, so its start time comes from `sysctl(KERN_PROC_PID)`
        // (which works cross-uid; see `ProcInfo.leaderStartMicros`). The anchor
        // side reads the same source, so a live root leader yields a matching
        // nonzero value and the terminal arm's SID-reuse guard holds. A nil
        // result, the leader's metadata is unavailable (a dead session leader,
        // as the test runner's or a detached GUI's can be), substitutes the `0`
        // sentinel: that case is owner-arm-only, and `0` matches no real anchor
        // (a bound anchor's leader start is always nonzero), so the owner triple
        // survives instead of the whole identity collapsing to `.missing`.
        let leaderStart = ProcInfo.leaderStartMicros(sid) ?? 0
        // Bind the token back to the exact process execution. `proc_pidinfo`
        // takes only the numeric pid, so a peer that exited and had its pid
        // reused between the token capture and the reads could graft the old
        // token onto a replacement process. Re-validating the token AFTER the
        // reads closes that window: `pidVersion` is monotonic, so a reused pid
        // never re-matches the captured token: `proc_pidpath_audittoken` then
        // fails and we return nil, fail-closed. This final audit-token validation
        // prevents owner authorization after the peer exits or its pid is reused.
        guard tokenNamesLiveProcess(&token) else { return nil }
        return PeerProcessIdentity(
            pid: pid,
            pidVersion: pidVersion,
            euid: euid,
            posixSessionId: sid,
            controllingTTYDev: tdev,
            posixSessionLeaderStartTime: leaderStart
        )
    }

    /// Whether the audit token still names a live process of its exact
    /// `(pid, pidVersion)` generation. `proc_pidpath_audittoken` looks up by
    /// the token's generation, not the bare pid, so it returns 0 once the
    /// process has exited or the pid was recycled; the fail-closed signal.
    private static func tokenNamesLiveProcess(_ token: inout audit_token_t) -> Bool {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN), not surfaced as a Swift
        // constant. We only care whether the call succeeds, not the path.
        var buffer = [CChar](repeating: 0, count: 4_096)
        return proc_pidpath_audittoken(&token, &buffer, UInt32(buffer.count)) > 0
    }

    /// The controlling terminal device, or `NODEV` for a process with no
    /// controlling tty. A `proc_pidinfo` failure (the process exited) is nil.
    private static func controllingTTY(of pid: pid_t) -> dev_t? {
        guard let info = ProcInfo.bsdInfo(of: pid) else { return nil }
        return dev_t(bitPattern: info.e_tdev)
    }
}
#endif

/// Injectable resolver seam. Production wires `defaultPeerIdentityResolver`
/// (the real `getsockopt(LOCAL_PEERTOKEN)` path); tests inject synthetic
/// identities so the provenance matrix stays hermetic without real sockets.
public typealias PeerIdentityResolver = @Sendable (Int32) -> PeerProcessIdentity?

#if canImport(Darwin)
public let defaultPeerIdentityResolver: PeerIdentityResolver = {
    PeerProcessIdentity.resolve(fd: $0)
}
#else
public let defaultPeerIdentityResolver: PeerIdentityResolver = { _ in nil }
#endif
