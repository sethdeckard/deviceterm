// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

/// Device-side inputs to size-preset math. Kept as a tiny value type
/// so the pure function signature reads naturally and the unit tests
/// can construct fixtures inline.
struct SimDeviceMetrics: Equatable, Sendable {
    /// Native pixel width of the device's display (from
    /// `SimDisplayHandle.displaySize` via the attach response).
    let pixelWidth: Int
    /// Native pixel height of the device's display. Pairs with
    /// `pixelWidth` to derive aspect ratio.
    let pixelHeight: Int
    /// Coarse device family. Picks the @x default for Point Accurate
    /// and the native PPI baseline for Physical Size. Watch overrides
    /// to @2x; phone defaults to @3x (modern Pro models); pad @2x;
    /// tv @1x; unknown @1x as a conservative fallback.
    let family: DeviceFamily
}
