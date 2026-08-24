// SPDX-License-Identifier: GPL-3.0-or-later
//
// The daemon round-trip seam. Command handlers depend on this protocol
// rather than the concrete UDS socket, so they can be unit-tested against
// a fake transport that returns canned response bytes: no daemon, no
// socket, no process exit.
//
// `UDSTransport` is the production implementation; it wraps the existing
// `roundTrip(method:params:)` path (auto-auth handshake included).

import DaemonProtocol
import Foundation

protocol CLITransport {
    /// Send a built request envelope and return the daemon's response
    /// body bytes. Throws `CLIError.transport` / `CLIError.daemon` on
    /// failure, matching the free `send(_:)`'s contract.
    func send(_ envelope: RPCEnvelope, timeoutSeconds: Double) throws -> Data
}

extension CLITransport {
    /// Default 5-second response timeout, matching the free `send(_:)`.
    func send(_ envelope: RPCEnvelope) throws -> Data {
        try send(envelope, timeoutSeconds: 5)
    }
}
