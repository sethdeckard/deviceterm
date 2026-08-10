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
//     only).
//
// This function is pure over its inputs so the whole provenance matrix is
// exercised hermetically. Three outcomes, kept distinct for the caller:
//   - `.authorized`: a provenance arm matched.
//   - `.notReady`: a NON-OWNER UDS peer on a live session whose terminal
//     anchor has not been established yet (the GUI hasn't bound, or a restart
//     dropped it). Exact-owner UDS and validated-GUI callers are authorized by
//     an earlier arm, so they never reach this. The bounded-retryable state;
//     NOT an authorization.
//   - `.unauthorized`. No arm matched: a wrong terminal, a detached caller, an
//     XPC peer that isn't the owner, or a missing kernel identity (fail
//     closed). NOT retryable.

import Foundation

/// The caller's kernel identity, shaped per transport. `.missing` is the
/// fail-closed case (the kernel couldn't vend an identity).
public enum ProvenancePeer: Sendable, Equatable {
    /// XPC peer whose audit token passed the daemon's signature check.
    case validatedGUI(owner: OwnerProcessIdentity)
    /// XPC peer that did NOT validate as the GUI. Owner arm only; no terminal
    /// arm on XPC (terminal callers use UDS).
    case xpc(owner: OwnerProcessIdentity)
    /// UDS peer with full kernel identity. Owner and terminal arms.
    case uds(PeerProcessIdentity)
    /// The kernel could not vend a peer identity. Fail closed.
    case missing
}

public enum ProvenanceVerdict: Sendable, Equatable {
    case authorized
    /// A non-owner UDS peer on a live session with no terminal anchor yet
    /// (owner and validated-GUI callers match an earlier arm); the CLI
    /// retries this briefly.
    case notReady
    /// No provenance arm matched. A wrong terminal identity, a detached
    /// caller, or a missing identity all land here; the caller must not retry.
    case unauthorized
}

public enum ProvenanceMatcher {
    /// Decide the provenance verdict for `peer` against a session's captured
    /// owner identity and (for UDS) its terminal anchor. The auth layer has
    /// already confirmed the capability and that the session is live.
    public static func verdict(
        peer: ProvenancePeer,
        sessionOwner: OwnerProcessIdentity?,
        anchor: TerminalAnchor?
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

        case let .uds(peer):
            if matchesOwner(OwnerProcessIdentity(peer), sessionOwner) {
                return .authorized
            }
            // Terminal arm. Absent anchor is the retryable not-ready state; a
            // present anchor that doesn't match is a hard unauthorized.
            guard let anchor else { return .notReady }
            return matchesTerminal(peer, anchor) ? .authorized : .unauthorized
        }
    }

    private static func matchesOwner(
        _ candidate: OwnerProcessIdentity,
        _ sessionOwner: OwnerProcessIdentity?
    ) -> Bool {
        guard let sessionOwner else { return false }
        return candidate == sessionOwner
    }

    private static func matchesTerminal(_ peer: PeerProcessIdentity, _ anchor: TerminalAnchor) -> Bool {
        peer.posixSessionId == anchor.facts.terminalSessionId
            && peer.controllingTTYDev == anchor.facts.controllingTTYDevice
            && peer.posixSessionLeaderStartTime == anchor.facts.sessionLeaderStartTime
    }
}
