// SPDX-License-Identifier: GPL-3.0-or-later

/// CLI operations supported by a projected workspace pane.
public enum WorkspacePaneCapability: String, Codable, Sendable, Equatable, CaseIterable {
    case sendInput
    case captureText
    case touch
    case key
    case text
    case button
    case rotate
    case crown
    case accessibility
    case location
}
