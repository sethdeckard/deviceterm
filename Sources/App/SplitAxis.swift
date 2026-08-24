// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

enum SplitAxis: String, Sendable, Codable {
    /// Children arranged side-by-side; divider is vertical.
    /// Maps to `NSSplitView.isVertical = true`.
    case horizontal
    /// Children stacked top-to-bottom; divider is horizontal.
    /// Maps to `NSSplitView.isVertical = false`.
    case vertical
}
