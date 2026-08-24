// SPDX-License-Identifier: GPL-3.0-or-later
//
// ProvenanceMatcher. The pure decision at the heart of session provenance.
//
// A session's capability authenticates possession, but the capability is
// readable by any same-uid process in the tab's tree (it is inherited env, and
// recoverable via `ps -E`). So possession alone can't authenticate a session.
// A caller is authorized as a session only when, in addition to a valid
// capability and a live session (checked by the auth layer), its kernel
// process provenance matches one of:
//
//   - it is the validated GUI peer (a provenance exception; XPC only); or
//   - it is exactly the process that created the session (owner arm); or
//   - it belongs to the session's bound terminal: same POSIX session id, same
//     controlling TTY, same session-leader start identity (terminal arm; UDS
//     only); or
//   - one of its live ancestors belongs to that terminal by the same test
//     (anchored-ancestry arm; UDS only).
//
// The ancestry arm is why authority is the live parent chain rather than
// terminal membership alone. A caller that detached from the terminal cannot
// match on its own facts, but a harness that runs each command under `setsid`
// still hangs off the tab's shell, and refusing it locks every agent running
// in a tab out of its own session. Orphaning is what severs authority: once no
// live ancestor reaches the terminal, nothing authorizes. The trade: detaching
// a child does not renounce its trust, which would require a separate
// quarantine mechanism.
//
// This function is pure over its inputs so the whole provenance matrix is
// exercised hermetically. Three outcomes, kept distinct for the caller:
//   - `.authorized`: a provenance arm matched.
//   - `.notReady`: a NON-OWNER UDS peer on a live session whose terminal
//     anchor has not been established yet (the GUI hasn't bound, or a restart
//     dropped it). Exact-owner UDS and validated-GUI callers are authorized by
//     an earlier arm, so they never reach this. The bounded-retryable state;
//     NOT an authorization.
//   - `.unauthorized`. No arm matched: a wrong terminal, a caller whose chain
//     no longer reaches the terminal, an XPC peer that isn't the owner, or a
//     missing kernel identity (fail closed). NOT retryable.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ProvenanceMatcher {
    /// Decide the provenance verdict for `peer` against a session's captured
    /// owner identity and (for UDS) its terminal facts. The auth layer has
    /// already confirmed the capability and that the session is live.
    public static func verdict(
        peer: ProvenancePeer,
        sessionOwner: OwnerProcessIdentity?,
        anchor: TerminalAnchorFacts?
    ) -> ProvenanceVerdict {
        switch peer {
        case .missing:
            // No kernel identity; fail closed regardless of the capability.
            return .unauthorized

        case .validatedGUI:
            // The signature-validated GUI is trusted for the provenance
            // factor; the capability + live-session checks still gate which
            // session it may act for.
            return .authorized

        case let .xpc(owner):
            // Owner arm only. No terminal arm and no not-ready on XPC.
            return matchesOwner(owner, sessionOwner) ? .authorized : .unauthorized

        case let .uds(peer, ancestors):
            if matchesOwner(OwnerProcessIdentity(peer), sessionOwner) {
                return .authorized
            }
            // Terminal arm. Absent anchor is the retryable not-ready state; a
            // present anchor that doesn't match is a hard unauthorized.
            guard let anchor else { return .notReady }
            if matchesTerminal(peer, anchor) { return .authorized }
            // Anchored-ancestry arm, evaluated last so a direct terminal match
            // returns without scanning ancestors. Every entry is scanned with
            // the SAME terminal test as the peer: no weaker same-session check.
            //
            // The prefix may be short because the walk truncated. That is not
            // itself a denial: a match sitting below the truncation point still
            // authorizes, and only a scan that finds nothing refuses. A severed
            // chain is `.unauthorized` rather than `.notReady`, matching how a
            // caller with the wrong terminal is treated, because it is
            // permanent for that process.
            let anchored = ancestors.contains { matchesTerminal($0, anchor) }
            return anchored ? .authorized : .unauthorized
        }
    }

    private static func matchesOwner(
        _ candidate: OwnerProcessIdentity,
        _ sessionOwner: OwnerProcessIdentity?
    ) -> Bool {
        guard let sessionOwner else { return false }
        return candidate == sessionOwner
    }

    private static func matchesTerminal(
        _ peer: PeerProcessIdentity,
        _ anchor: TerminalAnchorFacts
    ) -> Bool {
        matchesTerminal(
            sessionId: peer.posixSessionId,
            ttyDev: peer.controllingTTYDev,
            leaderStart: peer.posixSessionLeaderStartTime,
            anchor
        )
    }

    private static func matchesTerminal(
        _ ancestor: AncestorProcessIdentity,
        _ anchor: TerminalAnchorFacts
    ) -> Bool {
        matchesTerminal(
            sessionId: ancestor.posixSessionId,
            ttyDev: ancestor.controllingTTYDev,
            leaderStart: ancestor.posixSessionLeaderStartTime,
            anchor
        )
    }

    /// The terminal triple, written once. Both overloads above route here so
    /// the ancestry arm cannot drift into a weaker test than the peer's.
    private static func matchesTerminal(
        sessionId: pid_t,
        ttyDev: dev_t,
        leaderStart: UInt64,
        _ anchor: TerminalAnchorFacts
    ) -> Bool {
        sessionId == anchor.terminalSessionId
            && ttyDev == anchor.controllingTTYDevice
            && leaderStart == anchor.sessionLeaderStartTime
    }
}
