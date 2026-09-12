// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Stable compact display handle derived from a public workspace UUID.
enum WorkspaceShortID {
    static func make(from id: UUID) -> String {
        id.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(6)
            .lowercased()
    }
}
