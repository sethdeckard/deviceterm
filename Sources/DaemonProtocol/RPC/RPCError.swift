// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct RPCError: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
        case details
    }

    private indirect enum JSONValue: Codable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .object(value):
                try container.encode(value)

            case let .array(value):
                try container.encode(value)

            case let .string(value):
                try container.encode(value)

            case let .number(value):
                try container.encode(value)

            case let .bool(value):
                try container.encode(value)

            case .null:
                try container.encodeNil()
            }
        }
    }

    public let code: Int
    public let message: String
    /// Raw JSON object bytes carried through to public CLI failures.
    public let details: Data?

    public init(code: Int, message: String, details: Data? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        if let value = try container.decodeIfPresent(JSONValue.self, forKey: .details) {
            details = try JSONEncoder().encode(value)
        } else {
            details = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        if let details {
            try container.encode(
                JSONDecoder().decode(JSONValue.self, from: details),
                forKey: .details
            )
        }
    }
}
