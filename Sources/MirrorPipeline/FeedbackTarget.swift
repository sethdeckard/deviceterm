// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The RTCP feedback target negotiated in the start-stream answer's
/// `streamConfig`: where to send Receiver Reports and PLIs, and the SSRCs that
/// tag the exchange.
struct FeedbackTarget: Sendable, Equatable {
    /// The device-side RTCP port (`streamConfig.SourcePort`); RTCP rides the same
    /// UDP socket the RTP arrives on.
    let sourcePort: UInt16
    /// Our SSRC, which the device names `RemoteSSRC` (from its own perspective).
    let localSSRC: UInt32
    /// The device's SSRC, which the device names `LocalSSRC`.
    let remoteSSRC: UInt32
}
