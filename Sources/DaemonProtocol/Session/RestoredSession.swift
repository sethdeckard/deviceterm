// SPDX-License-Identifier: GPL-3.0-or-later

/// One session in a restore batch. Carries only state the GUI can
/// authoritatively reconstruct from its own live model; the daemon
/// derives everything else (owner from the XPC peer, verifier from the
/// capability, `createdAt` fresh).
///
/// Deliberately absent:
/// - **owner / ownerPID**: captured server-side from the validated XPC
///   audit token, exactly as `session.create` does; never wire-supplied.
/// - **terminal anchor / grant**: never persisted, never restored here;
///   the GUI re-establishes them AFTER restore (`session.bindTerminal`,
///   then automation grants) in a fixed order.
/// - **epoch**: the ordering epoch is the caller's XPC connection id,
///   derived server-side from the dispatch context, never wire-supplied (a
///   client can't forge or rewind it). Paired with `revision` it fences a
///   restore against staleness and orders it against overlapping restores;
///   replay safety rests on that fence plus idempotency, conflict-reject, and
///   the `.validatedGUI` scope.
/// - **label**: the GUI has no authoritative label source (sessions are
///   created with a nil label), so none is invented; the daemon defaults
///   it as `session.create` does with a nil label.
public struct RestoredSession: Codable, Sendable, Equatable {
    /// The UUID string the session is restored under (the id the tab's
    /// env cap was minted against). Must parse as a UUID.
    public let sessionId: String
    /// The EXISTING bearer capability the GUI still holds for this session
    /// (the one already in the tab shell's `DEVICETERM_SESSION_CAP`). The
    /// daemon re-derives the non-recoverable `CapabilityVerifier` from it
    /// via the same domain-separated hash `session.create` uses, so the
    /// in-tab cap keeps authenticating across a daemon restart. Never
    /// logged or interpolated into a diagnostic string.
    public let capability: String
    /// The immutable Crockford-base32 short id the session already had.
    /// Preserved verbatim (never re-derived) so cached `--tab <ref>`
    /// values and scripts keep working across a daemon restart.
    public let shortId: String
    /// The role the session was minted with (`agent` | `automation`).
    public let role: SessionRole
    /// The optional human/agent-set tab name.
    public let name: String?
    /// The desired absolute protection state, derived fail-closed from the
    /// GUI's effective-hidden presentation (a mid-transition tab restores
    /// protected, never briefly unprotected).
    public let isProtected: Bool

    public init(
        sessionId: String,
        capability: String,
        shortId: String,
        role: SessionRole,
        name: String?,
        isProtected: Bool
    ) {
        self.sessionId = sessionId
        self.capability = capability
        self.shortId = shortId
        self.role = role
        self.name = name
        self.isProtected = isProtected
    }
}
