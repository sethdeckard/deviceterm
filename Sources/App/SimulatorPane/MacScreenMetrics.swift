// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

/// Mac-side inputs to size-preset math.
struct MacScreenMetrics: Equatable, Sendable {
    /// `NSScreen.backingScaleFactor` of the screen the pane is on
    /// (typically 2.0 for Retina, 1.0 for non-Retina).
    let backingScaleFactor: CGFloat
    /// Pixels-per-inch of the Mac screen, used for the Physical Size
    /// preset. Defaults to 110 PPI matching the SwiftUI baseline.
    let pointsPerInch: CGFloat
}
