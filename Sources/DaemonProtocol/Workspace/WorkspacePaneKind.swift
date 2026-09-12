// SPDX-License-Identifier: GPL-3.0-or-later

/// The three addressable leaf kinds in a DeviceTerm workspace.
public enum WorkspacePaneKind: String, Codable, Sendable, Equatable, CaseIterable {
    case terminal
    case simulator
    case device
}
