// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure helper that classifies an RGB triple as "light"
/// or "dark" so the scroll wrapper can pick a matching scroller
/// appearance (`.aqua` vs `.darkAqua`). The 0.5 threshold matches
/// Ghostty.app's `OSColor.isLightColor`.
///
/// Uses a weighted-luma heuristic over normalized encoded components:
/// 0.299 R + 0.587 G + 0.114 B, with a 0.5 threshold. This is not WCAG
/// relative luminance, which uses different coefficients over
/// gamma-decoded components.
enum ColorLuma {
    /// Treat an RGB triple (0…255 per channel, sRGB) as "light"
    /// when its relative luminance is at or above 0.5. Used by
    /// `SurfaceScrollView.updateBackgroundColor(_:)` to pick the
    /// `NSAppearance` that matches the terminal background: a
    /// light bg gets `.aqua` (dark scroller); a dark bg gets
    /// `.darkAqua` (light scroller).
    static func isLight(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        let red = Double(red) / 255.0
        let green = Double(green) / 255.0
        let blue = Double(blue) / 255.0
        let luma = 0.299 * red + 0.587 * green + 0.114 * blue
        return luma >= 0.5
    }
}
