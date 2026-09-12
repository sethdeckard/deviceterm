// SPDX-License-Identifier: GPL-3.0-or-later

/// Disposition for Simulator panes closed with a tab or window.
public enum WorkspaceCloseMode: String, Codable, Sendable, Equatable, CaseIterable {
    case detach
    case shutdown
}
