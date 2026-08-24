// SPDX-License-Identifier: GPL-3.0-or-later
//
// BootClaimRelayAck: terminal-local relay acknowledgement. The relay validates
// kernel provenance; the socket path itself grants no authority.

public struct BootClaimRelayAck: Codable, Sendable, Equatable {
    public let status: BootClaimRelayAckStatus

    public init(status: BootClaimRelayAckStatus) {
        self.status = status
    }
}
