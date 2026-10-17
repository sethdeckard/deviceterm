// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

/// Turns the layout controller's slot frames into the published
/// `WorkspacePaneFrame`.
///
/// The controller's root view follows AppKit's default orientation, y growing
/// upward, while the published frame is measured from the top-left corner, the
/// way a reader lays out boxes.
enum PaneFrameMath {
    /// `rect`, given in a container `height` points tall with y growing upward,
    /// re-expressed with y measured down from the container's top edge.
    static func topLeft(_ rect: CGRect, inHeight height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// `rect` in whole points, or nil when its rounded edges enclose no area.
    /// Only a rectangle less than a point across can round away.
    ///
    /// Rounds each edge rather than the origin and size separately, so two
    /// panes sharing an edge still share it after rounding.
    static func wholePoints(_ rect: CGRect) -> WorkspacePaneFrame? {
        let minX = Int(rect.minX.rounded())
        let minY = Int(rect.minY.rounded())
        let maxX = Int(rect.maxX.rounded())
        let maxY = Int(rect.maxY.rounded())
        guard maxX > minX, maxY > minY else { return nil }
        return WorkspacePaneFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
