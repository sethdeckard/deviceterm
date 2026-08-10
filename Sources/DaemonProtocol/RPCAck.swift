// SPDX-License-Identifier: GPL-3.0-or-later
//
// RPCAck: the canonical `{"ok": true}` response shape used by every
// RPC method that has no domain-specific result body.
//
// Four RPC methods (Session.close, every PTY/Device shutdown-style
// method, every Pane mutation) reply with the same minimal payload:
// a single boolean keyed `ok`. Each `*Methods.swift` namespace used
// to declare its own `AckResponse` struct; once the fourth duplicate
// appeared, the comment in `DeviceMethods.swift` made explicit what
// to do: extract a shared type. This is that type.
//
// Wire format is unchanged: `{"ok": true}` encodes/decodes identically
// to the previous per-namespace structs. The Swift identifier is
// `success` rather than `ok` for readability and to keep SwiftLint's
// short-name rule satisfied.

import Foundation

public struct RPCAck: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case success = "ok"
    }

    public let success: Bool

    public init(success: Bool) {
        self.success = success
    }
}
