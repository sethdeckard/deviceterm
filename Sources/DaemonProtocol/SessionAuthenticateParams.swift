// SPDX-License-Identifier: GPL-3.0-or-later

public struct SessionAuthenticateParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let cap: String

    public init(sessionId: String, cap: String) {
        self.sessionId = sessionId
        self.cap = cap
    }
}
