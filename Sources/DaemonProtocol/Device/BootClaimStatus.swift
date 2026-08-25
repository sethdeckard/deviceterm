// SPDX-License-Identifier: GPL-3.0-or-later

/// The daemon's idempotent reconciliation result for one
/// DeviceTerm-originated simulator boot attempt.
public enum BootClaimStatus: String, Codable, Sendable, Equatable {
    case pending
    case promoted
    case canceled
    case expired
    case failed
    case superseded
}
