// SPDX-License-Identifier: GPL-3.0-or-later

/// Which DeviceTerm path initiated a simulator boot.
public enum BootClaimSource: String, Codable, Sendable, Equatable {
    case shim
    case gui
}
