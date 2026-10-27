// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// Whether a saved window frame can be reused on the screens attached now.
///
/// A frame saved on a display that has since gone, or read from a file that
/// was edited, can put the window's title bar off screen, and a window
/// without a reachable title bar can't be dragged back. Such a window opens
/// at its default size, centered, instead.
enum RestoredWindowFrameDecision {
    /// The height of the strip along a window's top edge that holds its title
    /// bar, in points.
    static let titleBarHeight: CGFloat = 28
    /// How much of that strip must sit on one screen's visible area, in
    /// points across, for the title bar to be grabbed.
    static let minimumTitleBarOverlap: CGFloat = 100

    /// `saved`, grown to `minSize` where it is smaller, when its title-bar
    /// strip lies within one of `visibleScreenFrames` vertically and overlaps
    /// it by `minimumTitleBarOverlap` across; nil otherwise. A window whose
    /// lower part is on screen but whose top edge is above every screen
    /// fails, because its title bar can't be reached.
    static func frame(
        saved: CGRect,
        visibleScreenFrames: [CGRect],
        minSize: CGSize
    ) -> CGRect? {
        guard saved.origin.x.isFinite, saved.origin.y.isFinite,
            saved.width.isFinite, saved.height.isFinite else { return nil }
        let frame = CGRect(
            x: saved.origin.x,
            y: saved.origin.y,
            width: max(saved.width, minSize.width),
            height: max(saved.height, minSize.height)
        )
        let titleBar = CGRect(
            x: frame.minX,
            y: frame.maxY - titleBarHeight,
            width: frame.width,
            height: titleBarHeight
        )
        let reachable = visibleScreenFrames.contains { screen in
            let overlap = screen.intersection(titleBar)
            return !overlap.isNull
                && overlap.width >= minimumTitleBarOverlap
                && overlap.height >= titleBarHeight
        }
        return reachable ? frame : nil
    }
}
