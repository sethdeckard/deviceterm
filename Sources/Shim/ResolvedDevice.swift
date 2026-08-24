// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Resolved-device payload: three identifiers carried together as
/// a struct (SwiftLint caps tuple width at 2).
struct ResolvedDevice: Sendable {
    let udid: String
    let name: String
    let runtime: String
    let state: String
}
