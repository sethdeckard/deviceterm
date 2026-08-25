// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct RPCError: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
    }

    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}
