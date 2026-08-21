// SPDX-License-Identifier: GPL-3.0-or-later
//
// BootClaimSource: which DeviceTerm path initiated a simulator boot.

public enum BootClaimSource: String, Codable, Sendable, Equatable {
    case shim
    case gui
}
