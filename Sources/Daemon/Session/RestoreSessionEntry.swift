// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// One validated, parsed entry in a `session.restoreBatch`. The handler
/// decodes the wire `RestoredSession`, parses each field (a malformed
/// UUID / capability / role / short id rejects the whole batch before this
/// is built), and hands the typed set to `SessionManager.restoreBatch`,
/// which derives the verifier and performs the atomic conflict-checked
/// insert.
public struct RestoreSessionEntry: Sendable {
    public let id: UUID
    public let capability: Capability
    public let shortId: String
    public let role: SessionRole
    public let name: String?
    public let isProtected: Bool

    public init(
        id: UUID,
        capability: Capability,
        shortId: String,
        role: SessionRole,
        name: String?,
        isProtected: Bool
    ) {
        self.id = id
        self.capability = capability
        self.shortId = shortId
        self.role = role
        self.name = name
        self.isProtected = isProtected
    }
}
