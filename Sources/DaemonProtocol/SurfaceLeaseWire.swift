// SPDX-License-Identifier: GPL-3.0-or-later
//
// SurfaceLeaseWire: request/response shapes for the device-pane
// surface-lease protocol.
//
// The daemon owns each physical-device frame in a leased surface pool
// and hands the GUI a lease per delivered generation. Two one-way
// notifications carry the GUI's side of the bookkeeping back:
//
//   pane.surfaceRelease: a cumulative low-water-mark ack, "I hold no
//     generation below lowestHeld for this
//     (paneId, subscriptionToken, leaseEpoch); free the committed ones
//     below it." (lowestHeld = min of the held set, or one past the
//     highest received when empty.)
//   pane.surfaceDrain: tear this surface subscription down, keyed by
//     the originating pane.subscribe request id.
//
// Both are notifications (no `id`, no response). The subscribe ack
// returns the `subscriptionToken` the GUI correlates its side-band
// surface lane and its acks against.

import Foundation

/// `pane.subscribe` initial result. Extends the bare `{ok}` ack with the
/// transport-level correlation token minted per XPC subscription. The
/// token is optional because UDS vends no surface lane and mints none; a
/// decoded frame without the field yields nil.
public struct PaneSubscribeAck: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case success = "ok"
        case subscriptionToken
    }

    public let success: Bool
    public let subscriptionToken: String?

    public init(success: Bool, subscriptionToken: String?) {
        self.success = success
        self.subscriptionToken = subscriptionToken
    }
}

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

/// `pane.surfaceDrain` params: tear down a surface subscription. Keyed
/// by the originating `pane.subscribe` request id (the `RPCEnvelope.id`
/// type), which the GUI knows the instant it subscribes, so drain works
/// even before any token or side-band exists.
public struct SurfaceDrainParams: Codable, Sendable, Equatable {
    public let paneId: String
    public let subscribeRequestId: UInt32

    public init(paneId: String, subscribeRequestId: UInt32) {
        self.paneId = paneId
        self.subscribeRequestId = subscribeRequestId
    }
}
