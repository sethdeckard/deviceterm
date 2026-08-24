// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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
