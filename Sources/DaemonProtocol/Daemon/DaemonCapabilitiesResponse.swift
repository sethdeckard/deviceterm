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
///     response { role: SessionRole?, allowedMethods: [String],
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
    public let allowedMethods: [String]
    public let wireVersion: String
    public let linkagePolicyVersion: Int

    public init(
        role: SessionRole?,
        allowedMethods: [String],
        wireVersion: String,
        linkagePolicyVersion: Int
    ) {
        self.role = role
        self.allowedMethods = allowedMethods
        self.wireVersion = wireVersion
        self.linkagePolicyVersion = linkagePolicyVersion
    }
}
