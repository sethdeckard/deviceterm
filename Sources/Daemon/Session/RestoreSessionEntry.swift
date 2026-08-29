// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// One parsed entry in a `session.restoreBatch`. The handler parses session
/// and tab UUIDs and capabilities, then hands the entries to
/// `SessionManager.restoreBatch`, which validates short IDs, derives the
/// verifiers, and performs the atomic conflict-checked insert.
public struct RestoreSessionEntry: Sendable {
    public let id: UUID
    public let tabId: UUID
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
        isProtected: Bool,
        tabId: UUID? = nil
    ) {
        self.id = id
        self.tabId = tabId ?? id
        self.capability = capability
        self.shortId = shortId
        self.role = role
        self.name = name
        self.isProtected = isProtected
    }
}
