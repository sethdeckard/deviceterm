// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import IOSurface

/// Dictionary keys shared by the XPC transport. Defined here so
/// receiver and sender agree on the wire without re-typing
/// strings.
public enum XPCTransportKey {
    /// The `xpc_dictionary` field that distinguishes an RPC
    /// envelope payload from a side-band surface payload. The
    /// only value accepted inbound is `rpcValue` below.
    public static let type = "type"
    /// The JSON-bytes payload of an RPC envelope. Present iff
    /// `type == rpcValue`.
    public static let data = "data"

    /// Discriminator value for a wrapped RPC envelope: the only
    /// value accepted on inbound messages. Outbound surface
    /// payloads use `"surface"` (see `surfaceDelivery`).
    public static let rpcValue = "rpc"
}
