// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// `deviceterm session show`.
///
/// Answers "who am I and what may I do" in one round trip, so a caller
/// refreshing its view of the workspace does not have to discover its own
/// authority by attempting a privileged call and reading the refusal.
///
/// The command is daemon-wide rather than grant-scoped, deliberately. A
/// caller with no grant is the case that most needs an answer, so it gets
/// `automationGrant: false` and exit 0 rather than a refusal. An unreachable
/// daemon is a different state and fails with a typed transport error, because
/// "you hold no grant" and "DeviceTerm is not running" call for opposite
/// responses from whoever is asking.
public struct SessionReport: Encodable, Sendable, Equatable {
    /// The session the daemon authenticated this connection as, or nil when
    /// the caller is outside a DeviceTerm tab.
    public let id: String?
    /// Descriptive session metadata, defaulted at `session.create`. A role
    /// alone grants no authority: a session can carry `automation` while
    /// holding no grant.
    public let role: SessionRole?
    /// Whether this session currently holds a live automation grant. Always
    /// present, so a caller branches on a boolean rather than on the presence
    /// of some other field.
    public let automationGrant: Bool

    public init(id: String?, role: SessionRole?, automationGrant: Bool) {
        self.id = id
        self.role = role
        self.automationGrant = automationGrant
    }

    /// Build from a `daemon.capabilities` reply. The grant is settled by that
    /// type's decoder, including against a daemon that predates the flag.
    ///
    /// Every field is the daemon's answer about the provenance-checked
    /// connection. `DEVICETERM_SESSION` is deliberately not consulted for `id`:
    /// it is a caller-supplied claim, and it stays set when missing or empty
    /// credentials prevent authentication.
    public init(capabilities: DaemonCapabilitiesResponse) {
        self.init(
            id: capabilities.sessionId,
            role: capabilities.role,
            automationGrant: capabilities.automationGrant
        )
    }
}
