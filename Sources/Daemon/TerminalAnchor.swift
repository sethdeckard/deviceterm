// SPDX-License-Identifier: GPL-3.0-or-later
//
// TerminalAnchor: the in-memory binding from a daemon session to its
// terminal's kernel identity.
//
// Established by the validated GUI over `session.bindTerminal` and never
// persisted: after a daemon restart the session is restored with no anchor and
// stays unusable for provenance-gated calls until the live GUI re-binds it.
// Holds no numeric foreground pid: only the kernel-stable facts a UDS peer's
// `PeerProcessIdentity` is matched against, plus the connection that issued it
// so a GUI disconnect can revoke it.

import Foundation

public struct TerminalAnchor: Sendable, Equatable {
    /// The daemon session this terminal is bound to.
    public let sessionId: UUID
    /// Kernel-verified terminal facts (POSIX session id, leader start time,
    /// controlling TTY device).
    public let facts: TerminalAnchorFacts
    /// The validated-GUI XPC connection that issued the binding. On that
    /// connection's close the anchor is revoked.
    public let issuingGUIConnectionId: UInt64

    public init(
        sessionId: UUID,
        facts: TerminalAnchorFacts,
        issuingGUIConnectionId: UInt64
    ) {
        self.sessionId = sessionId
        self.facts = facts
        self.issuingGUIConnectionId = issuingGUIConnectionId
    }
}
