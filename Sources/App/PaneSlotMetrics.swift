// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

struct PaneSlotMetrics: Sendable, Equatable {
    /// Identity of the pane this child represents; lets the caller
    /// match the extent back to its slot.
    let slot: PaneSlot
    /// Natural extent along the parent split's divider axis (points).
    /// For sims: a point-accurate computation against the axis the
    /// split currently runs. For terminals: a configurable default
    /// the caller picks.
    let naturalExtent: CGFloat
    /// Per-axis minimum extent. Mirrors the existing
    /// `terminalMinThickness(isVertical:)` /
    /// `simMinThickness(family:isVertical:)` floors so a layout pass
    /// always leaves every pane at a usable size.
    let minimumExtent: CGFloat
    /// Whether this pane absorbs leftover space when others have hit
    /// their natural extent. Terminals true (text flows); sims false
    /// (they aspect-fit).
    let isFlexible: Bool
}
