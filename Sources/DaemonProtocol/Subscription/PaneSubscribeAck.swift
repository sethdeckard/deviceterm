// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `pane.subscribe` initial result. Extends the bare `{ok}` ack with the
/// transport-level correlation token minted per XPC subscription. The
/// token is optional because UDS vends no surface lane and mints none; a
/// decoded frame without the field yields nil.
///
/// The daemon owns each physical-device frame in a leased surface pool
/// and hands the GUI a lease per delivered generation. Two one-way
/// notifications carry the GUI's side of the bookkeeping back, and both
/// are notifications (no `id`, no response):
///
/// - `pane.surfaceRelease`: a cumulative low-water-mark ack, "I hold no
///   generation below `lowestHeld` for this
///   `(paneId, subscriptionToken, leaseEpoch)`; free the committed ones
///   below it." (`lowestHeld` = min of the held set, or one past the
///   highest received when empty.) See `SurfaceReleaseParams`.
/// - `pane.surfaceDrain`: tear this surface subscription down, keyed by
///   the originating `pane.subscribe` request id. See `SurfaceDrainParams`.
///
/// This ack returns the `subscriptionToken` the GUI correlates its
/// side-band surface lane and its acks against.
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
