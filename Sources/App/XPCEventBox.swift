// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import IOSurface
import os

/// Sendable box for an `xpc_object_t` so it can ride an ingress
/// `AsyncStream`. XPC objects are reference-counted and thread-safe to pass
/// across queues, which is why the unchecked conformance holds.
struct XPCEventBox: @unchecked Sendable {
    let event: xpc_object_t
}
