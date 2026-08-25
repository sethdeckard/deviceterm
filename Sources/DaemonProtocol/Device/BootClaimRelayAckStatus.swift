// SPDX-License-Identifier: GPL-3.0-or-later

public enum BootClaimRelayAckStatus: String, Codable, Sendable, Equatable {
    case accepted
    case notReady
    case rejected
    case busy
}
