// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct AXTreeLimits: Equatable, Sendable {
    static let `default` = AXTreeLimits(maxDepth: 24, maxNodes: 4_000)

    /// How deep to descend before stopping. The root is depth 0.
    let maxDepth: Int
    /// Total nodes to emit across the whole walk.
    let maxNodes: Int
}
