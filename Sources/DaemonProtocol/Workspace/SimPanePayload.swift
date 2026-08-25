// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct SimPanePayload: Codable, Sendable, Equatable {
    public let paneId: String
    public let udid: String
    public let shortId: String?
    public let displayName: String
    public let family: String

    public init(
        paneId: String,
        udid: String,
        shortId: String?,
        displayName: String,
        family: String
    ) {
        self.paneId = paneId
        self.udid = udid
        self.shortId = shortId
        self.displayName = displayName
        self.family = family
    }
}
