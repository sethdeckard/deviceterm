// SPDX-License-Identifier: GPL-3.0-or-later

@_spi(ProvenanceTesting)
import Daemon
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Deterministic peer/terminal identity for the RPC test harnesses.
///
/// The production provenance gate authorizes a UDS `session.authenticate` only
/// when the peer's kernel identity matches the session's owner or its bound
/// terminal anchor. Neither is available in-process over a loopback socket:
/// the real `LOCAL_PEERTOKEN` resolve is leader-liveness-dependent (the test
/// runner's session leader can be dead late in a run) and the test sessions
/// carry no captured owner. So the harness injects a synthetic peer resolver
/// AND an anchor lookup whose facts match it. Every session authenticated
/// over the harness passes the **terminal arm** with no per-session seeding.
///
/// XPC harnesses instead use `owner` (the loopback process' real owner triple),
/// because XPC has no terminal arm; a non-validated XPC peer authorizes only
/// as the exact owner. `resolveSelf` reads the current process' owner triple,
/// which matches the audit token of an in-process anonymous XPC peer.
public enum TestPeerIdentity {
    /// Arbitrary terminal facts the resolver and anchor agree on.
    public static let sessionId: pid_t = 4_242
    public static let ttyDevice: dev_t = 42
    public static let leaderStart: UInt64 = 1

    /// The synthetic UDS peer identity every harness connection resolves to.
    /// Its owner triple is the current process (so an owner-arm test can match
    /// it too), and its terminal facts match `anchor(for:)`.
    public static let stub: PeerProcessIdentity = {
        let owner = OwnerProcessIdentity.resolveSelf()
        return PeerProcessIdentity(
            pid: owner?.pid ?? getpid(),
            pidVersion: owner?.pidVersion ?? 0,
            euid: owner?.euid ?? geteuid(),
            posixSessionId: sessionId,
            controllingTTYDev: ttyDevice,
            posixSessionLeaderStartTime: leaderStart
        )
    }()

    /// The current process' owner identity, for XPC owner-arm tests.
    public static let owner = OwnerProcessIdentity(stub)

    /// Peer resolver the harness injects into `RPCServer`: every accepted
    /// connection resolves to `stub` regardless of the real fd.
    public static let udsResolver: @Sendable (Int32) -> PeerProcessIdentity? = { _ in stub }

    /// Anchor lookup the harness injects into `RPCServer`: every session id
    /// maps to an anchor whose facts match `stub`, so the terminal arm
    /// authorizes any authenticated session without owner seeding.
    public static func anchor(for sessionId: UUID) -> TerminalAnchor {
        TerminalAnchor(
            sessionId: sessionId,
            facts: TerminalAnchorFacts(
                terminalSessionId: Self.sessionId,
                sessionLeaderStartTime: leaderStart,
                controllingTTYDevice: ttyDevice
            ),
            issuingGUIConnectionId: 1
        )
    }

    /// Provenance lookup for XPC harnesses. XPC has no terminal arm, so it
    /// carries the session's OWNER (this process' owner triple, matching the
    /// in-process anonymous XPC peer's audit token); a non-validated XPC
    /// session-auth then passes the owner arm, and a validated-GUI one passes
    /// regardless. A closed session resolves to nil (the per-request re-check
    /// then fails). Provenance is mandatory whenever a validator is configured
    /// (fail-closed), so every XPC harness that authenticates must pass this.
    public static func xpcProvenanceLookup(
        _ manager: SessionManager
    ) -> @Sendable (UUID) async -> SessionProvenanceSnapshot? {
        { sessionId in
            guard await manager.session(id: sessionId) != nil else { return nil }
            return SessionProvenanceSnapshot(owner: Self.owner, anchor: nil)
        }
    }

    /// A `ProvenanceContext` for XPC harnesses: the manager's store (structural)
    /// + the synthetic owner-arm lookup override.
    public static func xpcProvenance(_ manager: SessionManager) -> ProvenanceContext {
        ProvenanceContext(sessionManager: manager, lookupOverride: xpcProvenanceLookup(manager))
    }

    /// A `ProvenanceContext` for UDS harnesses: the manager's store + a lookup
    /// override whose anchor facts match `stub`, so the terminal arm authorizes
    /// any live session (nil for a closed one, so the per-request re-check fails
    /// after close).
    public static func udsProvenance(_ manager: SessionManager) -> ProvenanceContext {
        ProvenanceContext(
            sessionManager: manager,
            lookupOverride: { sessionId in
                guard await manager.session(id: sessionId) != nil else { return nil }
                return SessionProvenanceSnapshot(owner: nil, anchor: anchor(for: sessionId))
            }
        )
    }
}
