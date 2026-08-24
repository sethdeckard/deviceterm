// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// The zone of a target leaf the cursor is over during a drag.
/// `.center` swaps with the target; the four halves either reorder
/// within the existing parent split (when the parent's axis matches)
/// or create a new sub-split (when it doesn't).
enum DropZone: Sendable, Equatable {
    case center
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
}
