// SPDX-License-Identifier: GPL-3.0-or-later

/// Shape of the `daemon.capabilities` RPC reply.
///
/// Daemon-wide method; works with or without session creds (the
/// forward-compat for out-of-tab CLI calls). The CLI queries this at
/// startup and uses the result to filter `--help` to the verbs the
/// caller can actually invoke.
///
/// Wire shape:
///
///     request  {}   (body ignored)
///     response { role: SessionRole?, sessionId: String?,
///                automationGrant: Bool, allowedMethods: [String],
///                wireVersion: String, linkagePolicyVersion: Int }
///
/// The request carries NO body. `daemon.capabilities` derives its authority
/// from the PROVENANCE-CHECKED connection
/// (`DispatchPeerContext.authenticatedSession`), never a payload cap. A stolen
/// cap in the body must not surface a victim's role/grant advertising.
/// `role: nil` means the connection isn't authenticated (out-of-tab); the
/// daemon falls back to the daemon-wide subset of `allowedMethods` rather than
/// rejecting, so out-of-tab `deviceterm --help` works without authentication.
///
/// `linkagePolicyVersion` is forward-compat: increment whenever the
/// linkage semantics change in a way a pre-existing CLI couldn't
/// infer (new pane states, new `error.unlinked_pane` shapes). Lets
/// `deviceterm doctor` against a newer daemon hint about features the
/// CLI may not understand.
public struct DaemonCapabilitiesResponse: Codable, Sendable, Equatable {
    public let role: SessionRole?
    /// The connection's authenticated session, or nil out of tab. Taken from
    /// the provenance-checked connection like `role`, never from a payload.
    public let sessionId: String?
    /// Whether that session currently holds a live automation grant.
    public let automationGrant: Bool
    public let allowedMethods: [String]
    public let wireVersion: String
    public let linkagePolicyVersion: Int

    public init(
        role: SessionRole?,
        sessionId: String?,
        automationGrant: Bool,
        allowedMethods: [String],
        wireVersion: String,
        linkagePolicyVersion: Int
    ) {
        self.role = role
        self.sessionId = sessionId
        self.automationGrant = automationGrant
        self.allowedMethods = allowedMethods
        self.wireVersion = wireVersion
        self.linkagePolicyVersion = linkagePolicyVersion
    }

    /// During an update a newer client can receive a reply with no
    /// `automationGrant`. Derive it from `pane.sendInput` in `allowedMethods`,
    /// which appears exactly when the grant is live, so a live grant survives.
    /// Defaulting to false instead would understate a session's authority, and
    /// deriving here rather than at each call site leaves the type unable to
    /// report "unknown" at all.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(SessionRole.self, forKey: .role)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        allowedMethods = try container.decode([String].self, forKey: .allowedMethods)
        automationGrant = try container.decodeIfPresent(Bool.self, forKey: .automationGrant)
            ?? allowedMethods.contains(RPCMethod.paneSendInput.rawValue)
        wireVersion = try container.decode(String.self, forKey: .wireVersion)
        linkagePolicyVersion = try container.decode(Int.self, forKey: .linkagePolicyVersion)
    }
}
