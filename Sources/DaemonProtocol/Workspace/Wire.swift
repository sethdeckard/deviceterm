// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Wire-format ref types. Two-key shape (`type` discriminator +
/// optional `value`) for forward-compat, so a future ref kind can
/// extend the enum without breaking older decoders.
public enum Wire {
    public struct TabRef: Codable, Sendable, Equatable {
        public let type: String      // "current" | "sessionId" | "shortId" | "name"
        public let value: String?

        public init(type: String, value: String?) {
            self.type = type; self.value = value
        }
    }

    public struct PaneRef: Codable, Sendable, Equatable {
        public let type: String      // "current" | "paneId" | "udid" | "shortId"
        public let value: String?

        public init(type: String, value: String?) {
            self.type = type; self.value = value
        }
    }

    public struct WindowRef: Codable, Sendable, Equatable {
        public let type: String      // "current" | "index" | "keyed"
        public let value: String?    // "index" → stringified Int

        public init(type: String, value: String?) {
            self.type = type; self.value = value
        }
    }
}
