// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionAuthenticate{Params,Response}: wire shape for the
// `session.authenticate` RPC method that establishes per-connection
// auth.
//
// The CLI auto-sends this as the first frame on every UDS
// connection when its env carries `(DEVICETERM_SESSION,
// DEVICETERM_SESSION_CAP)`. The daemon validates the creds against
// SessionManager, stores the resulting SessionState on the
// `RPCConnection`, and returns the role so the caller knows which
// scope it's in. Subsequent session-scoped methods on the same
// connection succeed without per-call cred threading; daemon-wide
// methods work whether the connection auth'd or not.
//
// `(sessionId, cap)` parameters stay on this one method; they're
// the auth handshake. Other methods don't carry creds; the
// connection's auth state is the source of truth at dispatch time.

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
