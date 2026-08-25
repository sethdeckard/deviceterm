// SPDX-License-Identifier: GPL-3.0-or-later

/// One session's snapshotted protection. `.missing` names a requested id
/// that has no live session (a since-closed terminal), an explicit
/// entry so the GUI sees the membership change instead of a silent drop.
public struct SessionProtectionEntry: Codable, Sendable, Equatable {
    public let sessionId: String
    public let state: SessionProtectionMembership

    public init(sessionId: String, state: SessionProtectionMembership) {
        self.sessionId = sessionId
        self.state = state
    }
}
