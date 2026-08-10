// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabDragPayload: the pasteboard payload for a tab-strip drag. Carries
// the source window + the dragged tab's id and its index at drag start.
// A same-window drop reorders; a drop onto another window's strip moves
// the tab (its live view controller travels with it; see the AppDelegate
// transfer coordinator); a drop on empty space tears the tab off into a
// new window.
//
// Encoded as JSON via `JSONEncoder()` on the source side, decoded with
// `JSONDecoder()` on the destination, the same pattern as
// `PaneDragPayload`. A distinct `pasteboardType` keeps tab and pane drags
// from ever cross-decoding (the pane destination already rejects on a
// mismatched payload shape, and vice versa).

import Foundation

struct TabDragPayload: Codable, Sendable, Equatable {
    /// Custom pasteboard type. Bundle-scoped and distinct from the pane
    /// drag type so a pane drag never registers as a tab drag.
    static let pasteboardType = "com.deviceterm.tab.drag"

    let sourceWindowID: WindowID
    let tabID: TabID
    /// The tab's index in its window at drag start. Advisory, since the
    /// destination recomputes the live index by `tabID` before moving,
    /// but kept on the wire so a future consumer can label the drag.
    let sourceIndex: Int
}
