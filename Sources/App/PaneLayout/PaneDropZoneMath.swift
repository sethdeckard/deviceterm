// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// Pure cursor → `DropZone` math for the drag
/// destination. Each pane's frame is divided into five regions:
///
///     +-------------------+
///     |     top half      |   25% tall
///     +---+-----------+---+
///     |   |           |   |   50% tall, with
///     |lft|  center   |rt |     25% left and right edges
///     |   |           |   |     50% center
///     +---+-----------+---+
///     |    bottom half    |   25% tall
///     +-------------------+
///
/// The cursor's offset from the pane's origin picks one of the five
/// regions. Tie-breaking on exact boundaries favors the bigger zone
/// (center over edge, top/bottom over left/right) so a click that
/// lands precisely on a boundary still produces a sensible answer.
///
/// `paneFrame` is the leaf pane's frame in the layout controller's
/// host-view coordinate space; `cursor` is the cursor's position in
/// the same space. The function is pure, testable without any
/// AppKit dependencies beyond `CGRect` / `CGPoint`.
enum PaneDropZoneMath {
    /// Edge fraction: the height of the top/bottom zones and width of
    /// the left/right zones as a fraction of the pane's extent.
    static let edgeFraction: CGFloat = 0.25

    /// Return the drop zone the cursor is over for the given pane
    /// frame. Returns nil when the cursor is outside the frame.
    static func zone(forCursor cursor: CGPoint, in paneFrame: CGRect) -> DropZone? {
        guard paneFrame.contains(cursor) else { return nil }
        let offsetX = cursor.x - paneFrame.minX
        let offsetY = cursor.y - paneFrame.minY
        let topThreshold = paneFrame.height * (1 - edgeFraction)
        let bottomThreshold = paneFrame.height * edgeFraction
        let leftThreshold = paneFrame.width * edgeFraction
        let rightThreshold = paneFrame.width * (1 - edgeFraction)
        let inTop = offsetY >= topThreshold
        let inBottom = offsetY <= bottomThreshold
        let inLeft = offsetX < leftThreshold
        let inRight = offsetX > rightThreshold
        if inTop {
            return .topHalf
        }
        if inBottom {
            return .bottomHalf
        }
        if inLeft {
            return .leftHalf
        }
        if inRight {
            return .rightHalf
        }
        return .center
    }
}
