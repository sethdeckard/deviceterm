// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The canonical `{"ok": true}` response shape used by every
/// RPC method that has no domain-specific result body.
///
/// Session closes, the PTY and device shutdown-style methods, and the pane
/// mutations all reply with the same minimal payload: a single boolean
/// keyed `ok`. One shared type keeps them from each declaring their own.
///
/// The Swift identifier is `success` rather than `ok` for readability and
/// to keep SwiftLint's short-name rule satisfied; `ok` stays the wire key.
public struct RPCAck: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case success = "ok"
    }

    public let success: Bool

    public init(success: Bool) {
        self.success = success
    }
}
