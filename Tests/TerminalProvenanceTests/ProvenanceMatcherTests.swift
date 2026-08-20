// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import TerminalProvenance
import Testing
#if canImport(Darwin)
import Darwin
#endif

// ProvenanceMatcher: the pure authority decision. Driven with synthetic
// identities/anchors so every arm and outcome is covered hermetically. This is
// most of the provenance matrix; the wired auth path adds the cap + live-
// session gates around it.

private func peer(
    pid: pid_t = 100,
    ver: Int32 = 1,
    euid: uid_t = 501,
    sid: pid_t = 200,
    tty: dev_t = 5,
    leader: UInt64 = 9
) -> PeerProcessIdentity {
    PeerProcessIdentity(
        pid: pid,
        pidVersion: ver,
        euid: euid,
        posixSessionId: sid,
        controllingTTYDev: tty,
        posixSessionLeaderStartTime: leader
    )
}

/// A caller that detached from its terminal: its own POSIX session, no
/// controlling tty. This is the shape an agent harness produces when it runs
/// each command under `setsid`, and it matches no anchor on its own facts.
private func detachedPeer(pid: pid_t = 300) -> PeerProcessIdentity {
    peer(pid: pid, sid: pid, tty: dev_t(-1), leader: 77)
}

/// One entry on a caller's verified parent chain. The defaults match `anchor()`,
/// so a bare `ancestor()` is an anchored one.
private func ancestor(
    pid: pid_t = 400,
    euid: uid_t = 501,
    start: UInt64 = 1_000,
    sid: pid_t = 200,
    tty: dev_t = 5,
    leader: UInt64 = 9
) -> AncestorProcessIdentity {
    AncestorProcessIdentity(
        pid: pid,
        euid: euid,
        startMicros: start,
        posixSessionId: sid,
        controllingTTYDev: tty,
        posixSessionLeaderStartTime: leader
    )
}

private func owner(pid: pid_t = 100, ver: Int32 = 1, euid: uid_t = 501) -> OwnerProcessIdentity {
    OwnerProcessIdentity(pid: pid, pidVersion: ver, euid: euid)
}

private func anchor(sid: pid_t = 200, tty: dev_t = 5, leader: UInt64 = 9) -> TerminalAnchorFacts {
    TerminalAnchorFacts(
        terminalSessionId: sid,
        sessionLeaderStartTime: leader,
        controllingTTYDevice: tty
    )
}

// MARK: - GUI + owner arms

@Test
func validatedGUIIsAuthorized() {
    // The signature-validated GUI is trusted for provenance regardless of the
    // owner identity or whether an anchor exists.
    #expect(
        ProvenanceMatcher.verdict(peer: .validatedGUI(owner: owner()), sessionOwner: nil, anchor: nil)
            == .authorized
    )
}

@Test
func exactOwnerOverUDSIsAuthorizedWithoutAnchor() {
    // The GUI's UDS smoke fallback: the peer IS the process that created the
    // session, so it authenticates with no terminal anchor.
    #expect(
        ProvenanceMatcher.verdict(peer: .uds(peer(), ancestors: []), sessionOwner: owner(), anchor: nil)
            == .authorized
    )
}

@Test
func exactOwnerOverXPCIsAuthorized() {
    #expect(
        ProvenanceMatcher.verdict(peer: .xpc(owner: owner()), sessionOwner: owner(), anchor: nil)
            == .authorized
    )
}

@Test
func xpcNonOwnerIsUnauthorizedEvenWithMatchingTerminalAnchor() {
    // XPC has no terminal arm: a non-owner XPC peer is rejected even if an
    // anchor exists that a UDS peer would match.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .xpc(owner: owner(pid: 999)), sessionOwner: owner(), anchor: anchor()
        ) == .unauthorized
    )
}

@Test
func ownerMismatchOnPidVersionFallsThroughToTerminalArm() {
    // A recycled pid (same pid/euid, different version) is NOT the owner, so
    // the terminal arm decides: matching anchor authorizes.
    let recycled = owner(ver: 2)
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(ver: 1), ancestors: []), sessionOwner: recycled, anchor: anchor()
        ) == .authorized
    )
}

@Test
func ownerArmAuthorizesWhenTheWalkFoundNoAncestors() {
    // A failed or empty walk denies only the ancestry arm. The owner arm is
    // evaluated first and is unaffected, which is what keeps the GUI's UDS
    // fallback working from a process whose chain can't be read at all.
    #expect(
        ProvenanceMatcher.verdict(peer: .uds(peer(), ancestors: []), sessionOwner: owner(), anchor: anchor())
            == .authorized
    )
}

// MARK: - Terminal arm

@Test
func udsTerminalMatchIsAuthorized() {
    // A non-owner UDS peer whose session/tty/leader-start match the anchor.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300), ancestors: []), sessionOwner: owner(), anchor: anchor()
        ) == .authorized
    )
}

@Test
func udsSameTTYWrongSessionIsUnauthorized() {
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300, sid: 999, tty: 5), ancestors: []),
            sessionOwner: owner(),
            anchor: anchor(sid: 200, tty: 5)
        ) == .unauthorized
    )
}

@Test
func udsSameSessionWrongTTYIsUnauthorized() {
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300, sid: 200, tty: 7), ancestors: []),
            sessionOwner: owner(),
            anchor: anchor(sid: 200, tty: 5)
        ) == .unauthorized
    )
}

@Test
func udsWrongLeaderStartIsUnauthorized() {
    // SID/pid reuse: same session id and tty but a different session-leader
    // start identity → rejected.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300, leader: 111), ancestors: []),
            sessionOwner: owner(),
            anchor: anchor(leader: 9)
        ) == .unauthorized
    )
}

// MARK: - Anchored-ancestry arm

@Test
func detachedCallerWithAnAnchoredAncestorIsAuthorized() {
    // The invariant: authority follows the live parent chain. A caller with its
    // own POSIX session and no controlling tty matches no anchor on its own
    // facts, but an ancestor still sitting in the bound terminal authorizes it.
    // This is the agent-harness case, which is otherwise locked out of the
    // session it is running inside.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(detachedPeer(), ancestors: [ancestor()]),
            sessionOwner: owner(),
            anchor: anchor()
        ) == .authorized
    )
}

@Test
func detachedCallerWithASeveredChainIsUnauthorized() {
    // The other half of the invariant: orphaning severs authority. Nothing on
    // the chain reaches the terminal, so the same detached caller is refused.
    // An empty prefix is the shape a walk leaves behind when the harness was
    // reparented to launchd.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(detachedPeer(), ancestors: []),
            sessionOwner: owner(),
            anchor: anchor()
        ) == .unauthorized
    )
}

@Test
func ancestorsInAForeignTerminalDoNotAuthorize() {
    // The chain exists but leads somewhere else. A cap thief's ancestors are in
    // their own terminal, so scanning them changes nothing.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(detachedPeer(), ancestors: [ancestor(sid: 999, tty: 8, leader: 3)]),
            sessionOwner: owner(),
            anchor: anchor()
        ) == .unauthorized
    )
}

@Test
func theScanReachesAMatchBehindNonMatchingAncestors() {
    // The scan covers the whole prefix rather than stopping at the nearest
    // parent, which is what lets a harness nested several processes deep still
    // reach the tab's shell.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(
                detachedPeer(),
                ancestors: [
                    ancestor(pid: 401, sid: 999, tty: 8, leader: 3),
                    ancestor(pid: 402, sid: 998, tty: 8, leader: 3),
                    ancestor(pid: 403)
                ]
            ),
            sessionOwner: owner(),
            anchor: anchor()
        ) == .authorized
    )
}

@Test
func truncationBeforeAMatchDeniesAndTruncationAfterOneDoesNot() {
    // Truncation is not denial. The walk stops at a uid boundary, at pid 1, at
    // the depth cap, or at an unreadable hop, and it keeps whatever it verified
    // first. A prefix that reached the terminal before stopping still
    // authorizes; a prefix that stopped short of it does not. Both directions
    // matter: the first is the whole point of preserving the prefix, the second
    // is what stops truncation from becoming a bypass.
    let reachedTheTerminal = [ancestor(pid: 401, sid: 999, tty: 8, leader: 3), ancestor(pid: 402)]
    let stoppedShort = [ancestor(pid: 401, sid: 999, tty: 8, leader: 3)]
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(detachedPeer(), ancestors: reachedTheTerminal),
            sessionOwner: owner(),
            anchor: anchor()
        ) == .authorized
    )
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(detachedPeer(), ancestors: stoppedShort),
            sessionOwner: owner(),
            anchor: anchor()
        ) == .unauthorized
    )
}

@Test
func anAncestorKeepsTheFullTerminalTriple() {
    // The ancestry arm reuses the peer's terminal test unchanged; it is not a
    // weaker same-session check. An ancestor sharing the anchor's session id
    // and tty but carrying a different session-leader start is refused, exactly
    // as the peer itself would be.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(detachedPeer(), ancestors: [ancestor(leader: 111)]),
            sessionOwner: owner(),
            anchor: anchor(leader: 9)
        ) == .unauthorized
    )
}

@Test
func anAncestorWithTheDeadLeaderSentinelMatchesNoAnchor() {
    // An ancestor whose session leader has exited carries the `0` leader-start
    // sentinel. A bound anchor's leader start is always a real, positive value,
    // so the sentinel can never match one: the degraded entry stays in the
    // prefix but authorizes nothing.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(detachedPeer(), ancestors: [ancestor(leader: 0)]),
            sessionOwner: owner(),
            anchor: anchor(leader: 9)
        ) == .unauthorized
    )
}

// MARK: - Not-ready + fail-closed

@Test
func udsLiveSessionWithNoAnchorIsNotReady() {
    // Non-owner UDS peer, no anchor yet: the bounded-retryable state.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300), ancestors: []), sessionOwner: owner(), anchor: nil
        ) == .notReady
    )
}

@Test
func anAncestorPrefixDoesNotSubstituteForAMissingAnchor() {
    // The anchor gates the ancestry arm as much as the terminal arm: with no
    // anchor to compare against, a full prefix is still the retryable
    // not-ready state, never an authorization.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(detachedPeer(), ancestors: [ancestor()]), sessionOwner: owner(), anchor: nil
        ) == .notReady
    )
}

@Test
func missingPeerIdentityFailsClosed() {
    // No kernel identity → unauthorized regardless of owner/anchor.
    #expect(
        ProvenanceMatcher.verdict(peer: .missing, sessionOwner: owner(), anchor: anchor())
            == .unauthorized
    )
}

@Test
func ownerArmAuthorizesEvenWithADeadLeaderSentinel() {
    // A UDS peer whose POSIX session leader has genuinely exited resolves with a
    // real sid and tty but the leader-start degraded to the 0 sentinel. The
    // OWNER arm (the only path the GUI's UDS fallback has) authorizes on the
    // (pid, pidVersion, euid) triple regardless of terminal facts, so a dead
    // leader alone never denies a matching owner.
    let deadLeaderPeer = peer(leader: 0)
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(deadLeaderPeer, ancestors: []), sessionOwner: owner(), anchor: nil
        ) == .authorized
    )
}

@Test
func terminalArmKeepsTheLeaderStartReuseGuard() {
    // The session-leader start time is a real, non-zero value (read via
    // `sysctl(KERN_PROC_PID)` even for a root `login` leader), so it is a live
    // guard on the terminal arm: a non-owner peer sharing the anchor's sid and
    // tty but with a DIFFERENT leader start is rejected; only an exact match on
    // sid, tty, AND leader start authorizes: the protection against SID/TTY
    // reuse.
    let anch = anchor(sid: 200, tty: 5, leader: 9)
    let stranger = owner(pid: 999)  // owner mismatch → forces the terminal arm
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300, sid: 200, tty: 5, leader: 123), ancestors: []),
            sessionOwner: stranger,
            anchor: anch
        ) == .unauthorized
    )
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300, sid: 200, tty: 5, leader: 9), ancestors: []),
            sessionOwner: stranger,
            anchor: anch
        ) == .authorized
    )
}
