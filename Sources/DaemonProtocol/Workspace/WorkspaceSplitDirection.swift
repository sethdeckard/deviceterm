// SPDX-License-Identifier: GPL-3.0-or-later

/// Placement of a new terminal pane relative to its anchor.
public enum WorkspaceSplitDirection: String, Codable, Sendable, Equatable, CaseIterable {
    case left
    case right
    // swiftlint:disable:next identifier_name
    case up
    case down
}
