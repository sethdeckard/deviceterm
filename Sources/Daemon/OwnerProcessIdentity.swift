// SPDX-License-Identifier: GPL-3.0-or-later
//
// OwnerProcessIdentity: the kernel identity of the process that created a
// session, and the identity a peer is matched against on the "exact owner"
// provenance arm.
//
// Captured server-side from the transport peer at session.create (never from a
// caller-supplied pid): the audit token on XPC, the LOCAL_PEERTOKEN identity on
// UDS. Matched on (pid, pidVersion, euid) only: a session owner's POSIX
// session and controlling tty are irrelevant to *owner* identity (that is the
// separate terminal-anchor arm), so they are deliberately excluded here.
//
// The exact-owner arm is what lets the process that minted a session (the GUI,
// including its UDS smoke fallback) authenticate as that session without a
// terminal anchor.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct OwnerProcessIdentity: Sendable, Equatable {
    public let pid: pid_t
    public let pidVersion: Int32
    public let euid: uid_t

    public init(pid: pid_t, pidVersion: Int32, euid: uid_t) {
        self.pid = pid
        self.pidVersion = pidVersion
        self.euid = euid
    }

    /// The owner subset of a UDS peer's kernel identity.
    public init(_ peer: PeerProcessIdentity) {
        self.pid = peer.pid
        self.pidVersion = peer.pidVersion
        self.euid = peer.euid
    }

    #if canImport(Darwin)
    /// Derive the owner identity from an XPC peer's audit token. Same
    /// `(pid, pidVersion, euid)` the UDS resolver reads, via the documented
    /// libbsm accessors.
    public init(auditToken token: audit_token_t) {
        self.pid = audit_token_to_pid(token)
        self.pidVersion = audit_token_to_pidversion(token)
        self.euid = audit_token_to_euid(token)
    }
    #endif

    /// The owner identity of whoever established `context`'s connection:
    /// the XPC peer's audit token, or the UDS peer's `LOCAL_PEERTOKEN`
    /// identity. `nil` when the transport vended no identity (a UDS peer the
    /// kernel couldn't name, or an XPC peer with no captured token), in which
    /// case the session records no owner and the owner provenance arm never
    /// matches. Captured at `session.create`, never from a wire field.
    public static func from(_ context: DispatchPeerContext) -> OwnerProcessIdentity? {
        switch context.transport {
        case .xpc:
            #if canImport(Darwin)
            return context.auditToken.map(OwnerProcessIdentity.init(auditToken:))
            #else
            return nil
            #endif

        case .uds:
            return context.peerProcess.map(OwnerProcessIdentity.init)
        }
    }

    #if canImport(Darwin)
    /// Resolve THIS process's owner identity via a connected socketpair and
    /// `LOCAL_PEERTOKEN`. Unlike `PeerProcessIdentity.resolve`, it reads only
    /// the owner triple `(pid, pidVersion, euid)` and does NOT require a live
    /// POSIX session leader: owner identity is leader-independent, so this is
    /// reliable even when the caller's session leader has exited (which the
    /// test runner's can). Returns `nil` only if the kernel can't vend the
    /// token. Intended for test harnesses that seed a session's owner to the
    /// loopback peer they later authenticate as.
    public static func resolveSelf() -> OwnerProcessIdentity? {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        defer {
            close(pair[0])
            close(pair[1])
        }
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        // SOL_LOCAL = 0, LOCAL_PEERTOKEN = 0x0006 (<sys/un.h>).
        guard getsockopt(pair[0], 0, 0x0006, &token, &len) == 0 else { return nil }
        return OwnerProcessIdentity(auditToken: token)
    }
    #endif
}
