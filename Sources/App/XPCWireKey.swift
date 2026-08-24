// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import IOSurface
import os

/// XPC dictionary keys + discriminators on the GUI side. Mirror
/// `XPCTransportKey` in the daemon so the two ends agree without
/// re-typing string literals, but the GUI module can't import the
/// daemon, so the constants are duplicated here.
enum XPCWireKey {
    static let type = "type"
    static let data = "data"
    static let paneId = "paneId"
    static let sequence = "sequence"
    static let surface = "surface"

    static let rpcValue = "rpc"
    static let surfaceValue = "surface"

    // Correlation token (every XPC pane subscription, sim + device) plus the
    // device-only lease overlay (leased/leaseEpoch).
    static let subscriptionToken = "subscriptionToken"
    static let leased = "leased"
    static let leaseEpoch = "leaseEpoch"
}
