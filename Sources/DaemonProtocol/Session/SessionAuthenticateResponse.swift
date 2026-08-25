// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for the `session.authenticate` RPC method that establishes
/// per-connection auth.
///
/// The CLI auto-sends this as the first frame on every UDS
/// connection when its env carries `(DEVICETERM_SESSION,
/// DEVICETERM_SESSION_CAP)`. The daemon validates `(sessionId, cap)`
/// against `SessionManager` AND matches the caller's kernel provenance
/// against the session's bound terminal, then stores the resulting
/// `SessionState` on the `RPCConnection` and returns the role so the
/// caller knows which scope it's in. The cap alone establishes nothing:
/// any same-uid process can read it. Liveness and provenance are
/// re-checked before every scoped request, so closing a session or
/// revoking its anchor invalidates an already-authenticated connection.
///
/// Subsequent session-scoped methods on the same connection succeed
/// without per-call cred threading, and daemon-wide methods work whether
/// the connection authenticated or not. A few request bodies still carry
/// `(sessionId, cap)` of their own; their handlers confirm the target
/// equals the connection's provenance-checked session rather than
/// trusting the payload.
public struct SessionAuthenticateResponse: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case success = "ok"
        case role
    }

    /// Always true on success; on auth failure the daemon returns
    /// an `error.unauthorized` envelope instead of this shape.
    public let success: Bool
    /// The role the daemon assigned to this session, so the caller
    /// learns its scope on the same round-trip. Same value as the
    /// `role` field on `session.create`'s response.
    public let role: SessionRole

    public init(success: Bool, role: SessionRole) {
        self.success = success
        self.role = role
    }
}
