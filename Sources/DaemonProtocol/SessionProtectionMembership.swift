// SPDX-License-Identifier: GPL-3.0-or-later

public enum SessionProtectionMembership: String, Codable, Sendable, Equatable {
    case unprotectedState = "unprotected"
    case protectedState = "protected"
    case missing
}
