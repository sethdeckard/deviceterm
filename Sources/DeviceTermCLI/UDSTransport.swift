// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Production transport: one Unix-domain-socket round-trip per call via
/// `roundTrip`, including the env-cred auto-auth handshake.
struct UDSTransport: CLITransport {
    func send(_ envelope: RPCEnvelope, timeoutSeconds: Double) throws -> Data {
        try send(timeoutSeconds: timeoutSeconds) { envelope }
    }

    func send(
        timeoutSeconds: Double,
        buildingEnvelope: () throws -> RPCEnvelope
    ) throws -> Data {
        try roundTrip(timeoutSeconds: timeoutSeconds) {
            let envelope = try buildingEnvelope()
            guard let method = envelope.method else {
                throw CLIError.classified(
                    code: .internalError,
                    message: "internal error: request envelope has no method"
                )
            }
            return (method, paramsData(envelope))
        }
    }
}
