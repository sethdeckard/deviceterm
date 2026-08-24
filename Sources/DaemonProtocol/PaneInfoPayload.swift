// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct PaneInfoPayload: Codable, Sendable, Equatable {
    public let paneId: String
    public let udid: String
    public let shortId: String?
    public let name: String?
    public let displayName: String
    public let family: String
    public let linkedSessionId: String

    public init(
        paneId: String,
        udid: String,
        shortId: String?,
        name: String?,
        displayName: String,
        family: String,
        linkedSessionId: String
    ) {
        self.paneId = paneId
        self.udid = udid
        self.shortId = shortId
        self.name = name
        self.displayName = displayName
        self.family = family
        self.linkedSessionId = linkedSessionId
    }
}
