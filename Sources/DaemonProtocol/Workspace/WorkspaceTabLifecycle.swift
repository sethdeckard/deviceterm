// SPDX-License-Identifier: GPL-3.0-or-later

/// Whether a tab has a usable initial terminal session.
public enum WorkspaceTabLifecycle: String, Codable, Sendable, Equatable, CaseIterable {
    case opening
    case ready
    case failed
}
