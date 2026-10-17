// SPDX-License-Identifier: GPL-3.0-or-later

/// Where one pane sits in its tab, in whole points from the top-left corner of
/// the tab's pane area.
///
/// The slot the pane occupies, not what it draws: a device pane letterboxes its
/// screen inside this rectangle. Points are consistent across one tab's panes,
/// so proportions within a tab are meaningful; nothing relates two tabs' units.
public struct WorkspacePaneFrame: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
