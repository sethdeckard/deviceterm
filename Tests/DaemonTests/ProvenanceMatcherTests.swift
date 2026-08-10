// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
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

private func owner(pid: pid_t = 100, ver: Int32 = 1, euid: uid_t = 501) -> OwnerProcessIdentity {
    OwnerProcessIdentity(pid: pid, pidVersion: ver, euid: euid)
}

private func anchor(sid: pid_t = 200, tty: dev_t = 5, leader: UInt64 = 9) -> TerminalAnchor {
    TerminalAnchor(
        sessionId: UUID(),
        facts: TerminalAnchorFacts(
            terminalSessionId: sid, sessionLeaderStartTime: leader, controllingTTYDevice: tty
        ),
        issuingGUIConnectionId: 1
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
        ProvenanceMatcher.verdict(peer: .uds(peer()), sessionOwner: owner(), anchor: nil)
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
        ProvenanceMatcher.verdict(peer: .uds(peer(ver: 1)), sessionOwner: recycled, anchor: anchor())
            == .authorized
    )
}

// MARK: - Terminal arm

@Test
func udsTerminalMatchIsAuthorized() {
    // A non-owner UDS peer whose session/tty/leader-start match the anchor.
    #expect(
        ProvenanceMatcher.verdict(peer: .uds(peer(pid: 300)), sessionOwner: owner(), anchor: anchor())
            == .authorized
    )
}

@Test
func udsSameTTYWrongSessionIsUnauthorized() {
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300, sid: 999, tty: 5)), sessionOwner: owner(), anchor: anchor(sid: 200, tty: 5)
        ) == .unauthorized
    )
}

@Test
func udsSameSessionWrongTTYIsUnauthorized() {
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300, sid: 200, tty: 7)), sessionOwner: owner(), anchor: anchor(sid: 200, tty: 5)
        ) == .unauthorized
    )
}

@Test
func udsWrongLeaderStartIsUnauthorized() {
    // SID/pid reuse: same session id and tty but a different session-leader
    // start identity → rejected.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300, leader: 111)), sessionOwner: owner(), anchor: anchor(leader: 9)
        ) == .unauthorized
    )
}

@Test
func detachedCallerWithNoControllingTTYIsUnauthorized() {
    // A setsid/detached caller loses its controlling tty (NODEV), so it can't
    // match the anchor's real tty.
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300, tty: dev_t(-1))), sessionOwner: owner(), anchor: anchor(tty: 5)
        ) == .unauthorized
    )
}

// MARK: - Not-ready + fail-closed

@Test
func udsLiveSessionWithNoAnchorIsNotReady() {
    // Non-owner UDS peer, no anchor yet: the bounded-retryable state.
    #expect(
        ProvenanceMatcher.verdict(peer: .uds(peer(pid: 300)), sessionOwner: owner(), anchor: nil)
            == .notReady
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
        ProvenanceMatcher.verdict(peer: .uds(deadLeaderPeer), sessionOwner: owner(), anchor: nil)
            == .authorized
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
            peer: .uds(peer(pid: 300, sid: 200, tty: 5, leader: 123)),
            sessionOwner: stranger,
            anchor: anch
        ) == .unauthorized
    )
    #expect(
        ProvenanceMatcher.verdict(
            peer: .uds(peer(pid: 300, sid: 200, tty: 5, leader: 9)),
            sessionOwner: stranger,
            anchor: anch
        ) == .authorized
    )
}
