// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `pane.surfaceRelease` params: a cumulative release ack. Authority is
/// the peer connection, not the payload: the daemon reads the source
/// connection id from its dispatch context and the pool rejects any ack
/// whose connection ≠ the token's registered connection.
public struct SurfaceReleaseParams: Codable, Sendable, Equatable {
    public let paneId: String
    public let subscriptionToken: String
    public let leaseEpoch: UInt64
    /// The daemon frees committed generations strictly below this.
    public let lowestHeld: UInt64

    public init(paneId: String, subscriptionToken: String, leaseEpoch: UInt64, lowestHeld: UInt64) {
        self.paneId = paneId
        self.subscriptionToken = subscriptionToken
        self.leaseEpoch = leaseEpoch
        self.lowestHeld = lowestHeld
    }
}
