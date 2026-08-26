// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The seam a tab-strip uses to relocate a
/// *live* tab across windows. Cross-window tab moves and tear-off can't
/// go through the Router (it owns daemon records + nav state only, and
/// has no access to AppKit view controllers): moving a tab means moving
/// its live `TabContentViewController` (libghostty surface, running
/// shell, sim panes, and session ownership all intact) between two
/// windows' strips. The implementation (`AppDelegate`) owns the
/// window-controller registry and can reach both strips, so it performs
/// the extract → detach → adopt → insert relocation as one synchronous
/// block. That stays safe because `observe()` re-arms asynchronously:
/// neither strip's `render()` tears the moved VC down or re-creates it.
@MainActor
protocol TabTransferCoordinating: AnyObject {
    /// Move `tab` from window `from` into window `to`, inserting at
    /// `atIndex` in the destination strip and selecting it. A no-op if
    /// either window or the tab is gone.
    func moveTab(_ tab: TabID, from: WindowID, to destination: WindowID, atIndex: Int)

    /// Tear `tab` out of window `from` into a brand-new window placed at
    /// `screenPoint`. A no-op when `from` has a single tab (tearing off
    /// the sole tab would just close-and-recreate the same window).
    func tearOffTab(_ tab: TabID, from: WindowID, at screenPoint: NSPoint)
}
