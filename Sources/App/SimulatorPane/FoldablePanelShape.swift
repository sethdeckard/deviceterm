// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// Which of a foldable's panels a frame shows, read off the frame itself.
///
/// The daemon's `panel.changed` and the new panel's first surface race to the
/// GUI, so drawing a frame in whatever shape the last event named can put the
/// cover in the inner panel's bent frame for a moment, or the reverse. A
/// foldable's panels differ in size, so once the hinge-spanning panel's size
/// is known the frame's own size says which panel it is, and the shape it's
/// drawn in can't disagree with the picture.
enum FoldablePanelShape {
    /// Whether a frame of `surfaceSize` comes from the panel the hinge runs
    /// through.
    ///
    /// Matches either way round, since the two sizes are read from different
    /// places. Falls back to `reported`, the daemon's last word, when either
    /// size is unknown.
    static func spansHinge(surfaceSize: CGSize, spanningPanelSize: CGSize?, reported: Bool) -> Bool {
        guard let spanning = spanningPanelSize,
            spanning.width > 0, spanning.height > 0,
            surfaceSize.width > 0, surfaceSize.height > 0 else { return reported }
        return surfaceSize == spanning
            || surfaceSize == CGSize(width: spanning.height, height: spanning.width)
    }
}
