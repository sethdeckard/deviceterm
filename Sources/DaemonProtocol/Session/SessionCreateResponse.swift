// SPDX-License-Identifier: GPL-3.0-or-later
//
/// `session.create` → `{sessionId, capability, shortId?, name?, role?}`.
/// Mirrors `SessionMethods.CreateResponse`.
///
/// `shortId` is the daemon-minted Crockford base32 short identifier
/// for `--tab <ref>` resolution. `name` is the optional session name
/// the caller supplied at `session.create`, echoed back (the GUI
/// derives it from a git worktree branch when it detects one, but the
/// wire imposes no such rule); `deviceterm tab rename` changes only
/// GUI presentation and does not write back here.
/// `role` is the role the daemon assigned to this session
/// (descriptive metadata, not an authorization gate), surfaced for
/// display/diagnostics. The verbs a caller may invoke come from
/// `daemon.capabilities` (derived from transport and live grant state),
/// not from this field.
///
/// All three Optional on this shape (not on the daemon's shape) so a
/// client built against an older daemon (Sparkle update window) still
/// decodes cleanly when the daemon doesn't emit the field. The current
/// daemon always emits non-nil `shortId` and `role`; `name` is nil
/// whenever the request carried none.
public struct SessionCreateResponse: Codable, Sendable, Equatable {
    public let sessionId: String
    public let capability: String
    /// Daemon-minted short identifier (Crockford base32, 6 chars).
    /// Optional for skew tolerance against pre-identifier-model
    /// daemons; the current daemon always emits a non-nil value.
    public let shortId: String?
    /// The session name supplied at creation, or nil when the caller
    /// supplied none. Nothing renames it afterward.
    public let name: String?
    /// Role assigned at create time (descriptive metadata). Optional for
    /// skew tolerance against pre-role daemons; the current daemon always
    /// emits a non-nil value.
    public let role: SessionRole?

    public init(
        sessionId: String,
        capability: String,
        shortId: String? = nil,
        name: String? = nil,
        role: SessionRole? = nil
    ) {
        self.sessionId = sessionId
        self.capability = capability
        self.shortId = shortId
        self.name = name
        self.role = role
    }
}
