// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct TabInfoPayload: Codable, Sendable, Equatable {
    public let sessionId: String
    public let shortId: String?
    public let name: String?
    public let role: String
    public let cwd: String?
    public let label: String?
    public let isCurrent: Bool
    public let simPanes: [SimPanePayload]

    public init(
        sessionId: String,
        shortId: String?,
        name: String?,
        role: String,
        cwd: String?,
        label: String?,
        isCurrent: Bool,
        simPanes: [SimPanePayload]
    ) {
        self.sessionId = sessionId
        self.shortId = shortId
        self.name = name
        self.role = role
        self.cwd = cwd
        self.label = label
        self.isCurrent = isCurrent
        self.simPanes = simPanes
    }
}
