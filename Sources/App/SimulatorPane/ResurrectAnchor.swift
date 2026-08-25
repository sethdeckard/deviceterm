// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// Resurrect-time placement hint: insert the freshly-attached sim
/// next to `slot` on `side`. Captured by the resurrect dispatcher
/// before the detach removes the slot from the tree so the pane
/// lands back where the user saw it after reboot.
struct ResurrectAnchor: Sendable, Equatable {
    let slot: PaneSlot
    let side: AdjacentSide
}
