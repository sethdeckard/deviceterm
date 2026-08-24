// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Production transport: one Unix-domain-socket round-trip per call via
/// `roundTrip`, including the env-cred auto-auth handshake.
struct UDSTransport: CLITransport {
    func send(_ envelope: RPCEnvelope, timeoutSeconds: Double) throws -> Data {
        guard let method = envelope.method else {
            throw CLIError.transport("internal error: request envelope has no method")
        }
        return try roundTrip(
            method: method,
            params: paramsData(envelope),
            timeoutSeconds: timeoutSeconds
        )
    }
}
